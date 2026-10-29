//============================================================================
//  a3kp_scsi_hps: the SCSI hard disks on the AA3000+'s bus, served by the HPS
//
//  SCSI targets 0 and 1 (Main's hard disk images on its IDE channel 0's
//  master and slave).  The target answers its selection and runs the bus
//  phases -- Message Out (the Identify, when the initiator selected with
//  ATN), Command, Data In or Out, Status, Message In (Command Complete) --
//  and releases the bus; it never disconnects.  The commands themselves are
//  Main's (hps/maximig_scsi_target.h): it reads the CDB, then fills or
//  empties the 8 KB buffer and has the target move it, and gives the status.
//
//  The bus to the initiator (a3kp_sbic) is the SCSI bus's information
//  transfer handshake, one byte per REQ/ACK: the target sets the phase
//  (MSG, C/D, I/O), its byte for an In phase, and raises req; the initiator
//  answers with a one-clock ack and its byte for an Out phase.
//
//  The HPS side is ide.v's management port (Main's IDE channel 0, hps_ext):
//    0  read: {4'hA, seq, 0, LUN, 0, target}; write: {.., seq}, the buffer
//       cursor to its start (a step's operation then goes through only with
//       the current command's seq)
//    1-6  read: the CDB's bytes, two a register, the first one low
//    6  write: the drives present, as ide.v takes them (bits 3 / 7 enable
//       bits 0 / 4: targets 0 / 1)
//    8  write: the step -- {00, n} Data In of n bytes from the buffer, {01,
//       n} Data Out of n bytes into it, {10, 6'd0, status} the Status and
//       Message In phases, the command's end
//    15 the buffer, a word a access, its first byte low (the cursor moves)
//  and its request code (ide.v's are 4-6, so Main tells them apart): 1 a
//  command's CDB is in, 2 a Data Out has filled the buffer, 3 a Data In has
//  sent it.
//============================================================================

module a3kp_scsi_hps
(
	input             clk,
	input             reset,          // the system reset (SCSI RST)

	// the SCSI bus, the initiator's side
	input             sel,            // selection, held until bsy or the initiator gives up
	input       [2:0] sel_id,
	input             atn,
	output reg        bsy = 1'b0,
	output reg  [2:0] phase,          // {MSG, C/D, I/O}
	output reg        req = 1'b0,
	output reg  [7:0] tdata,          // the target's byte (In phases)
	input             ack,            // one clock: the initiator took / gives a byte
	input       [7:0] idata,          // the initiator's byte (Out phases)

	// the HPS (ide.v's management port)
	input       [3:0] mgmt_address,
	input             mgmt_write,
	input      [15:0] mgmt_writedata,
	input             mgmt_read,
	output reg [15:0] mgmt_readdata,
	output reg  [2:0] request = 3'd0,
	output      [1:0] present
);

localparam [2:0] PH_DOUT = 3'b000, PH_DIN = 3'b001, PH_CMD = 3'b010, PH_STAT = 3'b011,
                 PH_MOUT = 3'b110, PH_MIN = 3'b111;

localparam [2:0] RQ_CMD = 3'd1, RQ_DOUT = 3'd2, RQ_DIN = 3'd3;

localparam [3:0] T_FREE = 4'd0, T_MOUT = 4'd1, T_CMD = 4'd2, T_WAIT = 4'd3,
                 T_DIN  = 4'd4, T_DIN2 = 4'd5, T_DOUT = 4'd6, T_STAT = 4'd7,
                 T_MIN  = 4'd8, T_END  = 4'd9;

reg  [3:0] st = T_FREE;
reg  [1:0] pres = 2'b00;
reg  [2:0] tid, lun;
reg  [7:0] cdb [12];
reg  [3:0] cdb_n, cdb_len;
reg  [3:0] seq = 4'd0, hseq = 4'd0;   // the command's number; the one the HPS addresses
reg  [7:0] status;
reg [13:0] bcnt, bidx;                // the step's bytes, the next one
reg  [7:0] lo;                        // Data Out: the word's first byte

assign present = pres;

// the buffer: 4K words, the HPS's while the target waits, the target's in
// its steps
reg [15:0] buffer [0:4095];
reg [11:0] hptr;                      // the HPS cursor (words)
reg [15:0] bq;
wire       bus_side = (st == T_DIN) || (st == T_DIN2) || (st == T_DOUT);
reg        b_we;
reg [11:0] b_wa;
reg [15:0] b_wd;
wire [11:0] b_ra = bus_side ? bidx[12:1] : hptr;
always @(posedge clk) begin
	if (b_we) buffer[b_wa] <= b_wd;
	bq <= buffer[b_ra];
end

// the selection: a fitted target
wire sel_me = sel && !bsy && sel_id[2:1] == 2'b00 && pres[sel_id[0]];

always @(posedge clk) begin
	b_we <= 1'b0;
	// the HPS's registers
	if (mgmt_write) begin
		case (mgmt_address)
			4'd0: begin hseq <= mgmt_writedata[3:0]; hptr <= 12'd0; end
			4'd6: begin
				if (mgmt_writedata[3]) pres[0] <= mgmt_writedata[0];
				if (mgmt_writedata[7]) pres[1] <= mgmt_writedata[4];
			end
			4'd15: if (!bus_side) begin
				b_we <= 1'b1; b_wa <= hptr; b_wd <= mgmt_writedata;
				hptr <= hptr + 1'd1;
			end
			default: ;
		endcase
	end
	if (mgmt_read && mgmt_address == 4'd15 && !bus_side) hptr <= hptr + 1'd1;

	if (reset) begin
		st      <= T_FREE;
		bsy     <= 1'b0;
		req     <= 1'b0;
		request <= 3'd0;
	end
	else case (st)
		T_FREE: begin
			req <= 1'b0;
			if (sel_me) begin
				bsy   <= 1'b1;
				tid   <= sel_id;
				lun   <= 3'd0;
				cdb_n <= 4'd0;
				st    <= atn ? T_MOUT : T_CMD;
			end
		end

		// Message Out: the Identify (and whatever else the initiator sends
		// while ATN stays asserted: taken and ignored)
		T_MOUT: begin
			phase <= PH_MOUT;
			req   <= 1'b1;
			if (ack) begin
				req <= 1'b0;
				if (idata[7]) lun <= idata[2:0];
				if (!atn) st <= T_CMD;
			end
		end

		T_CMD: begin
			phase <= PH_CMD;
			req   <= 1'b1;
			if (ack) begin
				logic [3:0] n;
				req <= 1'b0;
				cdb[cdb_n] <= idata;
				n = cdb_n + 1'd1;
				if (cdb_n == 4'd0)
					cdb_len <= (idata[7:5] == 3'd1 || idata[7:5] == 3'd2) ? 4'd10 : (idata[7:5] == 3'd5) ? 4'd12 : 4'd6;
				cdb_n <= n;
				if (cdb_n != 4'd0 && n == cdb_len) begin
					seq     <= seq + 1'd1;
					request <= RQ_CMD;
					st      <= T_WAIT;
				end
			end
		end

		// the HPS's next step
		T_WAIT: begin
			req <= 1'b0;
			if (mgmt_write && mgmt_address == 4'd8 && hseq == seq) begin
				request <= 3'd0;
				bcnt    <= mgmt_writedata[13:0];
				bidx    <= 14'd0;
				case (mgmt_writedata[15:14])
					2'd0:    st <= (mgmt_writedata[13:0] == 14'd0) ? T_WAIT : T_DIN;
					2'd1:    st <= (mgmt_writedata[13:0] == 14'd0) ? T_WAIT : T_DOUT;
					default: begin status <= mgmt_writedata[7:0]; st <= T_STAT; end
				endcase
				if (mgmt_writedata[15:14] == 2'd0 && mgmt_writedata[13:0] == 14'd0) request <= RQ_DIN;
				if (mgmt_writedata[15:14] == 2'd1 && mgmt_writedata[13:0] == 14'd0) request <= RQ_DOUT;
			end
		end

		// Data In: the buffer's bytes (the word's read takes a clock)
		T_DIN: begin
			req <= 1'b0;
			if (bidx == bcnt) begin
				request <= RQ_DIN;
				st      <= T_WAIT;
			end
			else st <= T_DIN2;
		end
		T_DIN2: begin
			phase <= PH_DIN;
			tdata <= bidx[0] ? bq[15:8] : bq[7:0];
			req   <= 1'b1;
			if (ack && req) begin
				req  <= 1'b0;
				bidx <= bidx + 1'd1;
				st   <= T_DIN;
			end
		end

		// Data Out: into the buffer, two bytes a word
		T_DOUT: begin
			if (bidx == bcnt) begin
				req     <= 1'b0;
				request <= RQ_DOUT;
				st      <= T_WAIT;
			end
			else begin
				phase <= PH_DOUT;
				req   <= 1'b1;
				if (ack && req) begin
					req  <= 1'b0;
					bidx <= bidx + 1'd1;
					if (!bidx[0]) lo <= idata;
					if (bidx[0] || bidx + 1'd1 == bcnt) begin
						b_we <= 1'b1;
						b_wa <= bidx[12:1];
						b_wd <= bidx[0] ? {idata, lo} : {8'h00, idata};
					end
				end
			end
		end

		T_STAT: begin
			phase <= PH_STAT;
			tdata <= status;
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				st  <= T_MIN;
			end
		end

		T_MIN: begin
			phase <= PH_MIN;
			tdata <= 8'h00;                               // COMMAND COMPLETE
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				st  <= T_END;
			end
		end

		T_END: begin
			bsy <= 1'b0;
			st  <= T_FREE;
		end

		default: st <= T_FREE;
	endcase
end

// the HPS's reads (registered: the address is set well ahead of a read)
always @(posedge clk) begin
	case (mgmt_address)
		4'd0:    mgmt_readdata <= {4'hA, seq, 1'b0, lun, 1'b0, tid};
		4'd1:    mgmt_readdata <= {cdb[1],  cdb[0]};
		4'd2:    mgmt_readdata <= {cdb[3],  cdb[2]};
		4'd3:    mgmt_readdata <= {cdb[5],  cdb[4]};
		4'd4:    mgmt_readdata <= {cdb[7],  cdb[6]};
		4'd5:    mgmt_readdata <= {cdb[9],  cdb[8]};
		4'd6:    mgmt_readdata <= {cdb[11], cdb[10]};
		4'd15:   mgmt_readdata <= bq;
		default: mgmt_readdata <= 16'h0000;
	endcase
end

`ifdef SCSI_DEBUG
reg [3:0] dbg_st_d = 4'd0;
always @(posedge clk) begin
	dbg_st_d <= st;
	if (st != dbg_st_d) $display("[scsi] %t st %0d -> %0d", $time, dbg_st_d, st);
end
`endif

endmodule
