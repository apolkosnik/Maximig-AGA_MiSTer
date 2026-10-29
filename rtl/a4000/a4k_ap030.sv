//============================================================================
//  a4k_ap030: the AA3000+'s own processor, a 68030 (rtl/AP68030) on the
//  motherboard's local bus
//
//  The core drives the real MC68030 bus (MC68030UM section 7) on clk, using
//  both of its edges (the half-clock bus states); this module runs on clk's
//  rising edges, an asynchronous bus slave to it:
//
//  * A cycle (AS and DS: a write's data is on the bus with DS) becomes one
//    local-bus beat, the port 32 bits wide: DSACK1/DSACK0 both asserted with
//    the data, or BERR alone for a bus error, held until AS is negated.  The
//    beat's byte lanes are the operand's bytes in this long word (SIZ, A1:A0;
//    the 68030 sizes a misaligned operand into further cycles itself), its
//    TM the function code (the 68040's TM numbers the same spaces).  Bursts
//    are not acknowledged (CBACK), so a line fills one long word a cycle.
//  * CPU space (FC 7): an interrupt acknowledge (A19:A16 = F) is
//    autovectored (AVEC), as Gary does every interrupt on the A3000; a
//    breakpoint acknowledge, an access-level or a coprocessor cycle gets a
//    bus error -- no 68882 is fitted, so a coprocessor instruction takes
//    the F-line exception, as on an A3000 without one.
//  * CIIN goes with the data of a cache-inhibited beat.
//============================================================================

module a4k_ap030
(
	input             clk,
	input             reset,

	// the 68030's bus, as the core drives it
	input      [31:0] a,
	input       [2:0] fc,
	input       [1:0] siz,
	input             rw,
	input             as_n,
	input             ds_n,
	input      [31:0] d_cpu,
	// to the core
	output reg [31:0] d_mem,
	output reg  [1:0] dsack_n = 2'b11,
	output reg        berr_n = 1'b1,
	output reg        avec_n = 1'b1,
	output reg        ciin_n = 1'b1,
	output reg        iack7_t = 1'b0,  // toggles at each level-7 interrupt acknowledge

	// the motherboard's local bus (a4k_lbus)
	output reg        lb_req = 1'b0,
	input             lb_ack,
	output reg [31:2] lb_addr,
	output reg  [3:0] lb_be,
	output reg        lb_we,
	output reg [31:0] lb_wdata,
	output reg  [2:0] lb_tm,
	input      [31:0] lb_rdata,
	input             lb_berr,
	input             lb_ci
);

// the operand's bytes in this long word: from A1:A0, SIZ of them (00: four)
// or to the long word's end; [3] is the byte at offset 0, D31-D24
function automatic [3:0] lanes(input [1:0] s, input [1:0] a10);
	logic [2:0] n, m, k;
	n = (s == 2'b00) ? 3'd4 : {1'b0, s};
	m = 3'd4 - {1'b0, a10};
	k = (n < m) ? n : m;
	lanes = 4'((5'b00001 << k) - 5'd1) << (3'd4 - {1'b0, a10} - k);
endfunction

localparam [1:0] X_IDLE = 2'd0, X_BUS = 2'd1, X_END = 2'd2;
reg [1:0] xst = X_IDLE;

always @(posedge clk) begin
	if (reset) begin
		xst     <= X_IDLE;
		lb_req  <= lb_ack;
		dsack_n <= 2'b11;
		berr_n  <= 1'b1;
		avec_n  <= 1'b1;
		ciin_n  <= 1'b1;
	end
	else case (xst)
		X_IDLE: if (!as_n && !ds_n) begin
			if (fc == 3'd7) begin
				// CPU space
				if (a[19:16] == 4'hF) begin
					avec_n <= 1'b0;
					if (a[3:1] == 3'd7) iack7_t <= ~iack7_t;
				end
				else berr_n <= 1'b0;
				xst <= X_END;
			end
			else begin
				lb_addr  <= a[31:2];
				lb_be    <= lanes(siz, a[1:0]);
				lb_we    <= !rw;
				lb_wdata <= d_cpu;
				lb_tm    <= fc;
				lb_req   <= ~lb_req;
				xst      <= X_BUS;
			end
		end

		X_BUS: if (lb_ack == lb_req) begin
			d_mem   <= lb_rdata;
			ciin_n  <= !lb_ci;
			if (lb_berr) berr_n  <= 1'b0;
			else         dsack_n <= 2'b00;
			xst <= X_END;
		end

		X_END: if (as_n) begin
			// the cycle ends with AS
			dsack_n <= 2'b11;
			berr_n  <= 1'b1;
			avec_n  <= 1'b1;
			ciin_n  <= 1'b1;
			xst     <= X_IDLE;
		end

		default: xst <= X_IDLE;
	endcase
end

endmodule
