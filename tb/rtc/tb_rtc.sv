// The RP5C01 (a4k_rtc) as the CPU sees its registers: the hour registers in
// 12- and 24-hour mode written a digit at a time in either order (every
// start hour against every target hour), the 12-hour count over 11 -> 12
// (AM/PM, midnight carrying into the date) and 12 -> 01, the 24-hour count
// over midnight, the MiSTer's time loaded in 12-hour mode, and a change of
// mode converting the hour (WinUAE: 1 PM reads 13).
`timescale 1ns/1ps
module tb;
reg clk = 0;
always #5 clk = ~clk;

reg         reset = 1, cs = 0, we = 0;
reg  [64:0] hps_rtc = 0;
reg   [3:0] reg_sel = 0, wdata = 0;
wire  [3:0] rdata;

a4k_rtc dut
(
	.clk     (clk),
	.reset   (reset),
	.ntsc    (1'b0),
	.hps_rtc (hps_rtc),
	.cs      (cs),
	.we      (we),
	.reg_sel (reg_sel),
	.wdata   (wdata),
	.rdata   (rdata)
);

integer failures = 0;

task check(input bit ok, input string msg);
	if (!ok) begin
		if (failures < 40) $display("CONTROL FAIL: %s", msg);
		failures = failures + 1;
	end
endtask

task wr(input [3:0] a, input [3:0] d);
	@(negedge clk); cs = 1; we = 1; reg_sel = a; wdata = d;
	@(negedge clk); cs = 0; we = 0;
endtask

task rd(input [3:0] a, output [3:0] d);
	@(negedge clk); reg_sel = a;
	#1 d = rdata;
endtask

function automatic [7:0] bcd(input integer v);
	bcd = 8'((v / 10) << 4 | (v % 10));
endfunction

// the MiSTer's time: 24-hour BCD
task load(input integer h, input integer m, input integer s, input integer day, input integer wd);
	@(negedge clk);
	hps_rtc[7:0]   = bcd(s);
	hps_rtc[15:8]  = bcd(m);
	hps_rtc[23:16] = bcd(h);
	hps_rtc[31:24] = bcd(day);
	hps_rtc[39:32] = 8'h05;
	hps_rtc[47:40] = 8'h26;
	hps_rtc[50:48] = 3'(wd);
	hps_rtc[64]    = !hps_rtc[64];
	repeat (2) @(negedge clk);
endtask

// 12-hour registers of a 24-hour hour: {PM, tens}, ones
function automatic [7:0] reg12(input integer h);
	integer h12;
	h12 = h % 12;
	if (h12 == 0) h12 = 12;
	reg12 = {4'(h12 / 10 + (h >= 12 ? 2 : 0)), 4'(h12 % 10)};
endfunction

task set_mode(input bit h24);
	wr(4'hD, 4'h9);          // bank 1, the timer running
	wr(4'hA, {3'b000, h24});
	wr(4'hD, 4'h8);          // bank 0
endtask

// one second on: the clock's divider runs out (28375160 clocks, PAL)
task one_second;
	repeat (28375162) @(negedge clk);
endtask

integer h0, h1, order, total;
reg [3:0] lo, hi, d_lo, d_hi, s_lo, s_hi, m_lo, m_hi, wd;
reg [7:0] r;

initial begin
	repeat (3) @(negedge clk);
	reset = 0;

	// 12-hour mode: every start hour, every target hour, ones or tens first
	set_mode(1'b0);
	total = 0;
	for (h0 = 0; h0 < 24; h0 = h0 + 1)
		for (h1 = 0; h1 < 24; h1 = h1 + 1)
			for (order = 0; order < 2; order = order + 1) begin
				load(h0, 30, 0, 10, 2);
				r = reg12(h1);
				if (order == 0) begin wr(4, r[3:0]); wr(5, r[7:4]); end
				else            begin wr(5, r[7:4]); wr(4, r[3:0]); end
				rd(4, lo); rd(5, hi);
				check({hi, lo} == r, $sformatf("12-hour write from %0d to %0d (%s first): read %x%x, wrote %x",
				      h0, h1, order ? "tens" : "ones", hi, lo, r));
				total = total + 1;
			end

	// 24-hour mode: the same
	set_mode(1'b1);
	for (h0 = 0; h0 < 24; h0 = h0 + 1)
		for (h1 = 0; h1 < 24; h1 = h1 + 1)
			for (order = 0; order < 2; order = order + 1) begin
				load(h0, 30, 0, 10, 2);
				r = bcd(h1);
				if (order == 0) begin wr(4, r[3:0]); wr(5, r[7:4]); end
				else            begin wr(5, r[7:4]); wr(4, r[3:0]); end
				rd(4, lo); rd(5, hi);
				check({hi, lo} == r, $sformatf("24-hour write from %0d to %0d (%s first): read %x%x, wrote %x",
				      h0, h1, order ? "tens" : "ones", hi, lo, r));
				total = total + 1;
			end

	// the MiSTer's time in 12-hour mode
	set_mode(1'b0);
	for (h0 = 0; h0 < 24; h0 = h0 + 1) begin
		load(h0, 0, 0, 10, 2);
		rd(4, lo); rd(5, hi);
		r = reg12(h0);
		check({hi, lo} == r, $sformatf("12-hour load of %0d: read %x%x, expected %x", h0, hi, lo, r));
	end

	// a change of mode: the hour as the other mode reads it, both ways
	for (h0 = 0; h0 < 24; h0 = h0 + 1) begin
		set_mode(1'b1);
		load(h0, 0, 0, 10, 2);
		set_mode(1'b0);
		rd(4, lo); rd(5, hi);
		r = reg12(h0);
		check({hi, lo} == r, $sformatf("24 -> 12-hour of %0d: read %x%x, expected %x", h0, hi, lo, r));
		set_mode(1'b1);
		rd(4, lo); rd(5, hi);
		check({hi, lo} == bcd(h0), $sformatf("12 -> 24-hour of %0d: read %x%x", h0, hi, lo));
	end
	set_mode(1'b0);

	// the 12-hour count: 11:59:59 AM -> 12 PM, 11:59:59 PM -> 12 AM (the
	// next day), 12:59:59 AM -> 1 AM, 9:59:59 PM -> 10 PM
	load(11, 59, 59, 10, 2);
	one_second;
	rd(4, lo); rd(5, hi); rd(7, d_lo); rd(8, d_hi); rd(6, wd);
	rd(0, s_lo); rd(1, s_hi); rd(2, m_lo); rd(3, m_hi);
	check({hi, lo} == 8'h32 && {d_hi, d_lo} == 8'h10 && wd == 4'd2 && {m_hi, m_lo, s_hi, s_lo} == 16'h0000,
	      $sformatf("11:59:59 AM + 1 s: %x%x:%x%x:%x%x day %x%x wday %0d", hi, lo, m_hi, m_lo, s_hi, s_lo, d_hi, d_lo, wd));

	load(23, 59, 59, 10, 2);
	one_second;
	rd(4, lo); rd(5, hi); rd(7, d_lo); rd(8, d_hi); rd(6, wd);
	check({hi, lo} == 8'h12 && {d_hi, d_lo} == 8'h11 && wd == 4'd3,
	      $sformatf("11:59:59 PM + 1 s: hour %x%x day %x%x wday %0d", hi, lo, d_hi, d_lo, wd));

	load(0, 59, 59, 10, 2);
	one_second;
	rd(4, lo); rd(5, hi); rd(7, d_lo); rd(8, d_hi);
	check({hi, lo} == 8'h01 && {d_hi, d_lo} == 8'h10,
	      $sformatf("12:59:59 AM + 1 s: hour %x%x day %x%x", hi, lo, d_hi, d_lo));

	load(21, 59, 59, 10, 2);
	one_second;
	rd(4, lo); rd(5, hi);
	check({hi, lo} == 8'h30, $sformatf("9:59:59 PM + 1 s: hour %x%x", hi, lo));

	// written in 12-hour mode, then counted: 11:59:59 PM set by the CPU
	load(3, 0, 0, 10, 2);
	wr(0, 9); wr(1, 5); wr(2, 9); wr(3, 5); wr(5, 3); wr(4, 1);
	one_second;
	rd(4, lo); rd(5, hi); rd(7, d_lo); rd(8, d_hi);
	check({hi, lo} == 8'h12 && {d_hi, d_lo} == 8'h11,
	      $sformatf("11:59:59 PM written, + 1 s: hour %x%x day %x%x", hi, lo, d_hi, d_lo));

	// the 24-hour count over midnight
	set_mode(1'b1);
	load(23, 59, 59, 10, 2);
	one_second;
	rd(4, lo); rd(5, hi); rd(7, d_lo); rd(8, d_hi); rd(6, wd);
	check({hi, lo} == 8'h00 && {d_hi, d_lo} == 8'h11 && wd == 4'd3,
	      $sformatf("23:59:59 + 1 s: hour %x%x day %x%x wday %0d", hi, lo, d_hi, d_lo, wd));

	load(9, 59, 59, 10, 2);
	one_second;
	rd(4, lo); rd(5, hi);
	check({hi, lo} == 8'h10, $sformatf("09:59:59 + 1 s: hour %x%x", hi, lo));

	if (failures == 0) $display("PASS: %0d hour writes (12- and 24-hour, both orders), 12-hour loads, the 12- and 24-hour counts", total);
	else               $display("FAIL: %0d", failures);
	$finish;
end
endmodule
