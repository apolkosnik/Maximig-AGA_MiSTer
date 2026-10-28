//============================================================================
//  a3kp_sbic: the WD33C93A SCSI bus interface controller, as the AA3000+'s
//  SuperDMAC drives it (WD33C93A data sheet, Western Digital, Nov 1990)
//
//  Indirect addressing (ALE grounded, as on the A3000): A0 = 0 writes the
//  address register / reads the auxiliary status; A0 = 1 reads or writes
//  the addressed register, the address then incrementing except at the
//  auxiliary status, the command and the data registers.
//
//  The initiator role on a bus with targets that never select or reselect
//  it (a3kp_scsi_disk; nothing on the AA3000+'s bus initiates):
//  * Level I: Reset (00), Abort (01), Assert ATN (02), Negate ACK (03),
//    Disconnect (04), Set IDI (0F).
//  * Simple Level II: Select-With-ATN (06), Select-Without-ATN (07),
//    Transfer Info (20, with the SBT bit).
//  * Combination: Select-And-Transfer (08 with ATN, 09 without), resumed
//    from the Command Phase register when issued while connected (7.6.1).
//  * Reselect (05) times out (no initiator answers it); Wait-For-Select-
//    And-Receive (0C) waits forever (it can only be aborted or reset).
//  * Everything else -- the target role's commands, Translate Address --
//    an invalid command interrupt (40).
//  Interrupts: the SCSI Status register holds the cause; reading it drops
//  INTRQ; the chip does nothing further until it has been read (6.2.19).
//  Data phases go through the DMA port (DMA mode 4 or burst mode 1, the
//  SuperDMAC's) or the Data register (polled, DM = 0); command, status and
//  message bytes through the Data register when the host transfers them
//  itself (Transfer Info).  Transfers are asynchronous (the Synchronous
//  Transfer register is kept but not applied).
//
//  The host port and the DMA port are toggle handshakes from the SuperDMAC's
//  clock domain (clk_57): req toggles with its fields stable, ack toggles
//  back when done; both are synchronised here.
//============================================================================

module a3kp_sbic
(
	input             clk,            // clk_sys (the chip's clock: 14 MHz on the A3000, half this)
	input             mr,             // master reset (the system reset, or the DMAC's PREST)

	// the host port (a3kp_dmac)
	input             h_req,
	output reg        h_ack = 1'b0,
	input             h_a0,
	input             h_we,
	input       [7:0] h_wdata,
	output reg  [7:0] h_rdata,
	output            intrq,

	// the DMA port (a3kp_dmac): drq is up while a byte can move; a request
	// moves one byte (in: dma_rdata with the ack; out: dma_wdata)
	output reg        drq = 1'b0,
	input             d_req,
	output reg        d_ack = 1'b0,
	input       [7:0] d_wdata,
	output reg  [7:0] d_rdata,
	output reg        d_more,         // with the ack: drq stays up for another byte

	// the SCSI bus (a3kp_scsi_disk)
	output reg        sel = 1'b0,
	output reg  [2:0] sel_id,
	output reg        atn = 1'b0,
	input             bsy,
	input       [2:0] phase,          // {MSG, C/D, I/O}
	input             req,
	input       [7:0] tdata,
	output reg        ack = 1'b0,
	output reg  [7:0] idata,
	output reg        abort_t = 1'b0  // the initiator left the bus (Disconnect, Reset): the targets give up
);

localparam [7:0]
	R_OWNID = 8'h00, R_CTRL = 8'h01, R_TPER = 8'h02, R_CDB1 = 8'h03, R_TLUN = 8'h0F, R_CPR = 8'h10,
	R_SYNC = 8'h11, R_TCH = 8'h12, R_TCM = 8'h13, R_TCL = 8'h14, R_DEST = 8'h15, R_SRC = 8'h16,
	R_STAT = 8'h17, R_CMD = 8'h18, R_DATA = 8'h19, R_AUX = 8'h1F;

localparam [2:0] PH_DOUT = 3'b000, PH_DIN = 3'b001, PH_CMD = 3'b010, PH_STAT = 3'b011,
                 PH_MOUT = 3'b110, PH_MIN = 3'b111;

//----------------------------------------------------------------------------
// the registers
//----------------------------------------------------------------------------
reg  [7:0] regs [0:22];       // 00-16
reg  [7:0] sasr = 8'd0;
reg  [7:0] scsi_stat = 8'd0;
reg  [7:0] cmd_reg = 8'd0;
reg        int_r = 1'b0;      // INTRQ
reg        lci = 1'b0;
reg        busy = 1'b0;       // BSY: a Level II command executes
reg        dbr = 1'b0;        // Data Buffer Ready (polled transfers)
reg  [7:0] dbuf;              // the data register / the one-byte FIFO
reg        dbuf_v = 1'b0;     // dbuf holds a byte (in) / a byte to send (out)
reg        eaf = 1'b0;        // advanced features (the Own ID's EAF at the last Reset)
reg        connected = 1'b0;  // connected as an initiator
reg        sat = 1'b0;        // the command running is a Select-And-Transfer
reg        msgin_hold = 1'b0; // ACK held after a Message In byte (Transfer Info)

assign intrq = int_r;

wire [23:0] tc = {regs[R_TCH], regs[R_TCM], regs[R_TCL]};
wire  [2:0] dmode = regs[R_CTRL][7:5];
wire        dma_on = (dmode == 3'b100 || dmode == 3'b001);

wire [7:0] aux = {int_r, lci, busy, 1'b0, 2'b00, 1'b0, dbr};

//----------------------------------------------------------------------------
// the host port
//----------------------------------------------------------------------------
reg [2:0] h_req_s = 3'b000;
reg [2:0] d_req_s = 3'b000;
always @(posedge clk) begin
	h_req_s <= {h_req_s[1:0], h_req};
	d_req_s <= {d_req_s[1:0], d_req};
end
wire h_new = h_req_s[2] != h_ack;      // (h_req_s[1:0] settled: the fields are stable)
wire d_new = d_req_s[2] != d_ack;

// the register read at the current address
function automatic [7:0] reg_rd(input [7:0] a);
	if (a <= 8'h16)    reg_rd = regs[a[4:0]];
	else if (a == R_STAT) reg_rd = scsi_stat;
	else if (a == R_CMD)  reg_rd = cmd_reg;
	else if (a == R_DATA) reg_rd = dbuf;
	else if (a == R_AUX)  reg_rd = aux;
	else                  reg_rd = 8'hFF;
endfunction

function automatic incs(input [7:0] a);
	incs = !(a == R_AUX || a == R_DATA || a == R_CMD);
endfunction

//----------------------------------------------------------------------------
// the command engine
//----------------------------------------------------------------------------
localparam [4:0]
	E_IDLE  = 5'd0,  E_RESET = 5'd1,  E_SEL   = 5'd2,  E_SELW  = 5'd3,  E_NEXT = 5'd4,
	E_BYTE  = 5'd5,  E_ACKW  = 5'd6,  E_INT   = 5'd7,  E_TI    = 5'd8,  E_TIB  = 5'd9,
	E_FREEW = 5'd10, E_FOREVER = 5'd11, E_RESELT = 5'd12, E_INTW = 5'd13;

reg  [4:0] es = E_IDLE;
reg [25:0] tmo;               // selection timeout, in clocks
reg  [7:0] pend_stat;         // the interrupt the engine raises once the last one has been read
reg  [4:0] after_int;         // where the engine goes when it has raised it
reg  [3:0] cdb_len;
reg  [2:0] bphase;            // the byte's phase
reg        sbt;               // Transfer Info: one byte
reg  [2:0] last_phase;        // the phase of the last REQ seen while connected and idle
reg        req_seen;          // that REQ has interrupted (service required)
reg  [7:0] cpr_n;

// the CDB length from its group (the Own ID's CDB size for unknown groups in
// advanced mode)
function automatic [3:0] cdb_size(input [7:0] op, input adv, input [3:0] osz);
	case (op[7:5])
		3'd0:      cdb_size = 4'd6;
		3'd1, 3'd2: cdb_size = 4'd10;
		3'd5:      cdb_size = 4'd12;
		default:   cdb_size = (adv && osz != 4'd0) ? osz : 4'd6;
	endcase
endfunction

// timeout period: the register times 80,000 input clocks (6.2.5); the input
// clock (14.19 MHz on the A3000) is half clk_sys: 160,000 clocks a unit
function automatic [25:0] tper_clks(input [7:0] v);
	tper_clks = {1'b0, v, 17'd0} + {4'd0, v, 14'd0} + {5'd0, v, 13'd0} + {6'd0, v, 12'd0} + {10'd0, v, 8'd0};
endfunction

integer i;

always @(posedge clk) begin
	logic do_read, do_write;
	ack <= 1'b0;

	//------------------------------------------------------------------------
	// the host's register cycles
	//------------------------------------------------------------------------
	if (h_new) begin
		h_ack <= h_req_s[2];
		if (!h_a0) begin
			if (h_we) sasr <= h_wdata;
			else      h_rdata <= aux;
		end
		else if (!h_we) begin
			h_rdata <= reg_rd(sasr);
			if (sasr == R_STAT) begin
				// reading the status drops INTRQ
				int_r <= 1'b0;
			end
			if (sasr == R_DATA && dbuf_v && !dma_on) begin
				// a polled byte taken
				dbuf_v <= 1'b0;
				dbr    <= 1'b0;
			end
			if (incs(sasr)) sasr <= (sasr + 1'd1) & 8'h1F;
		end
		else begin
			if (sasr <= 8'h16) regs[sasr[4:0]] <= h_wdata;
			if (sasr == R_DATA && !dma_on) begin
				// a polled byte given
				dbuf   <= h_wdata;
				dbuf_v <= 1'b1;
				dbr    <= 1'b0;
			end
			if (sasr == R_CMD) begin
				cmd_reg <= h_wdata;
				if (int_r && h_wdata[6:0] != 7'h00 && h_wdata[6:0] != 7'h01 && h_wdata[6:0] != 7'h03) lci <= 1'b1;
				else if (busy && h_wdata[6:0] >= 7'h05 && h_wdata[6:0] != 7'h0F) lci <= 1'b1;
				else begin
					lci <= 1'b0;
					case (h_wdata[6:0])
						7'h00: begin                                   // Reset
							busy <= 1'b1;
							es   <= E_RESET;
						end
						7'h01: begin                                   // Abort
							if (es == E_SELW || es == E_RESELT || es == E_FOREVER) begin
								sel       <= 1'b0;
								atn       <= 1'b0;
								pend_stat <= 8'h22;                    // a Select or Reselect aborted
								after_int <= E_IDLE;
								es        <= E_INT;
							end
							else if (connected) begin
								pend_stat <= {4'h2, 1'b1, phase};      // a transfer aborted
								after_int <= E_IDLE;
								es        <= E_INT;
							end
							else begin
								pend_stat <= 8'h22;
								after_int <= E_IDLE;
								es        <= E_INT;
							end
						end
						7'h02: if (connected) atn <= 1'b1;            // Assert ATN
						7'h03: if (msgin_hold) begin                  // Negate ACK
							msgin_hold <= 1'b0;
							ack        <= 1'b1;
							idata      <= 8'h00;
							es         <= E_FREEW;
						end
						7'h04: begin                                   // Disconnect
							sel       <= 1'b0;
							atn       <= 1'b0;
							connected <= 1'b0;
							busy      <= 1'b0;
							abort_t   <= ~abort_t;
							es        <= E_IDLE;
						end
						7'h0F: regs[R_CTRL][2] <= 1'b1;               // Set IDI
						7'h06, 7'h07, 7'h08, 7'h09: begin
							busy   <= 1'b1;
							sat    <= h_wdata[3];
							if (connected && h_wdata[3]) begin
								// resume a Select-And-Transfer at its command phase
								es <= E_NEXT;
							end
							else if (connected) begin
								pend_stat <= 8'h40;                    // a Select while connected: invalid
								after_int <= E_IDLE;
								es        <= E_INT;
							end
							else begin
								regs[R_CPR] <= 8'h00;
								sel_id <= regs[R_DEST][2:0];
								sel    <= 1'b1;
								atn    <= !h_wdata[0];                  // 06, 08: with ATN
								tmo    <= tper_clks(regs[R_TPER]);
								es     <= E_SEL;
							end
						end
						7'h20: begin                                   // Transfer Info
							if (!connected) begin
								pend_stat <= 8'h40;
								after_int <= E_IDLE;
								es        <= E_INT;
							end
							else begin
								busy <= 1'b1;
								sat  <= 1'b0;
								sbt  <= h_wdata[7];
								es   <= E_TI;
							end
						end
						7'h05: begin                                   // Reselect: nobody to answer
							busy <= 1'b1;
							tmo  <= tper_clks(regs[R_TPER]);
							es   <= E_RESELT;
						end
						7'h0C: begin                                   // Wait-For-Select-And-Receive
							busy <= 1'b1;
							es   <= E_FOREVER;
						end
						default: begin                                 // invalid here
							pend_stat <= 8'h40;
							after_int <= E_IDLE;
							es        <= E_INT;
						end
					endcase
				end
			end
			if (incs(sasr)) sasr <= (sasr + 1'd1) & 8'h1F;
		end
	end

	//------------------------------------------------------------------------
	// the DMA port: one byte per request, while drq allows it
	//------------------------------------------------------------------------
	if (d_new) begin
		d_ack <= d_req_s[2];
		if (phase[0]) begin
			// in: the byte waiting
			d_rdata <= dbuf;
			dbuf_v  <= 1'b0;
		end
		else begin
			dbuf   <= d_wdata;
			dbuf_v <= 1'b1;
		end
		drq    <= 1'b0;
		d_more <= 1'b0;
	end

	//------------------------------------------------------------------------
	// the engine
	//------------------------------------------------------------------------
	if (!req) req_seen <= 1'b0;
	case (es)
		E_IDLE: begin
			busy <= 1'b0;
			// connected and idle: a new REQ asks for service; the bus going
			// free is a disconnect
			if (connected && !int_r) begin
				if (!bsy) begin
					connected <= 1'b0;
					pend_stat <= 8'h85;
					after_int <= E_IDLE;
					es        <= E_INT;
				end
				else if (req && !req_seen) begin
					req_seen  <= 1'b1;
					pend_stat <= {4'h8, 1'b1, phase};
					after_int <= E_IDLE;
					es        <= E_INT;
				end
			end
		end

		E_RESET: begin
			// Reset: registers 01-16 and the command register cleared, the Own
			// ID interpreted (6.3.2); the bus released
			for (i = 1; i <= 22; i = i + 1) regs[i] <= 8'h00;
			eaf       <= regs[R_OWNID][3];
			sel       <= 1'b0;
			atn       <= 1'b0;
			if (connected) abort_t <= ~abort_t;
			connected <= 1'b0;
			dbuf_v    <= 1'b0;
			dbr       <= 1'b0;
			drq       <= 1'b0;
			msgin_hold <= 1'b0;
			pend_stat <= {7'd0, regs[R_OWNID][3]};
			after_int <= E_IDLE;
			es        <= E_INT;
		end

		// raise an interrupt: only once the last one has been read (a REQ up
		// then has had its interrupt: it does not ask for service again)
		E_INT: if (!int_r) begin
			scsi_stat <= pend_stat;
			int_r     <= 1'b1;
			busy      <= 1'b0;
			if (req) req_seen <= 1'b1;
			es        <= after_int;
		end

		// arbitration won at once; selection: wait for BSY or the timeout
		E_SEL: begin
			if (bsy) begin
				sel       <= 1'b0;
				connected <= 1'b1;
				req_seen  <= 1'b0;
				regs[R_CPR] <= 8'h10;
				if (sat) es <= E_NEXT;
				else begin
					pend_stat <= 8'h11;                       // a Select completed
					after_int <= E_IDLE;
					es        <= E_INT;
				end
			end
			else if (regs[R_TPER] != 8'd0) begin
				if (tmo == 26'd0) begin
					sel       <= 1'b0;
					atn       <= 1'b0;
					regs[R_CPR] <= 8'h00;
					pend_stat <= 8'h42;                       // selection timeout
					after_int <= E_IDLE;
					es        <= E_INT;
				end
				else tmo <= tmo - 1'd1;
			end
		end

		E_RESELT: begin
			if (regs[R_TPER] != 8'd0) begin
				if (tmo == 26'd0) begin
					pend_stat <= 8'h42;
					after_int <= E_IDLE;
					es        <= E_INT;
				end
				else tmo <= tmo - 1'd1;
			end
		end

		E_FOREVER: ;

		// Select-And-Transfer: the next REQ, against the command phase reached
		E_NEXT: begin
			if (!bsy) begin
				// the target left the bus
				connected <= 1'b0;
				atn       <= 1'b0;
				if (regs[R_CPR] == 8'h60) begin
					pend_stat <= 8'h85;                       // the disconnect after the completion
					after_int <= E_IDLE;
				end
				else begin
					pend_stat <= 8'h41;                       // unexpected disconnect
					after_int <= E_IDLE;
				end
				es <= E_INT;
			end
			else if (req) begin
				logic [7:0] c;
				c = regs[R_CPR];
				bphase <= phase;
				case (phase)
					PH_MOUT: begin
						if (c < 8'h20) begin
							// the Identify: 1 R 000 LUN, R = Enable Reselect
							idata <= {1'b1, regs[R_SRC][7], 3'b000, regs[R_TLUN][2:0]};
							atn   <= 1'b0;                        // negated with the last byte
							ack   <= 1'b1;
							regs[R_CPR] <= 8'h20;
							es    <= E_ACKW;
						end
						else begin
							pend_stat <= 8'h4E;                   // unexpected Message Out
							after_int <= E_IDLE;
							es        <= E_INT;
						end
					end
					PH_CMD: begin
						if (c < 8'h30 || (c[7:4] == 4'h3 && c[3:0] < cdb_size(regs[R_CDB1], eaf, regs[R_OWNID][3:0]))) begin
							logic [3:0] n;
							n = (c < 8'h30) ? 4'd0 : c[3:0];
							idata <= regs[5'(8'h03 + n)];
							ack   <= 1'b1;
							regs[R_CPR] <= 8'h31 + {4'd0, n};
							es    <= E_ACKW;
						end
						else begin
							pend_stat <= 8'h4A;
							after_int <= E_IDLE;
							es        <= E_INT;
						end
					end
					PH_DIN, PH_DOUT: begin
						if (tc != 24'd0 && c < 8'h46) begin
							if (c < 8'h45) regs[R_CPR] <= 8'h45;
							es <= E_BYTE;
						end
						else begin
							// data the host did not ask for
							regs[R_CPR] <= (c < 8'h46) ? 8'h45 : c;
							pend_stat <= {4'h4, 1'b1, phase};
							after_int <= E_IDLE;
							es        <= E_INT;
						end
					end
					PH_STAT: begin
						if (tc == 24'd0 || c >= 8'h46 || c < 8'h41) begin
							regs[R_CPR] <= 8'h47;
							es <= E_BYTE;
						end
						else begin
							// status before the data the host expected
							pend_stat <= 8'h4B;
							after_int <= E_IDLE;
							es        <= E_INT;
						end
					end
					PH_MIN: begin
						es <= E_BYTE;
					end
					default: begin
						pend_stat <= {4'h4, 1'b1, phase};
						after_int <= E_IDLE;
						es        <= E_INT;
					end
				endcase
			end
		end

		// a Select-And-Transfer byte of an In phase or of a data phase
		E_BYTE: begin
			if (!bsy) es <= E_NEXT;
			else if (bphase == PH_DIN || bphase == PH_DOUT) begin
				// through the DMA port or the Data register
				if (bphase == PH_DIN && dbuf_v) ;               // the last byte taken by the DMA first
				else if (!req) ;                                // wait for the target's REQ
				else if (phase != bphase) es <= E_NEXT;
				else if (tc == 24'd0) begin
					regs[R_CPR] <= 8'h46;
					es <= E_NEXT;
				end
				else if (bphase == PH_DIN) begin
					if (!dbuf_v) begin
						dbuf   <= tdata;
						dbuf_v <= 1'b1;
						ack    <= 1'b1;
						{regs[R_TCH], regs[R_TCM], regs[R_TCL]} <= tc - 1'd1;
						if (tc == 24'd1) regs[R_CPR] <= 8'h46;
						es     <= E_ACKW;
					end
				end
				else begin
					if (dbuf_v) begin
						idata  <= dbuf;
						dbuf_v <= 1'b0;
						ack    <= 1'b1;
						{regs[R_TCH], regs[R_TCM], regs[R_TCL]} <= tc - 1'd1;
						if (tc == 24'd1) regs[R_CPR] <= 8'h46;
						es     <= E_ACKW;
					end
				end
			end
			else if (bphase == PH_STAT) begin
				regs[R_TLUN] <= tdata;                          // the status byte
				regs[R_CPR]  <= 8'h50;
				ack <= 1'b1;
				es  <= E_ACKW;
			end
			else begin
				// Message In after the status: Command Complete expected
				dbuf <= tdata;
				if (tdata == 8'h00 && regs[R_CPR] == 8'h50) begin
					regs[R_CPR] <= 8'h60;
					ack <= 1'b1;
					if (!regs[R_CTRL][3]) begin
						pend_stat <= 8'h16;                         // Select-And-Transfer completed
						after_int <= E_FREEW;
						es        <= E_INTW;
					end
					else es <= E_FREEW;                           // EDI: the interrupt waits for the disconnect
				end
				else begin
					// another message: terminated, ACK held so the host can see it
					msgin_hold <= 1'b1;
					pend_stat  <= 8'h4F;
					after_int  <= E_IDLE;
					es         <= E_INT;
				end
			end
		end

		// the ack given: wait for the target to drop REQ
		E_ACKW: if (!req) es <= sat ? ((bphase == PH_DIN || bphase == PH_DOUT) ? E_BYTE : E_NEXT) : E_TIB;

		// the last ACK of a Select-And-Transfer went with the interrupt
		E_INTW: if (!req) es <= E_INT;

		// wait for the target to free the bus after the Command Complete
		E_FREEW: if (!bsy) begin
			connected <= 1'b0;
			if (regs[R_CTRL][3] || after_int != E_FREEW) begin
				pend_stat <= regs[R_CTRL][3] ? 8'h16 : 8'h85;
				after_int <= E_IDLE;
				es        <= E_INT;
			end
			else begin
				pend_stat <= 8'h85;
				after_int <= E_IDLE;
				es        <= E_INT;
			end
		end

		// Transfer Info: TC bytes (one with SBT) in the phase the target asks for
		E_TI: begin
			bphase <= phase;
			dbr    <= 1'b0;
			es     <= E_TIB;
		end
		E_TIB: begin
			if (!bsy) begin
				connected <= 1'b0;
				pend_stat <= 8'h41;
				after_int <= E_IDLE;
				es        <= E_INT;
			end
			else if (dma_on && bphase == PH_DIN && dbuf_v) ;   // the DMA takes the byte first
			else if (!req) ;
			else if (phase != bphase) begin
				// the phase changed: the transfer is done (or cut short)
				req_seen  <= 1'b1;
				pend_stat <= (tc == 24'd0 || sbt) ? {4'h1, 1'b1, phase} : {4'h4, 1'b1, phase};
				after_int <= E_IDLE;
				es        <= E_INT;
			end
			else if (!sbt && tc == 24'd0) begin
				req_seen  <= 1'b1;
				pend_stat <= {4'h1, 1'b1, phase};
				after_int <= E_IDLE;
				es        <= E_INT;
			end
			else if (phase[0]) begin
				// In: a byte to the buffer, the host or DMA takes it
				if (!dbuf_v) begin
					dbuf   <= tdata;
					dbuf_v <= 1'b1;
					dbr    <= !(dma_on && phase[2:1] == 2'b00);
					if (!sbt) {regs[R_TCH], regs[R_TCM], regs[R_TCL]} <= tc - 1'd1;
					if (phase == PH_MIN && (sbt || tc == 24'd1)) begin
						// the last Message In byte: ACK stays asserted (paused)
						msgin_hold <= 1'b1;
						pend_stat  <= 8'h20;
						after_int  <= E_IDLE;
						es         <= E_INT;
					end
					else begin
						ack <= 1'b1;
						if (sbt) begin
							req_seen  <= 1'b0;
							pend_stat <= {4'h1, 1'b1, phase};
							after_int <= E_IDLE;
							es        <= E_INTW;
						end
						else es <= E_ACKW;
					end
				end
			end
			else begin
				// Out: the host or DMA gives the byte
				if (!dbuf_v) dbr <= !(dma_on && phase[2:1] == 2'b00);
				else begin
					idata  <= dbuf;
					dbuf_v <= 1'b0;
					dbr    <= 1'b0;
					if (phase == PH_MOUT && (sbt || tc == 24'd1)) atn <= 1'b0;   // ATN off before the last message byte
					ack    <= 1'b1;
					if (!sbt) {regs[R_TCH], regs[R_TCM], regs[R_TCL]} <= tc - 1'd1;
					if (sbt) begin
						req_seen  <= 1'b0;
						pend_stat <= {4'h1, 1'b1, phase};
						after_int <= E_IDLE;
						es        <= E_INTW;
					end
					else es <= E_ACKW;
				end
			end
		end

		default: es <= E_IDLE;
	endcase

	// the DMA request: a data phase in DMA mode with a byte to take or room for one
	if (!d_new) begin
		// in: a data byte waiting in the buffer; out: the target asking for
		// data the count allows and the buffer empty
		drq <= dma_on && connected && (es == E_BYTE || es == E_TIB || es == E_ACKW) &&
		       ((bphase == PH_DIN && dbuf_v) ||
		        (bphase == PH_DOUT && !dbuf_v && phase == PH_DOUT && bsy && tc != 24'd0));
	end

	if (mr) begin
		// the MR- pin (6.3.1): registers 01-15 kept; the Own ID cleared,
		// advanced mode off, the state machines cleared; INTRQ with status 00
		regs[R_OWNID] <= 8'h00;
		regs[R_SRC]   <= regs[R_SRC] & 8'h0F;
		eaf       <= 1'b0;
		sasr      <= 8'h00;
		lci       <= 1'b0;
		busy      <= 1'b0;
		dbr       <= 1'b0;
		dbuf_v    <= 1'b0;
		drq       <= 1'b0;
		sel       <= 1'b0;
		atn       <= 1'b0;
		if (connected) abort_t <= ~abort_t;
		connected <= 1'b0;
		msgin_hold <= 1'b0;
		scsi_stat <= 8'h00;
		int_r     <= 1'b1;
		es        <= E_IDLE;
	end
end


`ifdef SCSI_DEBUG
reg [5:0] dbg_es_d = 6'd0;
always @(posedge clk) begin
	dbg_es_d <= 6'(es);
	if (6'(es) != dbg_es_d) $display("[sbic] %t es %0d -> %0d", $time, dbg_es_d, es);
end
`endif

endmodule
