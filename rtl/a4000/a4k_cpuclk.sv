//============================================================================
//  a4k_cpuclk: the CPU card's clock
//
//  The 68040 of the A3640 runs from the card's own oscillator; its bus
//  clock is the motherboard's CPUCLK, 25 MHz.  Here the CPU clock is the
//  56.75 MHz base clock (clk_57) with pulses removed in a clock-control
//  block: a phase accumulator lets N of every D base pulses through, so
//  the CPU and the local bus logic see N/D of the base rate on average
//  while every CPU clock period is one or more whole base periods.  Every
//  path between the gated clock and clk_57 is then an ordinary clk_57
//  path for timing analysis.
//
//  cpu_ce is the register that enables the next base pulse: logic on
//  clk_57 that acts "if (cpu_ce)" changes state at exactly the edges where
//  the CPU's registers do, so it is synchronous to the CPU's bus.
//
//  speed (N/D of 56.75 MHz):
//    0  4/9   25.2 MHz   A3640 stock
//    1  7/12  33.1 MHz
//    2  5/7   40.5 MHz
//    3  8/9   50.4 MHz
//    4  1/1   56.75 MHz
//============================================================================

module a4k_cpuclk
(
	input            clk_57,
	input      [2:0] speed,
	output reg       cpu_ce = 1'b0,
	output           clk_cpu
);

reg [3:0] num, den;
always @(*) begin
	case (speed)
		3'd0:    begin num = 4'd4; den = 4'd9;  end
		3'd1:    begin num = 4'd7; den = 4'd12; end
		3'd2:    begin num = 4'd5; den = 4'd7;  end
		3'd3:    begin num = 4'd8; den = 4'd9;  end
		default: begin num = 4'd1; den = 4'd1;  end
	endcase
end

// acc stays below den; a pulse goes through whenever adding num reaches den
reg  [4:0] acc = 5'd0;
wire [4:0] sum = acc + num;
always @(posedge clk_57) begin
	if (sum >= {1'b0, den}) begin
		acc    <= sum - {1'b0, den};
		cpu_ce <= 1'b1;
	end
	else begin
		acc    <= sum;
		cpu_ce <= 1'b0;
	end
	// a speed change may leave acc above the new den: start over
	if (acc >= {1'b0, den}) acc <= 5'd0;
end

`ifdef VERILATOR
	// the clock-control block: enable registered on the falling edge, ANDed
	// with the clock (glitch-free because it changes only while clk_57 is low)
	reg ena_l = 1'b0;
	always @(negedge clk_57) ena_l <= cpu_ce;
	assign clk_cpu = clk_57 & ena_l;
`else
	cyclonev_clkena #(
		.clock_type("Global Clock"),
		.ena_register_mode("falling edge"),
		.lpm_type("cyclonev_clkena")
	) clkena (
		.inclk(clk_57),
		.ena(cpu_ce),
		.enaout(),
		.outclk(clk_cpu)
	);
`endif

endmodule
