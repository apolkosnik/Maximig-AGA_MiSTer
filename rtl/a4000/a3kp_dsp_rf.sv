//============================================================================
//  a3kp_dsp_rf: the DSP3210's CAU register file (a3kp_dsp3210), 32 words by
//  register code, in MLABs
//
//  Two write ports, a clock each (port B, written later in the instruction
//  cycle, wins when both write one register), and NR combinational read
//  ports -- the flip-flop file it replaces read the same way.  Each port is
//  a pair of banks, one a write port's, and the live value table (a bit a
//  register: the port that wrote it last) picks between them.
//============================================================================

module a3kp_dsp_rf
#(
	parameter int NR = 5
)
(
	input             clk,

	input             wa_en,
	input       [4:0] wa_a,
	input      [31:0] wa_d,
	input             wb_en,
	input       [4:0] wb_a,
	input      [31:0] wb_d,

	input       [4:0] ra [NR],
	output     [31:0] rd [NR]
);

reg [31:0] lvt = 32'd0;
always @(posedge clk) begin
	if (wa_en) lvt[wa_a] <= 1'b0;
	if (wb_en) lvt[wb_a] <= 1'b1;
end

genvar i;
generate for (i = 0; i < NR; i++) begin : g_rd
	wire [31:0] qa, qb;
`ifdef VERILATOR
	reg [31:0] ba [0:31];
	reg [31:0] bb [0:31];
	initial for (int j = 0; j < 32; j++) begin ba[j] = 32'd0; bb[j] = 32'd0; end
	always @(posedge clk) begin
		if (wa_en) ba[wa_a] <= wa_d;
		if (wb_en) bb[wb_a] <= wb_d;
	end
	assign qa = ba[ra[i]];
	assign qb = bb[ra[i]];
`else
	// (an MLAB with its read address and output unregistered: inference
	// folds the copies together and registers the read)
	altdpram #(.width(32), .widthad(5), .numwords(32), .lpm_type("altdpram"),
	           .intended_device_family("Cyclone V"), .ram_block_type("MLAB"),
	           .indata_reg("INCLOCK"), .wraddress_reg("INCLOCK"), .wrcontrol_reg("INCLOCK"),
	           .rdaddress_reg("UNREGISTERED"), .rdcontrol_reg("UNREGISTERED"),
	           .outdata_reg("UNREGISTERED"), .read_during_write_mode_mixed_ports("DONT_CARE"))
	ma (.inclock(clk), .wren(wa_en), .wraddress(wa_a), .data(wa_d), .rdaddress(ra[i]), .q(qa),
	    .aclr(1'b0), .byteena(1'b1), .inclocken(1'b1), .outclock(1'b1), .outclocken(1'b1),
	    .rdaddressstall(1'b0), .rden(1'b1), .sclr(1'b0), .wraddressstall(1'b0));
	altdpram #(.width(32), .widthad(5), .numwords(32), .lpm_type("altdpram"),
	           .intended_device_family("Cyclone V"), .ram_block_type("MLAB"),
	           .indata_reg("INCLOCK"), .wraddress_reg("INCLOCK"), .wrcontrol_reg("INCLOCK"),
	           .rdaddress_reg("UNREGISTERED"), .rdcontrol_reg("UNREGISTERED"),
	           .outdata_reg("UNREGISTERED"), .read_during_write_mode_mixed_ports("DONT_CARE"))
	mb (.inclock(clk), .wren(wb_en), .wraddress(wb_a), .data(wb_d), .rdaddress(ra[i]), .q(qb),
	    .aclr(1'b0), .byteena(1'b1), .inclocken(1'b1), .outclock(1'b1), .outclocken(1'b1),
	    .rdaddressstall(1'b0), .rden(1'b1), .sclr(1'b0), .wraddressstall(1'b0));
`endif
	assign rd[i] = lvt[ra[i]] ? qb : qa;
end endgenerate

endmodule
