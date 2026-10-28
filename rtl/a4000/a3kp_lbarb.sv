//============================================================================
//  a3kp_lbarb: the AA3000+'s local bus masters
//
//  The CPU card and two DMA masters -- the DSP3210 (U123, the highest
//  priority, as the AA3000's DSP arbiter takes it) and the SuperDMAC's SCSI
//  DMA (through Buster's arbiter, U123 passes SBR on) -- share a4k_lbus's
//  one beat port.  A master offers a beat with a toggle handshake (req
//  toggles with the fields stable; ack toggles back with the data), as the
//  card does to a4k_lbus.  Between beats the bus goes to the highest
//  priority master asking for it; a line transfer of the card (four beats)
//  is not broken up.  The DSP keeps the bus while it holds its request
//  (U123: dspCYC holds with dspBR, so a DSP running from host memory
//  stalls the CPU, as on the real machine): dsp_hold.
//
//  The DSP's beats are marked (lb_dsp): U122 runs them as 32-bit 68030
//  cycles that cannot be sized, so a4k_lbus answers one to an 8- or 16-bit
//  port with a bus error.
//
//  A DMA master's beat is a data access, never a line, given TT 0 and TM 1
//  (a4k_lbus takes TM 5 reads for the cartridge's NMI vector fetch, which
//  only the CPU makes); in the BFG9060's RAM window it reaches the card's
//  memory (lb_local) when that card is the one fitted.
//============================================================================

module a3kp_lbarb
(
	input             clk,
	input             reset,
	input             bfg,            // the BFG9060 is the card: $08000000-$0FFFFFFF is its RAM

	// the CPU card
	input             c_req,
	output reg        c_ack = 1'b0,
	input      [31:2] c_addr,
	input       [3:0] c_be,
	input             c_we,
	input      [31:0] c_wdata,
	input             c_line,
	input       [1:0] c_beat,
	input       [1:0] c_tt,
	input       [2:0] c_tm,
	input             c_local,

	// DMA master 0: the DSP3210 (the highest priority)
	input             d0_req,
	output reg        d0_ack = 1'b0,
	input      [31:2] d0_addr,
	input       [3:0] d0_be,
	input             d0_we,
	input      [31:0] d0_wdata,
	input             d0_hold,        // the DSP keeps the bus between its beats

	// DMA master 1: the SuperDMAC
	input             d1_req,
	output reg        d1_ack = 1'b0,
	input      [31:2] d1_addr,
	input       [3:0] d1_be,
	input             d1_we,
	input      [31:0] d1_wdata,

	// a4k_lbus's beat port (its rdata, berr and ci go to every master)
	output reg        lb_req = 1'b0,
	input             lb_ack,
	output reg [31:2] lb_addr,
	output reg  [3:0] lb_be,
	output reg        lb_we,
	output reg [31:0] lb_wdata,
	output reg        lb_line,
	output reg  [1:0] lb_beat,
	output reg  [1:0] lb_tt,
	output reg  [2:0] lb_tm,
	output reg        lb_local,
	output reg        lb_dsp = 1'b0,  // the beat is the DSP's (an 8- or 16-bit port: a bus error)

	output            dma_owns        // a DMA master has the bus (the card waits)
);

localparam [1:0] M_CARD = 2'd0, M_DSP = 2'd1, M_DMAC = 2'd2;

reg  [1:0] owner = M_CARD;
reg        busy = 1'b0;          // a beat is on a4k_lbus
reg        in_line = 1'b0;       // the card is inside a line transfer

wire c_pend  = c_req  != c_ack;
wire d0_pend = d0_req != d0_ack;
wire d1_pend = d1_req != d1_ack;

assign dma_owns = owner != M_CARD;

function automatic bfg_ram(input [31:2] a);
	bfg_ram = a[31:27] == 5'b00001;
endfunction

always @(posedge clk) begin
	if (reset) begin
		// (the handshakes are their masters' to reset: each sets its request
		// to its acknowledge; a4k_lbus sets its acknowledge to this request)
		busy    <= 1'b0;
		in_line <= 1'b0;
		owner   <= M_CARD;
	end
	else if (busy) begin
		if (lb_ack == lb_req) begin
			busy <= 1'b0;
			case (owner)
				M_DSP:   d0_ack <= d0_req;
				M_DMAC:  d1_ack <= d1_req;
				default: begin
					c_ack   <= c_req;
					in_line <= lb_line && lb_beat != 2'd3;
				end
			endcase
		end
	end
	else begin
		logic [1:0] w;
		logic       go;
		// the grant: the card's line first, then the DSP (and its hold), the
		// DMAC, the card
		go = 1'b1;
		if (in_line)                              w = M_CARD;
		else if (d0_pend || (owner == M_DSP && d0_hold)) w = M_DSP;
		else if (d1_pend)                         w = M_DMAC;
		else                                      w = M_CARD;
		owner <= w;
		case (w)
			M_DSP: if (d0_pend) begin
				lb_addr  <= d0_addr;
				lb_be    <= d0_be;
				lb_we    <= d0_we;
				lb_wdata <= d0_wdata;
				lb_line  <= 1'b0;
				lb_beat  <= 2'd0;
				lb_tt    <= 2'b00;
				lb_tm    <= 3'd1;
				lb_local <= bfg && bfg_ram(d0_addr);
				lb_dsp   <= 1'b1;
				lb_req   <= ~lb_req;
				busy     <= 1'b1;
			end
			M_DMAC: if (d1_pend) begin
				lb_addr  <= d1_addr;
				lb_be    <= d1_be;
				lb_we    <= d1_we;
				lb_wdata <= d1_wdata;
				lb_line  <= 1'b0;
				lb_beat  <= 2'd0;
				lb_tt    <= 2'b00;
				lb_tm    <= 3'd1;
				lb_local <= bfg && bfg_ram(d1_addr);
				lb_dsp   <= 1'b0;
				lb_req   <= ~lb_req;
				busy     <= 1'b1;
			end
			default: if (c_pend) begin
				lb_addr  <= c_addr;
				lb_be    <= c_be;
				lb_we    <= c_we;
				lb_wdata <= c_wdata;
				lb_line  <= c_line;
				lb_beat  <= c_beat;
				lb_tt    <= c_tt;
				lb_tm    <= c_tm;
				lb_local <= c_local;
				lb_dsp   <= 1'b0;
				lb_req   <= ~lb_req;
				busy     <= 1'b1;
			end
		endcase
	end
end

endmodule
