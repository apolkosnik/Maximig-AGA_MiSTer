// The DSP3210 bench: the real core (a3kp_dsp3210) on an external memory of
// 1 MB at 0x00000000 (big-endian, the core's bus handshake answered after
// `waits` clocks), bus errors at 0x40000000 and up; the bench (sim_dsp.cpp)
// loads the program, drives the interrupt pins and reads the memory back.
module tb_dsp
(
	input             clk,
	input             reset,
	input             ce,
	input       [3:0] waits,
	input             ir0_n,
	input             ir1_n,
	input       [7:0] bio_in,
	output            iack0,
	output            iack1,
	output     [31:0] pc,
	output            retire,
	output            halted,
	output            hold
);

wire        m_req, m_we, m_berr;
reg         m_ack = 1'b0;
wire [31:2] m_addr;
wire  [3:0] m_be;
wire [31:0] m_wdata;
reg  [31:0] m_rdata;
reg         berr_r = 1'b0;
wire [7:0]  bio_out, bio_oe;

a3kp_dsp3210 dsp
(
	.clk(clk), .ce(ce), .reset(reset),
	.m_req(m_req), .m_ack(m_ack), .m_addr(m_addr), .m_be(m_be), .m_we(m_we),
	.m_wdata(m_wdata), .m_rdata(m_rdata), .m_berr(berr_r), .m_hold(hold),
	.ir0_n(ir0_n), .ir1_n(ir1_n), .iack0(iack0), .iack1(iack1),
	.bio_in(bio_in), .bio_out(bio_out), .bio_oe(bio_oe),
	.dbg_pc(pc), .dbg_retire(retire), .dbg_halted(halted)
);

reg [31:0] mem [0:262143] /*verilator public_flat_rw*/;
reg  [3:0] wcnt = 4'd0;
reg        busy = 1'b0;

always @(posedge clk) begin
	if (reset) begin
		busy <= 1'b0;
		m_ack <= m_req;
	end
	else if (!busy && m_req != m_ack) begin
		busy <= 1'b1;
		wcnt <= waits;
	end
	else if (busy) begin
		if (wcnt != 4'd0) wcnt <= wcnt - 1'd1;
		else begin
			busy   <= 1'b0;
			berr_r <= m_addr[31:30] != 2'b00;
			if (m_addr[31:30] == 2'b00) begin
				m_rdata <= mem[m_addr[19:2]];
				if (m_we) for (int b = 0; b < 4; b++)
					if (m_be[3 - b]) mem[m_addr[19:2]][31 - 8*b -: 8] <= m_wdata[31 - 8*b -: 8];
			end
			else m_rdata <= 32'hFFFFFFFF;
			m_ack <= m_req;
		end
	end
end

assign m_berr = berr_r;

endmodule
