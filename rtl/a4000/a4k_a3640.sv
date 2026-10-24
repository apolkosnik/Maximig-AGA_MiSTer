//============================================================================
//  a4k_a3640: the A3640 card's bus converter
//
//  The 68040's only bus slave.  The core (rtl/AP68040) drives the real
//  68040 bus (MC68040UM section 7) on clk_cpu with bclk_en high, so its
//  outputs change, and its inputs are sampled, only at CPU clock edges.
//  This module runs on the base clock and changes state only in the base
//  cycles that end on a CPU clock edge (ce), which makes it synchronous to
//  the CPU's bus: what it registers at such an edge, the core samples at
//  the next.
//
//  * A transfer (TS for one bus clock) becomes one local-bus beat, or four
//    for a line (SIZ 11: the core holds the line's address, the slave
//    counts A3:A2 up from the first long word and wraps inside the line).
//    Byte lanes per MC68040UM table 7-1.  The A3640 converts the 68040's
//    cycles into 68030-style motherboard cycles one long word at a time;
//    each beat costs the card PRE CPU clocks before the motherboard sees
//    it and POST clocks after the motherboard terminates it (the
//    synchronisation of the two buses), then TA, TEA (bus error) and TCI
//    (with the first beat) go to the core for one CPU clock.
//  * A line write: the core puts the next beat's data on the bus only after
//    it has seen the current TA, so the next beat starts a clock later.
//  * Interrupt acknowledge (TT 11, TM = level): TA with AVEC -- Gary
//    autovectors every interrupt on the A3000/A4000.  A breakpoint
//    acknowledge (TM 0) gets TA alone; the core then takes the illegal
//    instruction exception, as a 68040 does.
//  * Nothing else masters the CPU bus, so BG stays asserted and the core
//    owns the bus for good; TBI is never asserted (lines are bursts).
//============================================================================

module a4k_a3640
(
	input             clk,
	input             ce,
	input             reset,

	// the 68040's bus, as the core drives it
	input      [31:0] a,
	input             ts_n,
	input             rw_n,
	input       [1:0] siz,
	input       [1:0] tt,
	input       [2:0] tm,
	input      [31:0] d_cpu,

	// to the core
	output reg [31:0] d_mem,
	output reg        ta_n,
	output reg        tea_n,
	output reg        tci_n,
	output            tbi_n,
	output reg        avec_n,
	output reg        iack7_t = 1'b0, // toggles at each level-7 interrupt acknowledge

	// the card's synchronisation cost per beat, in CPU clocks
	input       [2:0] pre,
	input       [2:0] post,

	// the motherboard's local bus (a4k_lbus)
	output reg        lb_req,
	input             lb_ack,
	output reg [31:2] lb_addr,
	output reg  [3:0] lb_be,
	output reg        lb_we,
	output reg [31:0] lb_wdata,
	output reg        lb_line,
	output reg  [1:0] lb_beat,
	output reg  [1:0] lb_tt,
	output reg  [2:0] lb_tm,
	input      [31:0] lb_rdata,
	input             lb_berr,
	input             lb_ci,

	output      [3:0] dbg_state
);

assign tbi_n = 1'b1;

// byte lanes of a byte, word or long transfer (MC68040UM table 7-1); [3] is
// the byte at offset 0 mod 4, D31-D24
function automatic [3:0] lanes(input [1:0] s, input [1:0] a10);
	case (s)
		2'b01:   lanes = 4'b1000 >> a10;                  // byte
		2'b10:   lanes = a10[1] ? 4'b0011 : 4'b1100;      // word
		default: lanes = 4'b1111;                         // long, line
	endcase
endfunction

localparam [2:0] X_IDLE = 3'd0, X_PRE = 3'd1, X_BUS = 3'd2, X_POST = 3'd3, X_TA = 3'd4, X_GAP = 3'd5, X_ACK = 3'd6;
reg  [2:0] xst;
reg  [2:0] cnt;
reg [31:0] xa;
reg        xline, xrd, xack;
reg  [1:0] beat;
reg [31:0] rdat;
reg        rerr, rci;

assign dbg_state = {xline, xst};

wire [1:0] a32 = xa[3:2] + beat;   // the long word of this beat

task automatic issue();
	lb_addr  <= xline ? {xa[31:4], a32} : xa[31:2];
	lb_beat  <= beat;
	lb_req   <= ~lb_req;
endtask

always @(posedge clk) begin
	if (reset) begin
		xst    <= X_IDLE;
		lb_req <= lb_ack;
		ta_n   <= 1'b1;
		tea_n  <= 1'b1;
		tci_n  <= 1'b1;
		avec_n <= 1'b1;
		beat   <= 2'd0;
		xline  <= 1'b0;
	end
	else if (ce) begin
		// TA/TEA/AVEC/TCI are one CPU clock long
		ta_n   <= 1'b1;
		tea_n  <= 1'b1;
		avec_n <= 1'b1;
		tci_n  <= 1'b1;

		case (xst)
			X_IDLE: if (!ts_n) begin
				// TS: the transfer's address, size, kind and write data are
				// on the bus from the same edge and hold
				xa       <= a;
				xrd      <= rw_n;
				xline    <= (siz == 2'b11);
				beat     <= 2'd0;
				lb_we    <= !rw_n;
				lb_be    <= lanes(siz, a[1:0]);
				lb_wdata <= d_cpu;
				lb_line  <= (siz == 2'b11);
				lb_tt    <= tt;
				lb_tm    <= tm;
				cnt      <= pre;
				if (tt == 2'b11) xst <= X_ACK;
				else if (pre == 3'd0) begin
					lb_addr <= (siz == 2'b11) ? {a[31:4], a[3:2]} : a[31:2];
					lb_beat <= 2'd0;
					lb_req  <= ~lb_req;
					xst     <= X_BUS;
				end
				else xst <= X_PRE;
			end

			X_PRE: begin
				if (cnt <= 3'd1) begin
					issue();
					xst <= X_BUS;
				end
				else cnt <= cnt - 1'd1;
			end

			X_BUS: if (lb_ack == lb_req) begin
				rdat <= lb_rdata;
				rerr <= lb_berr;
				rci  <= lb_ci;
				if (post == 3'd0) begin
					d_mem <= lb_rdata;
					ta_n  <= lb_berr;
					tea_n <= !lb_berr;
					tci_n <= !(lb_ci && beat == 2'd0);
					xst   <= X_TA;
				end
				else begin
					cnt <= post;
					xst <= X_POST;
				end
			end

			X_POST: begin
				if (cnt <= 3'd1) begin
					d_mem <= rdat;
					ta_n  <= rerr;
					tea_n <= !rerr;
					tci_n <= !(rci && beat == 2'd0);
					xst   <= X_TA;
				end
				else cnt <= cnt - 1'd1;
			end

			X_TA: begin
				// the core samples the termination at this edge
				if (xline && beat != 2'd3 && !rerr) begin
					beat <= beat + 1'd1;
					if (xrd) begin
						cnt <= pre;
						if (pre == 3'd0) begin
							lb_addr <= {xa[31:4], xa[3:2] + beat + 2'd1};
							lb_beat <= beat + 1'd1;
							lb_req  <= ~lb_req;
							xst     <= X_BUS;
						end
						else xst <= X_PRE;
					end
					else xst <= X_GAP;
				end
				else xst <= X_IDLE;
			end

			X_GAP: begin
				// a line write: the core has put the next long word on the bus
				lb_wdata <= d_cpu;
				cnt      <= pre;
				if (pre == 3'd0) begin
					issue();
					xst <= X_BUS;
				end
				else xst <= X_PRE;
			end

			X_ACK: begin
				// an interrupt acknowledge: autovectored; a breakpoint: TA
				ta_n   <= 1'b0;
				avec_n <= (tm == 3'd0);
				// the level-7 one (the HRTmon cartridge's NMI): on the 68040 TM
				// carries the level (0: a breakpoint acknowledge)
				if (tm == 3'd7) iack7_t <= ~iack7_t;
				xst    <= X_TA;
				xline  <= 1'b0;
				rerr   <= 1'b0;
			end

			default: xst <= X_IDLE;
		endcase
	end
end

endmodule
