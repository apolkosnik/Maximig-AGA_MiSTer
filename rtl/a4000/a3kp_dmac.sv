//============================================================================
//  a3kp_dmac: the AA3000's DMAC+ (the A3000+ SuperDMAC) and the DSP3210's
//  host control latch
//
//  The local bus (a4k_lbus) hands it the beats to $DD0000-$DD1FFF.  The
//  SuperDMAC decodes A6:A2 of each long word (mirrored every $80 below the
//  DSP latch's A7): its registers are 32-bit, behaving as whole long words
//  whatever the access size (A3000+ spec 2.4); the WD33C93's two byte
//  registers sit in its space (a3kp_sbic, the SBIC port here).
//
//    $00/$02  DAWR    (A3000 DMAC, unused; read back)
//    $04/$06  WTC     word transfer count: obsolete; reads 0 (bit 2 fixed at
//                     zero tells the new DMAC from the old, spec 2.4.1)
//    $08/$0A  CONTR   8 DMAENA (read), 4 PREST, 2 INTENA, 1 DMADIR
//    $0C/$0E  ACR     DMA start address, rounded down to a word
//    $10/$12  ST_DMA  strobe: start the DMA
//    $14/$16  FLUSH   strobe: flush the FIFO (SCSI to memory)
//    $18/$1A  CLR_INT strobe: clear the interrupts
//    $1C/$1E  ISTR    7 INT_F, 6 INT_S, 5 E_INT, 4 INT_P, 1 FF, 0 FE
//    $3C/$3E  SP_DMA  strobe: stop the DMA
//    $40/$41  SASR    (long write / byte read: the A3000's mapping)
//    $43/$47  SCMD    WD33C93 data register (byte)
//    $49      SASR    WD33C93 address register (byte)
//    $5C      the DSP status (long word: the DMAC+'s DSP control register's
//             read half; the byte is at $5F)
//
//  The DSP control latch is U124 (AA3000 rev 2, Haynie 1992 with the 2020/21
//  fixes): a write with A7 set ($DD0080) latches D7 (DSP reset, low: in
//  reset), D5/D4 (INT6/INT2 to the CPU, low: masked), D1/D0 (DSP INT1/INT0,
//  low: asserted until the DSP acknowledges with its IACK).  The system
//  reset (RST, which the RESET instruction drives on the A3000) puts the
//  DSP in reset, masks both host interrupts and drops both DSP interrupts.
//  U124 is an 8-bit port (DSACK0): a wider write is sized down to its
//  bytes, the last one (the lowest lane written) stays latched.  A read
//  with A7 set is answered by nobody (U124 only passes A7-clear selects on
//  to the DMAC): a4k_lbus leaves it to Gary's timeout.
//
//  The status at $DD005C (Haynie's DSP programming notes; WinUAE dsp_read):
//    7 DSP RESET (1: running)   5 MASK INT6 (1: enabled)   4 MASK INT2
//    3 CPU INT6 (0: the DSP pulls level 6)   2 CPU INT2 (0: level 2)
//    1 DSP INT1 (0: pending)    0 DSP INT0 (0: pending)
//============================================================================

module a3kp_dmac
(
	input             clk,
	input             reset,          // the system reset (RST)

	// register port (a4k_lbus): a toggle handshake; rdata stable until the next request
	input             req,
	output reg        ack = 1'b0,
	input       [7:2] addr,
	input       [3:0] be,
	input             we,
	input      [31:0] wdata,
	output reg [31:0] rdata,

	// the WD33C93 (a3kp_sbic): one byte register cycle per request
	output reg        sbic_req = 1'b0,
	input             sbic_ack,
	output reg        sbic_a0,        // 0 SASR (aux status / address), 1 SCMD (data)
	output reg        sbic_we,
	output reg  [7:0] sbic_wdata,
	input       [7:0] sbic_rdata,
	input             sbic_intrq,     // the SBIC's interrupt request (active high)
	output            sbic_reset,     // PREST

	// the DSP3210
	output            dsp_reset,      // held in reset
	output            dsp_int0,       // INT0/INT1 to the DSP (active high here)
	output            dsp_int1,
	input             dsp_iack0,      // the DSP's acknowledges
	input             dsp_iack1,
	input             dsp_ci2,        // the DSP pulls CPU level 2 / 6 (BIO7 / BIO6 low)
	input             dsp_ci6,

	// the host interrupts
	output            int2,
	output            int6
);

//----------------------------------------------------------------------------
// U124: the DSP control latch
//----------------------------------------------------------------------------
reg dl_rst = 1'b1;     // dspRST: the DSP held in reset
reg dl_mi2 = 1'b1;     // dspMI2: level 2 from the DSP inhibited
reg dl_mi6 = 1'b1;
reg dl_i0  = 1'b0;     // dspINT0 asserted
reg dl_i1  = 1'b0;

assign dsp_reset = dl_rst;
assign dsp_int0  = dl_i0;
assign dsp_int1  = dl_i1;

// U701: INT6/INT2 driven from the DSP's lines where not inhibited
wire dsp_int2 = dsp_ci2 && !dl_mi2;
wire dsp_int6 = dsp_ci6 && !dl_mi6;

wire [7:0] dsp_status = {!dl_rst, 1'b0, !dl_mi6, !dl_mi2, !dsp_ci6, !dsp_ci2, !dl_i1, !dl_i0};

// the byte the latch keeps from a write: the last of the sized-down cycles,
// the lowest lane written
function automatic [7:0] last_byte(input [3:0] b, input [31:0] d);
	if (b[0])      last_byte = d[7:0];
	else if (b[1]) last_byte = d[15:8];
	else if (b[2]) last_byte = d[23:16];
	else           last_byte = d[31:24];
endfunction

//----------------------------------------------------------------------------
// the SuperDMAC registers
//----------------------------------------------------------------------------
reg [15:0] dawr = 16'd0;
reg  [7:0] contr = 8'd0;       // CONTR's writable bits
reg [31:0] acr = 32'd0;
reg        dma_on = 1'b0;      // DMAENA
reg        istr_int = 1'b0;    // a registered SCSI interrupt (INT_F/INT_S/E_INT), until CLR_INT

assign sbic_reset = contr[4];

// the SBIC's interrupt is registered in ISTR (INT_F, INT_S, E_INT follow
// it); INT_P is it qualified by INTENA, and drives INT2
wire scsi_int = istr_int || sbic_intrq;
wire int_p    = scsi_int && contr[2];
wire [7:0] istr = {scsi_int, scsi_int, scsi_int, int_p, 2'b00, 1'b0, !dma_on};

assign int2 = int_p || dsp_int2;
assign int6 = dsp_int6;

// the register long word at offset a (A7 clear)
function automatic [31:0] reg_rd(input [6:2] a);
	case (a)
		5'h00:   reg_rd = {16'd0, dawr};
		5'h01:   reg_rd = 32'd0;                                 // WTC: not in the DMAC+
		5'h02:   reg_rd = {23'd0, dma_on, contr};
		5'h03:   reg_rd = acr;
		5'h07:   reg_rd = {24'd0, istr};
		5'h17:   reg_rd = {16'hFFFF, 8'h00, dsp_status};         // $5C: the DSP status at $5F
		default: reg_rd = 32'd0;                                 // strobes read 0
	endcase
endfunction

localparam [1:0] S_IDLE = 2'd0, S_SBIC = 2'd1;
reg [1:0] st = S_IDLE;

always @(posedge clk) begin
	// the DSP's acknowledges drop its interrupts
	if (dsp_iack0) dl_i0 <= 1'b0;
	if (dsp_iack1) dl_i1 <= 1'b0;
	if (sbic_intrq) istr_int <= 1'b1;

	if (reset) begin
		dl_rst   <= 1'b1;
		dl_mi2   <= 1'b1;
		dl_mi6   <= 1'b1;
		dl_i0    <= 1'b0;
		dl_i1    <= 1'b0;
		contr    <= 8'd0;
		dma_on   <= 1'b0;
		istr_int <= 1'b0;
		// (the handshake is the local bus's to reset: it sets its request to
		// this acknowledge)
		st       <= S_IDLE;
	end
	else case (st)
		S_IDLE: if (req != ack) begin
			rdata <= reg_rd(addr[6:2]);
			if (addr[7]) begin
				// U124 (reads with A7 set never get here)
				if (we) begin
					logic [7:0] d;
					d = last_byte(be, wdata);
					dl_rst <= !d[7];
					dl_mi6 <= !d[5];
					dl_mi2 <= !d[4];
					dl_i1  <= !d[1] && !dsp_iack1;
					dl_i0  <= !d[0] && !dsp_iack0;
				end
				ack <= req;
			end
			else if (addr[6:2] == 5'h10 || addr[6:2] == 5'h11 || addr[6:2] == 5'h12) begin
				// $40-$4B: the WD33C93.  $40 long write / $41: SASR; $43, $47:
				// SCMD; $49: SASR.  A long word write at $40 writes SASR with its
				// low byte (A3000 software's long-word SASR access).
				sbic_a0    <= (addr[6:2] == 5'h10) ? (be[0] && !be[2]) :      // $43 (lane 0) is SCMD, $41 (lane 2) SASR
				              (addr[6:2] == 5'h11) ? 1'b1 : 1'b0;           // $47 SCMD, $49 SASR
				sbic_we    <= we;
				sbic_wdata <= (addr[6:2] == 5'h10) ? ((be[0] && !be[2]) ? wdata[7:0] : (be[3] ? wdata[7:0] : wdata[23:16])) :
				              (addr[6:2] == 5'h11) ? wdata[7:0] : wdata[23:16];
				sbic_req   <= ~sbic_req;
				st         <= S_SBIC;
			end
			else begin
				if (we) case (addr[6:2])
					5'h00: dawr  <= wdata[15:0];
					5'h02: contr <= wdata[7:0];
					5'h03: acr   <= {wdata[31:1], 1'b0};
					default: ;
				endcase
				// the strobes act on a read or a write
				case (addr[6:2])
					5'h04: dma_on <= 1'b1;                       // ST_DMA
					5'h06: istr_int <= 1'b0;                     // CLR_INT
					5'h0F: dma_on <= 1'b0;                       // SP_DMA
					default: ;
				endcase
				ack <= req;
			end
		end

		S_SBIC: if (sbic_ack == sbic_req) begin
			// the SBIC's byte, on every lane
			rdata <= {4{sbic_rdata}};
			ack   <= req;
			st    <= S_IDLE;
		end

		default: st <= S_IDLE;
	endcase
end

endmodule
