// Denise (the real denise.v and its blocks) on its register bus: what a
// copper or CPU write to BPLxDAT or SPRxDATx loads in the 32- and 64-wide
// fetch modes.  FMODE 2/3 take the chip bus's previous word as the first 16
// bits (WinUAE wordto64convert, chipset_latch_rw): the last DMA word -- the
// last of a wide bitplane or sprite fetch -- and not the CPU's cycles, nor
// the SDRAM's burst words (chip48) of some later, unrelated read.
`timescale 1ns/1ps
module tb;
reg clk = 0;
always #5 clk = ~clk;

reg reset_n = 0, reset = 1;
wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk clocks
(
	.clk_28   (clk),
	.clk7_en  (clk7_en),
	.clk7n_en (clk7n_en),
	.c1       (c1),
	.c3       (c3),
	.cck      (cck),
	.eclk     (eclk),
	.reset_n  (reset_n)
);

reg   [8:1] addr = 8'hFF;
reg  [15:0] data = 16'h0000;
reg  [47:0] chip48 = 48'h0;
reg         dbr = 0, dmald = 0;
wire [15:0] data_out;
wire  [7:0] red, green, blue;
wire        hires, shres;

denise dut
(
	.clk                        (clk),
	.clk7_en                    (clk7_en),
	.c1                         (c1),
	.c3                         (c3),
	.cck                        (cck),
	.reset                      (reset),
	.strhor                     (1'b0),
	.bitplane_dma               (1'b0),
	.bitplane_fetch_phase       (1'b0),
	.bitplane_fetch_phase_valid (1'b0),
	.bitplane_fetch_unit_start  (1'b0),
	.reg_address_in             (addr),
	.data_in                    (data),
	.chip48                     (chip48),
	.dmald                      (dmald),
	.dbr                        (dbr),
	.data_out                   (data_out),
	.blank                      (1'b0),
	.red                        (red),
	.green                      (green),
	.blue                       (blue),
	.a1k                        (1'b0),
	.ecs                        (1'b1),
	.aga                        (1'b1),
	.hires                      (hires),
	.shres                      (shres)
);

integer failures = 0, checks = 0;

task check(input [63:0] got, input [63:0] exp, input string msg);
	checks = checks + 1;
	if (got !== exp) begin
		$display("CONTROL FAIL: %s: loaded %016h, expected %016h", msg, got, exp);
		failures = failures + 1;
	end
endtask

// one 7 MHz bus cycle: the register, its data, DMA or not; chip48 is the
// SDRAM's burst words as they are at the shifters' load (half a cycle on)
task cyc(input [8:0] a, input [15:0] d, input bit is_dbr, input bit is_dmald, input [47:0] c48);
	@(negedge clk);
	while (!clk7_en) @(negedge clk);
	addr = a[8:1]; data = d; dbr = is_dbr; dmald = is_dmald; chip48 = c48;
	@(negedge clk);
	addr = 8'hFF; dbr = 0; dmald = 0;
	repeat (6) @(negedge clk);
endtask

// a CPU write: the chip bus is the CPU's (no DMA); the SDRAM's burst words
// are whatever its last read left (set here to a pattern that must not show)
task cpu(input [8:0] a, input [15:0] d);
	cyc(a, d, 1'b0, 1'b0, 48'hAAAA_BBBB_CCCC);
endtask

// a DMA word for another chip (audio, disk, blitter, copper fetches)
task dma(input [15:0] d);
	cyc(9'h0AA, d, 1'b1, 1'b0, 48'h0);
endtask

localparam [8:0] FMODE = 9'h1FC, COLOR00 = 9'h180, BPL1DAT = 9'h110, BPL2DAT = 9'h112,
                 SPR0DATA = 9'h144, COP_IDLE = 9'h1FE;

integer fm;

initial begin
	repeat (6) @(negedge clk);
	reset_n = 1;
	repeat (16) @(negedge clk);
	reset = 0;
	repeat (8) @(negedge clk);

	// CPU writes in each mode after a DMA word, with a CPU write between
	// (it leaves the previous word as it is) and a stale SDRAM burst
	for (fm = 0; fm < 4; fm = fm + 1) begin
		cpu(FMODE, 16'(fm * 5));              // bitplane and sprite width alike
		dma(16'hD1D1);
		cpu(COLOR00, 16'h1234);
		cpu(BPL2DAT, 16'h5678);
		case (fm)
			0: check(dut.bplm0.bpl2dat, 64'h5678_0000_5678_0000, "BPL2DAT CPU write, FMODE 0");
			1: check(dut.bplm0.bpl2dat, 64'h5678_5678_5678_5678, "BPL2DAT CPU write, FMODE 1");
			2: check(dut.bplm0.bpl2dat, 64'hD1D1_5678_5678_5678, "BPL2DAT CPU write, FMODE 2");
			3: check(dut.bplm0.bpl2dat, 64'hD1D1_5678_5678_5678, "BPL2DAT CPU write, FMODE 3");
		endcase
		dma(16'hD2D2);
		cpu(SPR0DATA, 16'h9ABC);
		case (fm)
			0: check(dut.sprm0.sps0.datla, 64'h9ABC_0000_0000_0000, "SPR0DATA CPU write, FMODE 0");
			1: check(dut.sprm0.sps0.datla, 64'h9ABC_9ABC_0000_0000, "SPR0DATA CPU write, FMODE 1");
			2: check(dut.sprm0.sps0.datla, 64'hD2D2_9ABC_0000_0000, "SPR0DATA CPU write, FMODE 2");
			3: check(dut.sprm0.sps0.datla, 64'hD2D2_9ABC_9ABC_9ABC, "SPR0DATA CPU write, FMODE 3");
		endcase
	end

	// after a 64-wide bitplane DMA fetch: its last word
	cpu(FMODE, 16'h0003);
	cyc(BPL1DAT, 16'h1111, 1'b1, 1'b1, 48'h2222_3333_4444);
	check(dut.bplm0.bpl1dat, 64'h1111_2222_3333_4444, "BPL1DAT DMA, FMODE 3");
	cpu(BPL2DAT, 16'h5678);
	check(dut.bplm0.bpl2dat, 64'h4444_5678_5678_5678, "BPL2DAT CPU write after a 64-wide bitplane fetch");

	// after a 32-wide bitplane DMA fetch: its second word
	cpu(FMODE, 16'h0002);
	cyc(BPL1DAT, 16'h1212, 1'b1, 1'b1, 48'h3434_5656_7878);
	cpu(BPL2DAT, 16'h5678);
	check(dut.bplm0.bpl2dat, 64'h3434_5678_5678_5678, "BPL2DAT CPU write after a 32-wide bitplane fetch");

	// after a 64-wide sprite DMA fetch (FMODE bits 3-2): its last word
	cpu(FMODE, 16'h000C);
	cyc(SPR0DATA, 16'h5151, 1'b1, 1'b1, 48'h6262_7373_8484);
	check(dut.sprm0.sps0.datla, 64'h5151_6262_7373_8484, "SPR0DATA DMA, FMODE 3");
	cpu(SPR0DATA, 16'h9ABC);
	check(dut.sprm0.sps0.datla, 64'h8484_9ABC_9ABC_9ABC, "SPR0DATA CPU write after a 64-wide sprite fetch");

	// a copper MOVE: its first word on the bus, then the data word written in
	// its own DMA cycle; the write's first 16 bits are the word before it
	cpu(FMODE, 16'h0003);
	cyc(COP_IDLE, 16'h0112, 1'b1, 1'b0, 48'h0);
	cyc(BPL2DAT, 16'hC0C0, 1'b1, 1'b0, 48'hAAAA_BBBB_CCCC);
	check(dut.bplm0.bpl2dat, 64'h0112_C0C0_C0C0_C0C0, "BPL2DAT copper MOVE, FMODE 3");
	// and its data word is the previous word for the next write
	cpu(BPL2DAT, 16'h5678);
	check(dut.bplm0.bpl2dat, 64'hC0C0_5678_5678_5678, "BPL2DAT CPU write after a copper MOVE");

	if (failures == 0) $display("PASS: %0d wide-mode BPLxDAT/SPRxDATx loads (CPU, copper, DMA)", checks);
	else               $display("FAIL: %0d of %0d", failures, checks);
	$finish;
end
endmodule
