// The 8520s (the real ciaa.v and ciab.v with their timers) at the pins: timer
// A and B's outputs on PB6 and PB7 (CRA/CRB bit 1 PBON, bit 2 OUTMODE).  A
// toggle is set high when the timer starts and inverts at each underflow; a
// pulse is high for one E cycle at each underflow; PBON makes the bit an
// output whatever DDRB says, and a PRB read returns it.  Without PBON the
// port is as programmed.  One clock is one 7 MHz cycle, E one in ten.
`timescale 1ns/1ps
module tb;
reg clk = 0;
always #5 clk = ~clk;

reg        reset = 1;
reg        eclk = 0;
integer    ediv = 0;
always @(posedge clk) begin
	ediv <= (ediv == 9) ? 0 : ediv + 1;
	eclk <= (ediv == 9);
end

// CIA-B
reg        b_aen = 0, b_rd = 0, b_wr = 0;
reg  [3:0] b_rs = 0;
reg  [7:0] b_di = 0;
wire [7:0] b_do, b_pb;
wire [7:6] b_pa;
wire       b_irq;
ciab ciab
(
	.clk(clk), .clk7_en(1'b1), .aen(b_aen), .rd(b_rd), .wr(b_wr), .reset(reset), .rs(b_rs),
	.data_in(b_di), .data_out(b_do), .tick(1'b0), .eclk(eclk), .cnt_in(1'b1), .flag(1'b1),
	.irq(b_irq), .porta_in(6'h3F), .porta_out(b_pa), .portb_out(b_pb)
);

// CIA-A
reg        a_aen = 0, a_rd = 0, a_wr = 0;
reg  [3:0] a_rs = 0;
reg  [7:0] a_di = 0;
wire [7:0] a_do;
wire [3:0] a_pa;
wire       a_irq, a_freeze;
ciaa ciaa
(
	.clk(clk), .clk7_en(1'b1), .clk7n_en(1'b1), .aen(a_aen), .rd(a_rd), .wr(a_wr), .reset(reset),
	.rs(a_rs), .data_in(a_di), .data_out(a_do), .tick(1'b0), .eclk(eclk), .cnt_in(1'b1),
	.irq(a_irq), .porta_in(6'h3F), .porta_out(a_pa), .portb_in(8'h00), .kms_level(1'b0),
	.kbd_mouse_type(2'd0), .kbd_mouse_data(8'h00), .freeze(a_freeze), .hrtmon_en(1'b0)
);

integer failures = 0, checks = 0;
task check(input bit ok, input string msg);
	checks = checks + 1;
	if (!ok) begin
		$display("CONTROL FAIL: %s", msg);
		failures = failures + 1;
	end
endtask

task bw(input [3:0] r, input [7:0] v);
	@(negedge clk); b_aen = 1; b_wr = 1; b_rs = r; b_di = v;
	@(negedge clk); b_aen = 0; b_wr = 0;
endtask
task aw(input [3:0] r, input [7:0] v);
	@(negedge clk); a_aen = 1; a_wr = 1; a_rs = r; a_di = v;
	@(negedge clk); a_aen = 0; a_wr = 0;
endtask
task br(input [3:0] r, output [7:0] v);
	@(negedge clk); b_aen = 1; b_rd = 1; b_rs = r;
	#1 v = b_do;
	@(negedge clk); b_aen = 0; b_rd = 0;
endtask
task ar(input [3:0] r, output [7:0] v);
	@(negedge clk); a_aen = 1; a_rd = 1; a_rs = r;
	#1 v = a_do;
	@(negedge clk); a_aen = 0; a_rd = 0;
endtask

// the edges of PB6 and PB7 over n clocks: their times and levels
integer e6[$], e7[$], l6[$], l7[$];
task watch(input integer n);
	reg p6, p7;
	e6.delete(); e7.delete(); l6.delete(); l7.delete();
	p6 = b_pb[6]; p7 = b_pb[7];
	for (integer i = 0; i < n; i++) begin
		@(negedge clk);
		if (b_pb[6] != p6) begin e6.push_back(i); l6.push_back(b_pb[6]); p6 = b_pb[6]; end
		if (b_pb[7] != p7) begin e7.push_back(i); l7.push_back(b_pb[7]); p7 = b_pb[7]; end
	end
endtask

// every interval between consecutive edges, alternately hi then lo clocks
// long after the first edge (a toggle: hi = lo = the period)
task intervals(input string what, ref integer e[$], ref integer l[$], input integer hi, input integer lo);
	check(e.size() >= 6, $sformatf("%s: %0d edges", what, e.size()));
	for (integer i = 1; i < e.size(); i++) begin
		integer want;
		want = l[i - 1] ? hi : lo;
		check(e[i] - e[i - 1] == want, $sformatf("%s: %s for %0d clocks, expected %0d",
		      what, l[i - 1] ? "high" : "low", e[i] - e[i - 1], want));
	end
endtask

reg [7:0] v;

initial begin
	repeat (4) @(negedge clk);
	reset = 0;
	repeat (4) @(negedge clk);

	// control: no PBON, the port as programmed (outputs low, inputs high)
	bw(4'h3, 8'hFF);                     // DDRB: all outputs
	bw(4'h1, 8'h00);
	bw(4'h4, 8'h03); bw(4'h5, 8'h00);    // timer A latch 3: an underflow every 4 E
	bw(4'h6, 8'h05); bw(4'h7, 8'h00);    // timer B latch 5: every 6 E
	bw(4'hE, 8'h11); bw(4'hF, 8'h11);    // START, LOAD
	watch(400);
	check(e6.size() == 0 && e7.size() == 0 && b_pb[7:6] == 2'b00, "no PBON: PB6/PB7 are the port register");
	bw(4'hE, 8'h00); bw(4'hF, 8'h00);

	// toggle: high at the start, inverted at each underflow
	bw(4'h1, 8'h00);
	bw(4'hE, 8'h17); bw(4'hF, 8'h17);    // START, PBON, OUTMODE toggle, LOAD
	@(negedge clk);
	check(b_pb[6] == 1'b1 && b_pb[7] == 1'b1, "toggle: high when the timer starts");
	watch(800);
	intervals("PB6 toggle (timer A, latch 3)", e6, l6, 40, 40);
	intervals("PB7 toggle (timer B, latch 5)", e7, l7, 60, 60);
	// the read of PRB returns the pins
	br(4'h1, v);
	check(v[7:6] == b_pb[7:6], $sformatf("CIA-B PRB read %02X, pins %02X", v, b_pb));

	// stopped: the toggle keeps its level
	bw(4'hE, 8'h06); bw(4'hF, 8'h06);
	v[7:6] = b_pb[7:6];
	watch(400);
	check(e6.size() == 0 && e7.size() == 0 && b_pb[7:6] == v[7:6], "toggle holds while the timer is stopped");

	// pulse: one E cycle high at each underflow
	bw(4'hE, 8'h13); bw(4'hF, 8'h13);    // START, PBON, pulse, LOAD
	watch(800);
	intervals("PB6 pulse (timer A, latch 3)", e6, l6, 10, 30);
	intervals("PB7 pulse (timer B, latch 5)", e7, l7, 10, 50);
	bw(4'hE, 8'h02); bw(4'hF, 8'h02);

	// PBON over an input bit: the timer drives it
	bw(4'h3, 8'h00);                     // DDRB: all inputs
	bw(4'hE, 8'h17);
	@(negedge clk);
	check(b_pb[6] == 1'b1, "PBON over DDRB input: the toggle drives PB6");
	watch(200);
	check(e6.size() >= 4, $sformatf("PBON over DDRB input: PB6 toggles (%0d edges)", e6.size()));
	bw(4'hE, 8'h00);

	// one-shot toggle: high at the start, low at the one underflow, then still
	bw(4'h3, 8'hFF);
	bw(4'hE, 8'h1F);                     // START, PBON, toggle, RUNMODE one-shot, LOAD
	@(negedge clk);
	check(b_pb[6] == 1'b1, "one-shot toggle: high when started");
	watch(400);
	check(e6.size() == 1 && l6[0] == 0, $sformatf("one-shot toggle: %0d edges after the start, the last to %0d",
	      e6.size(), e6.size() ? l6[e6.size() - 1] : -1));
	br(4'hE, v);
	check(v[0] == 1'b0, $sformatf("one-shot: the timer stopped (CRA %02X)", v));
	bw(4'hE, 8'h00);

	// CIA-A: the same timer output read back through PRB (the parallel port)
	aw(4'h3, 8'h00);
	aw(4'h4, 8'h03); aw(4'h5, 8'h00);
	aw(4'hE, 8'h17);
	ar(4'h1, v);
	check(v[6] == 1'b1, $sformatf("CIA-A PRB with PBON toggle started: %02X", v));
	repeat (70) @(negedge clk);           // the start's two E cycles, then 4 E to the first underflow
	ar(4'h1, v);
	check(v[6] == 1'b0, $sformatf("CIA-A PRB after one underflow: %02X", v));
	aw(4'hE, 8'h00);
	ar(4'h1, v);
	check(v[6] == 1'b0, $sformatf("CIA-A PRB, no PBON, DDRB input: %02X", v));

	if (failures == 0) $display("PASS: %0d checks, PB6/PB7 timer outputs (toggle, pulse, one-shot, DDRB, PRB)", checks);
	else               $display("FAIL: %0d of %0d", failures, checks);
	$finish;
end
endmodule
