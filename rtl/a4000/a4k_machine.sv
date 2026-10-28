//============================================================================
//  a4k_machine: the Amiga 4000
//
//  The A3640 CPU card (ap68040 + a4k_a3640), the motherboard (a4k_lbus:
//  Gary, Ramsey, Buster; a4k_budgie: the 16-bit buses; the RP5C01, the IDE
//  port), the AGA chipset (a4k_chipset), the Zorro boards (Zorro III RAM
//  and RTG in a4k_lbus, the A2065 and Toccata here), and the memory
//  controllers (a4k_sdram, a4k_ddr3).  Everything of the MiSTer itself --
//  hps_io, the PLL, video and audio output -- is outside, in Maximig.sv,
//  so the full-system simulation (tb/system) runs this module as it is.
//============================================================================

module a4k_machine
#(
	// the CPU card, chosen at build time (only it is built): 0 the A3640,
	// 1 the BFG9060, 2 both, the OSD's card_bfg choosing at a reset
	parameter int CPU_CARD = 2,
	// the machine: 0 the A4000, 1 the AA3000+ (docs/AA3000.md): the DMAC+
	// with the DSP3210's control latch, its chip RAM and ROM windows
	parameter bit A3000P   = 1'b0,
	// the AA3000+'s DSP3210 (a3kp_dsp3210); without it the U124 latch and
	// the status still answer, the DSP's lines idle (BIO6/BIO7 pulled up)
	parameter bit DSP3210  = 1'b1
)
(
	// clocks: one PLL, edge aligned
	input             clk_114,       // SDRAM, DDR3
	input             clk_57,        // the CPU card and the local bus
	input             clk_sys,       // the chipset
	input             reset,         // the MiSTer's reset (synchronised to clk_sys)

	// Amiga clocks (amiga_clk, clk_sys domain)
	output            clk7_en,
	output            clk7n_en,
	output            c1,
	output            c3,
	output            cck,

	// the HPS: Minimig's IO channel (userio, Paula's floppy), IDE management
	input             io_uio,
	input             io_fpga,
	input             io_strobe,
	output            io_wait,
	input      [15:0] io_din,
	output     [15:0] io_dout,
	input       [4:0] ide_mgmt_addr,
	input             ide_mgmt_rd,
	input             ide_mgmt_wr,
	input      [15:0] ide_mgmt_wdata,
	output     [15:0] ide_mgmt_rdata,
	output      [5:0] ide_req,
	output            ide_led,
	input      [64:0] rtc,

	// input
	input      [15:0] joy0,
	input      [15:0] joy1,
	input      [15:0] joy2,
	input      [15:0] joy3,
	input      [15:0] joya0,
	input      [15:0] joya1,
	input       [2:0] mouse_buttons,
	input             kbd_mouse_level,
	input       [1:0] kbd_mouse_type,
	input       [7:0] kbd_mouse_data,

	// serial
	input             uart_rx,
	output            uart_tx,
	input             uart_cts,
	output            uart_rts,
	output            uart_dtr,
	input             uart_dsr,

	// user port (MiSTer floppy) and LEDs
	input       [6:0] user_in,
	output      [6:0] user_out,
	output            user_port_mode,
	output      [2:0] mister_floppy_status,
	output            pwr_led,
	output            fdd_led,

	// video
	output            hs_n,
	output            vs_n,
	output            field1,
	output            lace,
	output      [7:0] red,
	output      [7:0] green,
	output      [7:0] blue,
	output            hblank,
	output            vblank,
	output      [1:0] ar,
	output      [2:0] scanline,
	output      [1:0] res,
	output            ntsc,

	// audio
	output     [14:0] ldata,
	output     [14:0] rdata,
	output      [8:0] ldata_okk,
	output      [8:0] rdata_okk,
	output      [1:0] aud_mix,
	output     [15:0] toccata_l,
	output     [15:0] toccata_r,
	input       [1:0] dsnd_volume,
	input             cart_ar,       // the cartridge: 0 HRTmon, 1 the Action Replay (AR5, DeMoN v2)
	input             card_bfg,      // the CPU card: 0 the A3640, 1 the BFG9060 (68040); taken at a reset
	output     [15:0] dsnd_l,
	output     [15:0] dsnd_r,

	// SDRAM
	output     [12:0] SDRAM_A,
	output      [1:0] SDRAM_BA,
	inout      [15:0] SDRAM_DQ,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output            SDRAM_nCS,
	output            SDRAM_nCAS,
	output            SDRAM_nRAS,
	output            SDRAM_nWE,
	output            SDRAM_CKE,
	output            SDRAM_CLK,

	// DDR3
	output            DDRAM_CLK,
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output            DDRAM_RD,
	output     [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE,
	output            DDRAM_WE,

	// the RTG framebuffer
	output            FB_EN,
	output      [4:0] FB_FORMAT,
	output     [11:0] FB_WIDTH,
	output     [11:0] FB_HEIGHT,
	output     [31:0] FB_BASE,
	output     [13:0] FB_STRIDE,
	output            FB_PAL_CLK,
	output      [7:0] FB_PAL_ADDR,
	output     [23:0] FB_PAL_DOUT,
	input      [23:0] FB_PAL_DIN,
	output            FB_PAL_WR,

	// observation (simulation)
	output     [31:0] dbg_pc,
	output            dbg_retire,
	output            dbg_halted,
	output            dbg_cpu_ce,
	output            dbg_lb_beat,     // a local-bus beat terminates (clk_57)
	output     [31:0] dbg_lb_addr,
	output            dbg_lb_we,
	output     [31:0] dbg_lb_data
);

//////////////////////////////  Amiga clocks  ///////////////////////////////

wire [9:0] eclk;

amiga_clk amiga_clk
(
	.clk_28   ( clk_sys    ),
	.clk7_en  ( clk7_en    ),
	.clk7n_en ( clk7n_en   ),
	.c1       ( c1         ),
	.c3       ( c3         ),
	.cck      ( cck        ),
	.eclk     ( eclk       ),
	.reset_n  ( ~reset     )
);

//////////////////////////////  configuration  ////////////////////////////

wire  [4:0] cpucfg;
wire  [2:0] cachecfg;
wire  [6:0] memcfg;
wire  [5:0] chipsetcfg;
wire  [5:0] idecfg;

// the CPU card, taken at a system reset: the A3640 or the BFG9060
reg        bfg = 1'b0;

// CPU clock: TT 0 25 MHz (A3640), 1 33 MHz (the BFG9060: 37.5 MHz, its
// 68040 firmware's other clock), 2 50 MHz, 3 56.75 MHz; SS 01: 40 MHz
reg [2:0] cpu_speed;
always @(posedge clk_57) begin
	if (cpucfg[4:3] == 2'b01) cpu_speed <= 3'd2;
	else case (cpucfg[1:0])
		2'd0: cpu_speed <= 3'd0;
		2'd1: cpu_speed <= bfg ? 3'd5 : 3'd1;
		2'd2: cpu_speed <= 3'd3;
		2'd3: cpu_speed <= 3'd4;
	endcase
end

wire       bus_fast = cpucfg[2];                       // P: Fast bus timing
wire [1:0] mbram    = memcfg[3:2];                     // SS: motherboard RAM
wire [2:0] z3cfg    = {memcfg[6], memcfg[5:4]};        // FF + bit 7: Zorro III RAM
wire       z3ram256_fit = (z3cfg >= 3'd4);
wire       z3ram128_fit = (z3cfg != 3'd0) && (z3cfg != 3'd4) && !bfg;   // (the BFG9060's RAM takes its DDR3)

//////////////////////////////  the CPU card  ////////////////////////////

wire       cpu_ce;
wire       clk_cpu;

a4k_cpuclk cpuclk
(
	.clk_57(clk_57),
	.speed(cpu_speed),
	.cpu_ce(cpu_ce),
	.clk_cpu(clk_cpu)
);

assign dbg_cpu_ce = cpu_ce;

wire        sys_rst_n;          // the system reset (the chipset's _cpu_reset)
wire        cpu_rsto_n;         // the RESET instruction
wire        iack7_t;            // the card: toggles at a level-7 interrupt acknowledge
wire        freeze_t;           // the chipset: toggles at the freeze key
wire        cart_nmi_t;         // the local bus: toggles to raise the cartridge's NMI
wire        cart_ar_on;         // the chipset: the Action Replay is the enabled cartridge
wire  [2:0] cpu_ipl_n;
wire        gary_ien;           // Gary's interrupt master (a4k_lbus)

// the 68040's bus
wire [31:0] c_a, c_do, c_di;
wire        c_rw_n, c_ts_n, c_ta_n, c_tea_n, c_tci_n, c_tbi_n, c_avec_n;
wire  [1:0] c_siz, c_tt;
wire  [2:0] c_tm;

// the CPU's reset input, on its own clock's edges
reg cpu_rsti_n = 1'b0;
always @(posedge clk_57) if (cpu_ce) cpu_rsti_n <= sys_rst_n;

// the card choice (an OSD status bit) only while the machine is in reset;
// a build with one card has it fixed
reg [1:0] card_bfg_s = 2'b00;
always @(posedge clk_57) begin
	card_bfg_s <= {card_bfg_s[0], card_bfg};
	if (CPU_CARD == 0)      bfg <= 1'b0;
	else if (CPU_CARD == 1) bfg <= 1'b1;
	else if (!cpu_rsti_n)   bfg <= card_bfg_s[1];
end

// the RESET instruction for the clk_sys boards (IDE, A2065, Toccata), taken
// on clk_sys (the chipset takes its own)
reg cpu_rsto_sys_n = 1'b1;
always @(posedge clk_sys) cpu_rsto_sys_n <= cpu_rsto_n;

// the CPU's debug outputs: the PC sampler's recorder and the benches
// read them; a release build leaves them out (their loads cost the fit)
`ifdef MAXIMIG_PCSAMPLE
localparam CPU_DEBUG = 1'b1;
`elsif VERILATOR
localparam CPU_DEBUG = 1'b1;
`else
localparam CPU_DEBUG = 1'b0;
`endif

ap68040 #(.DEBUG(CPU_DEBUG)) cpu
(
	.clk(clk_cpu),
	.bclk_en(1'b1),
	.rsti_n(cpu_rsti_n),

	.a_o(c_a), .a_oe(),
	.a_i(32'd0), .ts_n_i(1'b1), .rw_n_i(1'b1), .siz_i(2'd0), .tt_i(2'd0), .sc(2'd0),
	.mi_n(), .ta_n_o(), .ta_oe(),
	.d_i(c_di), .d_o(c_do), .d_oe(),
	.rw_n(c_rw_n), .siz(c_siz), .tt(c_tt), .tm(c_tm), .tln(), .upa(),
	.ciout_n(), .lock_n(), .locke_n(), .ts_n(c_ts_n), .tip_n(),
	.ta_n(c_ta_n), .tea_n(c_tea_n), .tci_n(c_tci_n), .tbi_n(c_tbi_n),
	.ipl_n(gary_ien ? cpu_ipl_n : 3'b111), .avec_n(c_avec_n),   // Gary's interrupt master
	.br_n(), .bg_n(1'b0), .bb_n_i(1'b1), .bb_n_o(), .bb_oe(),
	.rsto_n(cpu_rsto_n), .cdis_n(1'b1), .mdis_n(1'b1), .ipend_n(), .pst(),

	.dbg_pc(dbg_pc), .dbg_retire(dbg_retire), .dbg_rinfo(dbg_rinfo), .dbg_xgo(dbg_xgo), .dbg_xvec(dbg_xvec), .dbg_xpc(dbg_xpc),
	.dbg_hfgo(dbg_hfgo), .dbg_hfld(dbg_hfld), .dbg_hfa(dbg_hfa), .dbg_hff(dbg_hff), .dbg_hfpc(dbg_hfpc),
	.dbg_ev(dbg_ev), .dbg_evpc(dbg_evpc),
	.dbg_halted(dbg_halted)
);

wire        lb_req, lb_ack, lb_we, lb_line, lb_berr, lb_ci, lb_local;
// a4k_lbus's beat port: the card's beats, or (AA3000+) the bus masters' through a3kp_lbarb
wire        bus_req, bus_ack, bus_we, bus_line, bus_local, bus_dsp;
wire [31:2] bus_addr;
wire  [3:0] bus_be;
wire [31:0] bus_wdata;
wire  [1:0] bus_beat, bus_tt;
wire  [2:0] bus_tm;
wire[127:0] lb_rline;
wire [31:2] lb_addr;
wire  [3:0] lb_be;
wire [31:0] lb_wdata, lb_rdata;
wire  [1:0] lb_beat, lb_tt;
wire  [2:0] lb_tm;

// the card's cost per beat in A4000 timing (calibrated against a real
// A3640, docs/ARCHITECTURE.md)
wire  [2:0] card_pre  = 3'd0;
wire  [2:0] card_post = 3'd0;

// the two cards answer the same CPU bus; the one not chosen is held in reset
// (its local bus request then follows the acknowledge)
wire [31:0] a_di, b_di;
wire        a_ta_n, a_tea_n, a_tci_n, a_tbi_n, a_avec_n, a_iack7_t;
wire        b_ta_n, b_tea_n, b_tci_n, b_tbi_n, b_avec_n, b_iack7_t;
wire        a_lb_req, a_lb_we, a_lb_line, b_lb_req, b_lb_we, b_lb_line;
wire [31:2] a_lb_addr, b_lb_addr;
wire  [3:0] a_lb_be, b_lb_be;
wire [31:0] a_lb_wdata, b_lb_wdata;
wire  [1:0] a_lb_beat, b_lb_beat, a_lb_tt, b_lb_tt;
wire  [2:0] a_lb_tm, b_lb_tm;

generate if (CPU_CARD != 1) begin : g_a3640
a4k_a3640 a3640
(
	.clk(clk_57),
	.ce(cpu_ce),
	.reset(~cpu_rsti_n | bfg),

	.a(c_a),
	.ts_n(c_ts_n),
	.rw_n(c_rw_n),
	.siz(c_siz),
	.tt(c_tt),
	.tm(c_tm),
	.d_cpu(c_do),

	.d_mem(a_di),
	.ta_n(a_ta_n),
	.tea_n(a_tea_n),
	.tci_n(a_tci_n),
	.tbi_n(a_tbi_n),
	.avec_n(a_avec_n),
	.iack7_t(a_iack7_t),

	.pre(card_pre),
	.post(card_post),

	.lb_req(a_lb_req),
	.lb_ack(lb_ack),
	.lb_addr(a_lb_addr),
	.lb_be(a_lb_be),
	.lb_we(a_lb_we),
	.lb_wdata(a_lb_wdata),
	.lb_line(a_lb_line),
	.lb_beat(a_lb_beat),
	.lb_tt(a_lb_tt),
	.lb_tm(a_lb_tm),
	.lb_rdata(lb_rdata),
	.lb_berr(lb_berr),
	.lb_ci(lb_ci),

	.dbg_state()
);
end else begin : g_no_a3640
	assign a_di = 32'd0;
	assign {a_ta_n, a_tea_n, a_tci_n, a_tbi_n, a_avec_n} = 5'b11111;
	assign a_iack7_t = 1'b0;
	assign {a_lb_req, a_lb_we, a_lb_line} = 3'b000;
	assign a_lb_addr = 30'd0;
	assign a_lb_be = 4'd0;
	assign a_lb_wdata = 32'd0;
	assign {a_lb_beat, a_lb_tt, a_lb_tm} = 7'd0;
end endgenerate

generate if (CPU_CARD != 0) begin : g_bfg9060
a4k_bfg9060 bfg9060
(
	.clk(clk_57),
	.ce(cpu_ce),
	.reset(~cpu_rsti_n | !bfg),

	.a(c_a),
	.ts_n(c_ts_n),
	.rw_n(c_rw_n),
	.siz(c_siz),
	.tt(c_tt),
	.tm(c_tm),
	.d_cpu(c_do),

	.d_mem(b_di),
	.ta_n(b_ta_n),
	.tea_n(b_tea_n),
	.tci_n(b_tci_n),
	.tbi_n(b_tbi_n),
	.avec_n(b_avec_n),
	.iack7_t(b_iack7_t),

	.pre(card_pre),
	.post(card_post),

	.lb_req(b_lb_req),
	.lb_ack(lb_ack),
	.lb_addr(b_lb_addr),
	.lb_be(b_lb_be),
	.lb_we(b_lb_we),
	.lb_wdata(b_lb_wdata),
	.lb_line(b_lb_line),
	.lb_beat(b_lb_beat),
	.lb_tt(b_lb_tt),
	.lb_tm(b_lb_tm),
	.lb_local(lb_local),
	.lb_rdata(lb_rdata),
	.lb_berr(lb_berr),
	.lb_rline(lb_rline),

	.dbg_state()
);
end else begin : g_no_bfg9060
	assign b_di = 32'd0;
	assign {b_ta_n, b_tea_n, b_tci_n, b_tbi_n, b_avec_n} = 5'b11111;
	assign b_iack7_t = 1'b0;
	assign {b_lb_req, b_lb_we, b_lb_line} = 3'b000;
	assign b_lb_addr = 30'd0;
	assign b_lb_be = 4'd0;
	assign b_lb_wdata = 32'd0;
	assign {b_lb_beat, b_lb_tt, b_lb_tm} = 7'd0;
	assign lb_local = 1'b0;
end endgenerate

assign c_di     = bfg ? b_di     : a_di;
assign c_ta_n   = bfg ? b_ta_n   : a_ta_n;
assign c_tea_n  = bfg ? b_tea_n  : a_tea_n;
assign c_tci_n  = bfg ? b_tci_n  : a_tci_n;
assign c_tbi_n  = bfg ? b_tbi_n  : a_tbi_n;
assign c_avec_n = bfg ? b_avec_n : a_avec_n;
assign iack7_t  = a_iack7_t ^ b_iack7_t;
assign lb_req   = bfg ? b_lb_req   : a_lb_req;
assign lb_addr  = bfg ? b_lb_addr  : a_lb_addr;
assign lb_be    = bfg ? b_lb_be    : a_lb_be;
assign lb_we    = bfg ? b_lb_we    : a_lb_we;
assign lb_wdata = bfg ? b_lb_wdata : a_lb_wdata;
assign lb_line  = bfg ? b_lb_line  : a_lb_line;
assign lb_beat  = bfg ? b_lb_beat  : a_lb_beat;
assign lb_tt    = bfg ? b_lb_tt    : a_lb_tt;
assign lb_tm    = bfg ? b_lb_tm    : a_lb_tm;

// a beat terminating on the local bus, for the simulation's bus trace
reg bus_ack_d;
always @(posedge clk_57) bus_ack_d <= bus_ack;
assign dbg_lb_beat = bus_ack ^ bus_ack_d;
assign dbg_lb_addr = {bus_addr, 2'b00};
assign dbg_lb_we   = bus_we;
assign dbg_lb_data = bus_we ? bus_wdata : lb_rdata;

//////////////////////////////  the motherboard  //////////////////////////

// resets: the system's (OSD, keyboard, power-up) and, for the I/O, the
// RESET instruction as well; the first since configuration is a power-up
reg io_reset_57, sys_reset_57, sys_reset_57_d;
always @(posedge clk_57) begin
	sys_reset_57   <= ~sys_rst_n;
	io_reset_57    <= ~sys_rst_n | ~cpu_rsto_n;
	sys_reset_57_d <= sys_reset_57;
end

reg pwrup = 1'b1;
always @(posedge clk_57) if (sys_reset_57_d & ~sys_reset_57) pwrup <= 1'b0;

wire        sd_req, sd_ack, sd_we;
wire [24:2] sd_addr;
wire  [3:0] sd_be;
wire [31:0] sd_wdata;
wire [63:0] sd_rdata;

wire        dd_req, dd_ack, dd_we;
wire [28:2] dd_addr;
wire  [3:0] dd_be;
wire [31:0] dd_wdata;
wire[127:0] dd_rdata;

wire        sb_req, sb_ack, sb_we;
wire  [2:0] sb_tgt;
wire [23:2] sb_addr;
wire  [3:0] sb_be;
wire [31:0] sb_wdata, sb_rdata;

wire        a2065_ena, toccata_ena;
wire  [7:0] a2065_base, toccata_base;

// the DMAC+ (AA3000+)
wire        dm_req, dm_ack, dm_we;
wire  [7:2] dm_addr;
wire  [3:0] dm_be;
wire [31:0] dm_wdata, dm_rdata;
wire        dmac_int2, dmac_int6;

wire        ovl;
wire        extrom_on;           // the chipset: an extension ROM is loaded

// The retired-PC ring, a debug aid with the PC sampler (MAXIMIG_PCSAMPLE):
// the PCs of the last 256 instructions retired, frozen at the first sign of
// a crash once armed: an instruction retired from the vector page
// ($000002-$0003FF: nothing runs there, a runaway does; exception entry
// retires at 0), an instruction from Kickstart's first page ($F80000-
// $F800FF: its entry, reached without a reset by a runaway), a RESET
// instruction (Kickstart's ColdReboot after an Alert), a CPU reset, or the
// CPU halting (a double fault).  It arms after 2^22 instructions (the
// boot's own resets come before); a4k_lbus copies it to DDR3 at
// 0x27FF6400.
// (MAXIMIG_RTR_ILLEGAL: an illegal instruction's exception freezes it too,
// for a program that dies with 8000 0004; cputest ends every test with
// ILLEGAL).  The last exception's vector and stacked PC go with it.
wire        dbg_xgo;
wire  [7:0] dbg_xvec;
wire [31:0] dbg_xpc;
reg   [7:0] rtr_xvec = 8'd0;
reg  [31:0] rtr_xpc = 32'd0;
// ... and the last exception routine's handler fetch (its load data, the
// A operand's register value, {A source, the DMU job's answer}, its PC)
wire        dbg_hfgo;
wire [31:0] dbg_hfld, dbg_hfa, dbg_hfpc;
wire  [7:0] dbg_hff;
reg  [31:0] rtr_hfld = 32'd0, rtr_hfa = 32'd0, rtr_hfpc = 32'd0;
reg   [7:0] rtr_hff = 8'd0;
`ifdef MAXIMIG_RTR_ILLEGAL
localparam RTR_ILL = 1'b1;
`else
localparam RTR_ILL = 1'b0;
`endif
wire [31:0] rtr_rd;
wire  [9:0] rtr_ra;
// the front end's last 32 events (redirects, the BTB's, exception entry,
// the handler fetch), with the ring's next slot at each
wire  [2:0] dbg_ev;
wire [31:0] dbg_evpc;
// the retired uop: dbg_retire is registered at the commit, so its PC is
// the previous clock's dbg_pc; dbg_rinfo comes with it
wire [15:0] dbg_rinfo;
reg  [31:0] dbg_pc_d = 32'd0;
reg   [7:0] rtr_wp = 8'd0;
reg         rtr_frz = 1'b0;
`ifndef MAXIMIG_RTR_ARM_BITS
`define MAXIMIG_RTR_ARM_BITS 22      // (the system bench: fewer)
`endif
reg  [`MAXIMIG_RTR_ARM_BITS:0] rtr_cnt = '0;
wire        rtr_arm = rtr_cnt[`MAXIMIG_RTR_ARM_BITS];
`ifdef MAXIMIG_PCSAMPLE
reg  [31:0] rtr_ram [256];
reg  [15:0] rtr_ram2 [256];      // the uop's info with each PC
reg  [31:0] rtr_q;
reg  [15:0] rtr_q2;
always @(posedge clk_cpu) begin
	dbg_pc_d <= dbg_pc;
	if (!rtr_frz) begin
		if (dbg_xgo) begin
			rtr_xvec <= dbg_xvec;
			rtr_xpc  <= dbg_xpc;
		end
		if (dbg_hfgo) begin
			rtr_hfld <= dbg_hfld;
			rtr_hfa  <= dbg_hfa;
			rtr_hff  <= dbg_hff;
			rtr_hfpc <= dbg_hfpc;
		end
		if (rtr_arm && (!cpu_rsti_n || !cpu_rsto_n || dbg_halted || (RTR_ILL && dbg_xgo && dbg_xvec == 8'd4))) rtr_frz <= 1'b1;
		else if (dbg_retire) begin
			rtr_ram[rtr_wp]  <= dbg_pc_d;
			rtr_ram2[rtr_wp] <= dbg_rinfo;
			rtr_wp <= rtr_wp + 1'd1;
			if (!rtr_arm) rtr_cnt <= rtr_cnt + 1'd1;
			// (an exception's entry retires at PC 0: not a runaway)
			else if (dbg_pc_d[31:10] == 22'd0 && dbg_pc_d[9:0] != 10'd0) rtr_frz <= 1'b1;
			// (Kickstart's entry, $F800D0-$F800D2, reached by a jump rather
			// than a reset: a runaway into a cold start)
			else if (dbg_pc_d[31:8] == 24'h00F800) rtr_frz <= 1'b1;
			// (nothing runs above the Zorro III RAM boards, $58000000 up: the
			// RTG board, autoconfig space -- a runaway through a stale return
			// address lands there before it reaches low memory)
			else if (dbg_pc_d[31:27] >= 5'd11) rtr_frz <= 1'b1;
		end
	end
end
reg  [31:0] ev_a [32];
reg  [31:0] ev_b [32];
reg   [4:0] ev_wp = 5'd0;
reg  [31:0] ev_qa, ev_qb;
reg         ev_sel = 1'b0, ev_w = 1'b0;
always @(posedge clk_cpu)
	if (!rtr_frz && dbg_ev != 3'd0) begin
		ev_a[ev_wp] <= {8'hE5, 5'd0, dbg_ev, 8'd0, rtr_wp};
		ev_b[ev_wp] <= dbg_evpc;
		ev_wp <= ev_wp + 1'd1;
	end
wire  [4:0] ev_ri = ev_wp + rtr_ra[5:1];             // oldest first
always @(posedge clk_57) begin
	rtr_q  <= rtr_ram[rtr_ra[7:0]];
	rtr_q2 <= rtr_ram2[rtr_ra[7:0]];
	ev_qa  <= ev_a[ev_ri];
	ev_qb  <= ev_b[ev_ri];
	ev_sel <= rtr_ra[8];
	ev_w   <= rtr_ra[0];
end
assign rtr_rd = ev_sel ? (ev_w ? ev_qb : ev_qa) : rtr_ra[9] ? {16'd0, rtr_q2} : rtr_q;
`else
assign rtr_rd = 32'd0;
`endif

a4k_lbus #(.A3000P(A3000P)) lbus
(
	.clk(clk_57),
	.ce(cpu_ce),
	.reset(sys_reset_57),
	.io_reset(io_reset_57),
	.pwrup(pwrup),

	.fast(bus_fast),
	.mbram(mbram),
	.z3ram256_fit(z3ram256_fit),
	.z3ram128_fit(z3ram128_fit),
	.rtg_fit(1'b1),
	.a2065_fit(1'b1),
	.toccata_fit(1'b1),
	.rom_speed(2'd1),
	.ovl(ovl),
	.extrom_on(extrom_on),
	.gary_ien(gary_ien),
	.iack7_t(iack7_t),
	.cart_ar(cart_ar_on),
	.freeze_t(freeze_t),
	.nmi_t(cart_nmi_t),
	.dbg_pc(dbg_pc),
	.rtr_frz(rtr_frz),
	.rtr_wp(rtr_wp),
	.rtr_xvec(rtr_xvec),
	.rtr_xpc(rtr_xpc),
	.rtr_hfld(rtr_hfld),
	.rtr_hfa(rtr_hfa),
	.rtr_hff(rtr_hff),
	.rtr_hfpc(rtr_hfpc),
	.rtr_ra(rtr_ra),
	.rtr_rd(rtr_rd),

	.lb_req(bus_req),
	.lb_ack(bus_ack),
	.lb_addr(bus_addr),
	.lb_be(bus_be),
	.lb_we(bus_we),
	.lb_wdata(bus_wdata),
	.lb_line(bus_line),
	.lb_beat(bus_beat),
	.lb_tt(bus_tt),
	.lb_tm(bus_tm),
	.lb_local(bus_local),
	.lb_dsp(bus_dsp),
	.lb_rdata(lb_rdata),
	.lb_rline(lb_rline),
	.lb_berr(lb_berr),
	.lb_ci(lb_ci),

	.sd_req(sd_req),
	.sd_ack(sd_ack),
	.sd_addr(sd_addr),
	.sd_we(sd_we),
	.sd_be(sd_be),
	.sd_wdata(sd_wdata),
	.sd_rdata(sd_rdata),

	.dd_req(dd_req),
	.dd_ack(dd_ack),
	.dd_addr(dd_addr),
	.dd_we(dd_we),
	.dd_be(dd_be),
	.dd_wdata(dd_wdata),
	.dd_rdata(dd_rdata),

	.sb_req(sb_req),
	.sb_ack(sb_ack),
	.sb_tgt(sb_tgt),
	.sb_addr(sb_addr),
	.sb_we(sb_we),
	.sb_be(sb_be),
	.sb_wdata(sb_wdata),
	.sb_rdata(sb_rdata),

	.dm_req(dm_req),
	.dm_ack(dm_ack),
	.dm_addr(dm_addr),
	.dm_be(dm_be),
	.dm_we(dm_we),
	.dm_wdata(dm_wdata),
	.dm_rdata(dm_rdata),

	.a2065_ena(a2065_ena),
	.a2065_base(a2065_base),
	.toccata_ena(toccata_ena),
	.toccata_base(toccata_base),

	.rtg_ena(FB_EN),
	.rtg_hsize(FB_WIDTH),
	.rtg_vsize(FB_HEIGHT),
	.rtg_format(FB_FORMAT),
	.rtg_base(FB_BASE),
	.rtg_stride(FB_STRIDE),
	.rtg_pal_clk(FB_PAL_CLK),
	.rtg_pal_dw(FB_PAL_DOUT),
	.rtg_pal_dr(FB_PAL_DIN),
	.rtg_pal_a(FB_PAL_ADDR),
	.rtg_pal_wr(FB_PAL_WR),

	.dbg_tgt(),
	.dbg_coldboot(),
	.dbg_ramsey()
);

// the AA3000+'s DMAC+ and the DSP3210's control latch (U124), the WD33C93A
// and the SCSI disks (ide0, Main's drives 0 and 1, as SCSI IDs 0 and 1), the
// bus masters' arbiter
wire [15:0] ide0_mgmt_rd, ide1_mgmt_rd;
wire [31:0] ide0_io_rdata, ide1_io_rdata;
wire        ide0_irq, ide1_irq, ide0_nodata, ide1_nodata, ide0_drq, ide1_drq;
wire  [1:0] ide0_present, ide1_present;
wire  [3:0] scsi_io_addr;
wire        scsi_io_rd, scsi_io_wr;
wire [15:0] scsi_io_wdata;
generate if (A3000P) begin : g_dmac
	wire       sbic_req, sbic_ack, sbic_a0, sbic_we, sbic_intrq, sbic_drq, sbic_mr;
	wire [7:0] sbic_wdata, sbic_rdata;
	wire       sd_rq, sd_ak;
	wire [7:0] sd_wd, sd_rd;
	wire       m_req, m_ack, m_we;
	wire[31:2] m_addr;
	wire [3:0] m_be;
	wire[31:0] m_wdata;
	wire       prest;
	wire       dsp_rst, dsp_i0, dsp_i1, dsp_ack0, dsp_ack1, dsp_ci2, dsp_ci6;
	wire       d_req, d_ack, d_we, d_hold;
	wire[31:2] d_addr;
	wire [3:0] d_be;
	wire[31:0] d_wdata;

	a3kp_dmac dmac
	(
		.clk(clk_57),
		.reset(io_reset_57),
		.req(dm_req),
		.ack(dm_ack),
		.addr(dm_addr),
		.be(dm_be),
		.we(dm_we),
		.wdata(dm_wdata),
		.rdata(dm_rdata),
		.sbic_req(sbic_req),
		.sbic_ack(sbic_ack),
		.sbic_a0(sbic_a0),
		.sbic_we(sbic_we),
		.sbic_wdata(sbic_wdata),
		.sbic_rdata(sbic_rdata),
		.sbic_intrq(sbic_intrq),
		.sbic_reset(prest),
		.sbic_drq(sbic_drq),
		.sd_req(sd_rq),
		.sd_ack(sd_ak),
		.sd_wdata(sd_wd),
		.sd_rdata(sd_rd),
		.m_req(m_req),
		.m_ack(m_ack),
		.m_addr(m_addr),
		.m_be(m_be),
		.m_we(m_we),
		.m_wdata(m_wdata),
		.m_rdata(lb_rdata),
		.dsp_reset(dsp_rst),
		.dsp_int0(dsp_i0),
		.dsp_int1(dsp_i1),
		.dsp_iack0(dsp_ack0),
		.dsp_iack1(dsp_ack1),
		.dsp_ci2(dsp_ci2),
		.dsp_ci6(dsp_ci6),
		.int2(dmac_int2),
		.int6(dmac_int6)
	);

	// the DSP3210 (docs/AA3000.md): CKI 50 MHz (U701's), here 7 of every 8
	// clk_57 cycles; held in reset by U124's dspRST; its INT0/INT1 from
	// U124, its BIO6/BIO7 (pulled up as inputs) the CPU's INT6/INT2 through
	// U124's masks (U701); BIO4/BIO5 low (pcw at reset: Computer mode, the
	// boot ROM at 0)
	wire [7:0] bio_o, bio_e;
	wire [7:0] bio_pin = (bio_e & bio_o) | (~bio_e & 8'b1100_0000);
	assign dsp_ci2 = !bio_pin[7];
	assign dsp_ci6 = !bio_pin[6];

	if (DSP3210) begin : g_dsp
	reg  [2:0] cki_n = 3'd0;
	always @(posedge clk_57) cki_n <= cki_n + 1'd1;

	a3kp_dsp3210 dsp
	(
		.clk(clk_57),
		.ce(cki_n != 3'd7),
		.reset(dsp_rst | sys_reset_57),
		.m_req(d_req),
		.m_ack(d_ack),
		.m_addr(d_addr),
		.m_be(d_be),
		.m_we(d_we),
		.m_wdata(d_wdata),
		.m_rdata(lb_rdata),
		.m_berr(lb_berr),
		.m_hold(d_hold),
		.ir0_n(!dsp_i0),
		.ir1_n(!dsp_i1),
		.iack0(dsp_ack0),
		.iack1(dsp_ack1),
		.bio_in(bio_pin),
		.bio_out(bio_o),
		.bio_oe(bio_e),
		.dbg_pc(),
		.dbg_retire(),
		.dbg_halted()
	);
	end
	else begin : g_no_dsp
	assign {d_req, d_we, d_hold, d_addr, d_be, d_wdata} = '0;
	assign {dsp_ack0, dsp_ack1} = 2'b00;
	assign {bio_o, bio_e} = 16'd0;
	end

	// the SBIC's MR-: the system reset or the DMAC's PREST (on clk_sys)
	reg [1:0] prest_s = 2'b00;
	always @(posedge clk_sys) prest_s <= {prest_s[0], prest};
	assign sbic_mr = ~sys_rst_n | prest_s[1];

	wire       t_sel, t_atn, t_bsy, t_req, t_ack, t_abort;
	wire [2:0] t_id, t_phase;
	wire [7:0] t_tdata, t_idata;

	a3kp_sbic sbic
	(
		.clk(clk_sys),
		.mr(sbic_mr),
		.h_req(sbic_req),
		.h_ack(sbic_ack),
		.h_a0(sbic_a0),
		.h_we(sbic_we),
		.h_wdata(sbic_wdata),
		.h_rdata(sbic_rdata),
		.intrq(sbic_intrq),
		.drq(sbic_drq),
		.d_req(sd_rq),
		.d_ack(sd_ak),
		.d_wdata(sd_wd),
		.d_rdata(sd_rd),
		.d_more(),
		.sel(t_sel),
		.sel_id(t_id),
		.atn(t_atn),
		.bsy(t_bsy),
		.phase(t_phase),
		.req(t_req),
		.tdata(t_tdata),
		.ack(t_ack),
		.idata(t_idata),
		.abort_t(t_abort)
	);

	// the initiator leaving the bus (Disconnect, Reset) frees the targets
	reg t_abort_d = 1'b0;
	always @(posedge clk_sys) t_abort_d <= t_abort;

	a3kp_scsi_disk disks
	(
		.clk(clk_sys),
		.reset(~sys_rst_n | (t_abort != t_abort_d)),
		.sel(t_sel),
		.sel_id(t_id),
		.atn(t_atn),
		.bsy(t_bsy),
		.phase(t_phase),
		.req(t_req),
		.tdata(t_tdata),
		.ack(t_ack),
		.idata(t_idata),
		.io_address(scsi_io_addr),
		.io_read(scsi_io_rd),
		.io_write(scsi_io_wr),
		.io_writedata(scsi_io_wdata),
		.io_readdata(ide0_io_rdata[15:0]),
		.io_nodata(ide0_nodata),
		.present(ide0_present)
	);

	a3kp_lbarb arb
	(
		.clk(clk_57),
		.reset(sys_reset_57),
		.bfg(bfg),
		.c_req(lb_req),
		.c_ack(lb_ack),
		.c_addr(lb_addr),
		.c_be(lb_be),
		.c_we(lb_we),
		.c_wdata(lb_wdata),
		.c_line(lb_line),
		.c_beat(lb_beat),
		.c_tt(lb_tt),
		.c_tm(lb_tm),
		.c_local(lb_local),
		.d0_req(d_req),
		.d0_ack(d_ack),
		.d0_addr(d_addr),
		.d0_be(d_be),
		.d0_we(d_we),
		.d0_wdata(d_wdata),
		.d0_hold(d_hold),
		.d1_req(m_req),
		.d1_ack(m_ack),
		.d1_addr(m_addr),
		.d1_be(m_be),
		.d1_we(m_we),
		.d1_wdata(m_wdata),
		.lb_req(bus_req),
		.lb_ack(bus_ack),
		.lb_addr(bus_addr),
		.lb_be(bus_be),
		.lb_we(bus_we),
		.lb_wdata(bus_wdata),
		.lb_line(bus_line),
		.lb_beat(bus_beat),
		.lb_tt(bus_tt),
		.lb_tm(bus_tm),
		.lb_local(bus_local),
		.lb_dsp(bus_dsp),
		.dma_owns()
	);
end else begin : g_no_dmac
	assign dm_ack = dm_req;
	assign dm_rdata = 32'd0;
	assign dmac_int2 = 1'b0;
	assign dmac_int6 = 1'b0;
	assign {scsi_io_addr, scsi_io_rd, scsi_io_wr, scsi_io_wdata} = 22'd0;
	assign bus_req   = lb_req;
	assign lb_ack    = bus_ack;
	assign bus_addr  = lb_addr;
	assign bus_be    = lb_be;
	assign bus_we    = lb_we;
	assign bus_wdata = lb_wdata;
	assign bus_line  = lb_line;
	assign bus_beat  = lb_beat;
	assign bus_tt    = lb_tt;
	assign bus_tm    = lb_tm;
	assign bus_local = lb_local;
	assign bus_dsp   = 1'b0;
end endgenerate

// the chip bus side of the board
wire [23:1] chip_addr;
wire [15:0] chip_dout, chip_dout2, chip_din, chip_din2;
wire        chip_as, chip_uds, chip_lds, chip_rw, chip_long, chip_dtack, chip32_en;

wire        rtc_cs, rtc_we;
wire  [3:0] rtc_reg, rtc_wdata, rtc_rdata;

wire  [3:0] ide_io_addr;
wire        ide_io_rd, ide_io_wr, ide_nodata, ide_irq;
wire  [1:0] ide_present;
wire [15:0] ide_io_wdata;
wire [31:0] ide_io_rdata;

wire [23:1] z2_addr;
wire [15:0] z2_dout, a2065_dout, tocc_dout;
wire        z2_rw, z2_as_n, z2_uds_n, z2_lds_n;
wire        a2065_sel, a2065_nrdy;
wire        tocc_sel, tocc_rd, tocc_hwr, tocc_lwr;

a4k_budgie budgie
(
	.clk(clk_sys),
	.reset(reset),
	.sys_reset(~sys_rst_n),
	.fast(bus_fast),
	.clk7_en(clk7_en),
	.cck(cck),

	.sb_req(sb_req),
	.sb_ack(sb_ack),
	.sb_tgt(sb_tgt),
	.sb_addr(sb_addr),
	.sb_we(sb_we),
	.sb_be(sb_be),
	.sb_wdata(sb_wdata),
	.sb_rdata(sb_rdata),

	.cpu_addr(chip_addr),
	.cpu_dout(chip_dout),
	.cpu_dout2(chip_dout2),
	.cpu_as_n(chip_as),
	.cpu_uds_n(chip_uds),
	.cpu_lds_n(chip_lds),
	.cpu_rw(chip_rw),
	.cpu_long(chip_long),
	.cpu_dtack_n(chip_dtack),
	.cpu_din(chip_din),
	.cpu_din2(chip_din2),
	.chip32_en(chip32_en),

	.rtc_cs(rtc_cs),
	.rtc_we(rtc_we),
	.rtc_reg(rtc_reg),
	.rtc_wdata(rtc_wdata),
	.rtc_rdata(rtc_rdata),

	.ide_addr(ide_io_addr),
	.ide_rd(ide_io_rd),
	.ide_wr(ide_io_wr),
	.ide_wdata(ide_io_wdata),
	.ide_rdata(ide_io_rdata[15:0]),
	.ide_nodata(ide_nodata),
	.ide_irq(ide_irq),
	.ide_reset(~(sys_rst_n & cpu_rsto_sys_n)),
	.ide_present(ide_present),

	.z2_addr(z2_addr),
	.z2_dout(z2_dout),
	.z2_rw(z2_rw),
	.z2_as_n(z2_as_n),
	.z2_uds_n(z2_uds_n),
	.z2_lds_n(z2_lds_n),
	.a2065_sel(a2065_sel),
	.a2065_din(a2065_dout),
	.a2065_nrdy(a2065_nrdy),
	.tocc_sel(tocc_sel),
	.tocc_rd(tocc_rd),
	.tocc_hwr(tocc_hwr),
	.tocc_lwr(tocc_lwr),
	.tocc_din(tocc_dout)
);

a4k_rtc rtc_chip
(
	.clk(clk_sys),
	.reset(reset),
	.ntsc(ntsc),
	.hps_rtc(rtc),
	.cs(rtc_cs),
	.we(rtc_we),
	.reg_sel(rtc_reg),
	.wdata(rtc_wdata),
	.rdata(rtc_rdata)
);

// the A4000 IDE port: one channel, master and slave, served by the HPS
// (ide0, Main's drives 0 and 1).  On the AA3000+ ide0 is the SCSI disks'
// and the A4000 IDE port, an extra there, is ide1 (Main's drives 2 and 3).

ide ide0
(
	.clk(clk_sys),
	.rst_n(sys_rst_n & (A3000P | cpu_rsto_sys_n)),
	.irq(ide0_irq),
	.drq(ide0_drq),
	.use_fast(1'b1),
	.no_data(ide0_nodata),
	.drive_en(ide0_present),

	.io_address(A3000P ? scsi_io_addr : ide_io_addr),
	.io_read(A3000P ? scsi_io_rd : ide_io_rd),
	.io_readdata(ide0_io_rdata),
	.io_write(A3000P ? scsi_io_wr : ide_io_wr),
	.io_writedata({16'd0, A3000P ? scsi_io_wdata : ide_io_wdata}),
	.io_32(1'b0),
	.io_wait(),

	.request(ide_req[2:0]),

	.mgmt_address(ide_mgmt_addr[3:0]),
	.mgmt_write(ide_mgmt_wr & ~ide_mgmt_addr[4]),
	.mgmt_writedata(ide_mgmt_wdata),
	.mgmt_read(ide_mgmt_rd & ~ide_mgmt_addr[4]),
	.mgmt_readdata(ide0_mgmt_rd)
);

generate if (A3000P) begin : g_ide1
	ide ide1
	(
		.clk(clk_sys),
		.rst_n(sys_rst_n & cpu_rsto_sys_n),
		.irq(ide1_irq),
		.drq(ide1_drq),
		.use_fast(1'b1),
		.no_data(ide1_nodata),
		.drive_en(ide1_present),

		.io_address(ide_io_addr),
		.io_read(ide_io_rd),
		.io_readdata(ide1_io_rdata),
		.io_write(ide_io_wr),
		.io_writedata({16'd0, ide_io_wdata}),
		.io_32(1'b0),
		.io_wait(),

		.request(ide_req[5:3]),

		.mgmt_address(ide_mgmt_addr[3:0]),
		.mgmt_write(ide_mgmt_wr & ide_mgmt_addr[4]),
		.mgmt_writedata(ide_mgmt_wdata),
		.mgmt_read(ide_mgmt_rd & ide_mgmt_addr[4]),
		.mgmt_readdata(ide1_mgmt_rd)
	);
end else begin : g_no_ide1
	assign ide1_mgmt_rd  = 16'h0000;
	assign ide1_io_rdata = 32'hFFFFFFFF;
	assign {ide1_irq, ide1_nodata, ide1_drq} = 3'b000;
	assign ide1_present  = 2'b00;
	assign ide_req[5:3]  = 3'b000;
end endgenerate

// the port Budgie drives: ide0, or ide1 on the AA3000+
assign ide_io_rdata   = A3000P ? ide1_io_rdata : ide0_io_rdata;
assign ide_irq        = A3000P ? ide1_irq      : ide0_irq;
assign ide_nodata     = A3000P ? ide1_nodata   : ide0_nodata;
assign ide_present    = A3000P ? ide1_present  : ide0_present;
assign ide_led        = ide0_drq | ide1_drq;
assign ide_mgmt_rdata = ide_mgmt_addr[4] ? ide1_mgmt_rd : ide0_mgmt_rd;

////////////////////////////  A2065 ETHERNET  ///////////////////////////////

wire        a2065_int2;
wire [28:0] a2065_mem_address;
wire  [7:0] a2065_mem_burstcount, a2065_mem_byteenable;
wire        a2065_mem_read, a2065_mem_write;
wire [63:0] a2065_mem_writedata, a2065_mem_readdata;
wire        a2065_mem_readdatavalid, a2065_mem_waitrequest;

a2065 a2065_inst
(
	.clk_sys          (clk_sys),
	.rst_n_sys        (sys_rst_n & cpu_rsto_sys_n),

	.cpu_addr         (z2_addr),
	.cpu_data_in      (z2_dout),
	.cpu_data_out     (a2065_dout),
	.cpu_rw           (z2_rw),
	.cpu_as_n         (z2_as_n),
	.cpu_uds_n        (z2_uds_n),
	.cpu_lds_n        (z2_lds_n),
	.sel              (a2065_sel),
	.nrdy             (a2065_nrdy),
	.int2             (a2065_int2),

	.card_base        (a2065_base),
	.card_configured  (a2065_ena),

	.clk_ddr          (clk_114),
	.mem_address      (a2065_mem_address),
	.mem_burstcount   (a2065_mem_burstcount),
	.mem_read         (a2065_mem_read),
	.mem_readdata     (a2065_mem_readdata),
	.mem_readdatavalid(a2065_mem_readdatavalid),
	.mem_writedata    (a2065_mem_writedata),
	.mem_byteenable   (a2065_mem_byteenable),
	.mem_write        (a2065_mem_write),
	.mem_waitrequest  (a2065_mem_waitrequest)
);

////////////////////////////  TOCCATA  ///////////////////////////////////////

wire toccata_int6;

toccata #(
	.CLK_FREQUENCY(28_359_380)
) toccata_board (
	.clk(clk_sys),
	.rst(~sys_rst_n | ~cpu_rsto_sys_n),
	.hsync(hs_n),
	.data_in(z2_dout),
	.data_out(tocc_dout),
	.addr(z2_addr[15:1]),
	.rd(tocc_rd),
	.hwr(tocc_hwr),
	.lwr(tocc_lwr),
	.sel(tocc_sel & toccata_ena),
	.toc_int(toccata_int6),
	.out_left(toccata_l),
	.out_right(toccata_r)
);

//////////////////////////////  memory  /////////////////////////////////////

wire [15:0] ram_data;
wire [15:0] ramdata_in;
wire [47:0] chip48;
wire [24:1] ram_address;
wire        _ram_bhe, _ram_ble, _ram_we, _ram_oe;
wire        ram_long;

a4k_sdram sdram
(
	.sysclk   (clk_114),
	.c_7m     (c1),
	.reset_n  (~reset),

	.sd_data  (SDRAM_DQ),
	.sd_addr  (SDRAM_A),
	.sd_dqm   ({SDRAM_DQMH, SDRAM_DQML}),
	.sd_cs    (SDRAM_nCS),
	.sd_ba    (SDRAM_BA),
	.sd_we    (SDRAM_nWE),
	.sd_ras   (SDRAM_nRAS),
	.sd_cas   (SDRAM_nCAS),
	.sd_cke   (SDRAM_CKE),
	.sd_clk   (SDRAM_CLK),

	.chipWR   (ram_data),
	.chipAddr (ram_address),
	.chipU    (_ram_bhe),
	.chipL    (_ram_ble),
	.chipRW   (_ram_we),
	.chipDMA  (_ram_oe),
	.chipRD   (ramdata_in),
	.chip48   (chip48),
	.chip32   (ram_long),
	.chipWR2  (chip_dout2),
	.chipRD2  (chip_din2),

	.cpu_req  (sd_req),
	.cpu_ack  (sd_ack),
	.cpu_addr (sd_addr),
	.cpu_we   (sd_we),
	.cpu_be   (sd_be),
	.cpu_wdata(sd_wdata),
	.cpu_rdata(sd_rdata)
);

// DDR3: the motherboard, then the A2065 and the drive sounds (merged)
wire [28:0] mem2_address;
wire  [7:0] mem2_burstcount, mem2_byteenable;
wire        mem2_read, mem2_write;
wire [63:0] mem2_writedata, mem2_readdata;
wire        mem2_readdatavalid, mem2_waitrequest;

wire [28:0] dsnd_addr;
wire        dsnd_rd, dsnd_busy, dsnd_ready;

a2065_ddram_arbiter dsnd_arb
(
	.clk             (clk_114),
	.rst             (reset),

	.m0_address      (a2065_mem_address),
	.m0_burstcount   (a2065_mem_burstcount),
	.m0_read         (a2065_mem_read),
	.m0_readdata     (a2065_mem_readdata),
	.m0_readdatavalid(a2065_mem_readdatavalid),
	.m0_writedata    (a2065_mem_writedata),
	.m0_byteenable   (a2065_mem_byteenable),
	.m0_write        (a2065_mem_write),
	.m0_waitrequest  (a2065_mem_waitrequest),

	.m1_address      (dsnd_addr),
	.m1_burstcount   (8'd1),
	.m1_read         (dsnd_rd),
	.m1_readdata     (),
	.m1_readdatavalid(dsnd_ready),
	.m1_writedata    (64'd0),
	.m1_byteenable   (8'hFF),
	.m1_write        (1'b0),
	.m1_waitrequest  (dsnd_busy),

	.s_address       (mem2_address),
	.s_burstcount    (mem2_burstcount),
	.s_read          (mem2_read),
	.s_readdata      (mem2_readdata),
	.s_readdatavalid (mem2_readdatavalid),
	.s_writedata     (mem2_writedata),
	.s_byteenable    (mem2_byteenable),
	.s_write         (mem2_write),
	.s_waitrequest   (mem2_waitrequest)
);

a4k_ddr3 ddr3
(
	.clk             (clk_114),
	.reset           (reset),

	.cpu_req         (dd_req),
	.cpu_ack         (dd_ack),
	.cpu_addr        (dd_addr),
	.cpu_we          (dd_we),
	.cpu_be          (dd_be),
	.cpu_wdata       (dd_wdata),
	.cpu_rdata       (dd_rdata),

	.mem2_address      (mem2_address),
	.mem2_burstcount   (mem2_burstcount),
	.mem2_read         (mem2_read),
	.mem2_readdata     (mem2_readdata),
	.mem2_readdatavalid(mem2_readdatavalid),
	.mem2_writedata    (mem2_writedata),
	.mem2_byteenable   (mem2_byteenable),
	.mem2_write        (mem2_write),
	.mem2_waitrequest  (mem2_waitrequest),

	.DDRAM_CLK       (DDRAM_CLK),
	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (DDRAM_BURSTCNT),
	.DDRAM_ADDR      (DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (DDRAM_RD),
	.DDRAM_DIN       (DDRAM_DIN),
	.DDRAM_BE        (DDRAM_BE),
	.DDRAM_WE        (DDRAM_WE)
);

drive_sounds drive_sounds
(
	.clk(clk_114),
	.rst(reset),
	.volume(dsnd_volume),
	.drive_snd(drive_snd),
	.sample_l(dsnd_l),
	.sample_r(dsnd_r),
	.ddr_addr(dsnd_addr),
	.ddr_rd(dsnd_rd),
	.ddr_busy(dsnd_busy),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(dsnd_ready)
);

//////////////////////////////  the chipset  ////////////////////////////////

wire  [8:0] drive_snd;

a4k_chipset chipset
(
	.cpu_address  (chip_addr        ),
	.cpu_data     (chip_din         ),
	.cpudata_in   (chip_dout        ),
	._cpu_ipl     (cpu_ipl_n        ),
	._cpu_as      (chip_as          ),
	._cpu_uds     (chip_uds         ),
	._cpu_lds     (chip_lds         ),
	.cpu_r_w      (chip_rw          ),
	.cpu_long     (chip_long        ),
	.chip32_en    (chip32_en        ),
	.ram_long     (ram_long         ),
	._cpu_dtack   (chip_dtack       ),
	._cpu_reset   (sys_rst_n        ),
	._cpu_reset_in(cpu_rsto_n       ),
	.iack7_t      (iack7_t          ),
	.cart_ar      (cart_ar          ),
	.cart_ar_on   (cart_ar_on       ),
	.freeze_t     (freeze_t         ),
	.nmi_t        (cart_nmi_t       ),

	.ram_data     (ram_data         ),
	.ramdata_in   (ramdata_in       ),
	.ram_address  (ram_address      ),
	._ram_bhe     (_ram_bhe         ),
	._ram_ble     (_ram_ble         ),
	._ram_we      (_ram_we          ),
	._ram_oe      (_ram_oe          ),
	.chip48       (chip48           ),

	.rst_ext      (reset            ),
	.rst_out      (                 ),
	.clk          (clk_sys          ),
	.clk7_en      (clk7_en          ),
	.clk7n_en     (clk7n_en         ),
	.c1           (c1               ),
	.c3           (c3               ),
	.cck          (cck              ),
	.eclk         (eclk             ),

	.rxd          (uart_rx          ),
	.txd          (uart_tx          ),
	.cts          (uart_cts         ),
	.rts          (uart_rts         ),
	.dtr          (uart_dtr         ),
	.dsr          (uart_dsr         ),
	.cd           (uart_dsr         ),
	.ri           (1'b1             ),

	._joy1        (~joy0            ),
	._joy2        (~joy1            ),
	._joy3        (~joy2            ),
	._joy4        (~joy3            ),
	.joya1        (joya0            ),
	.joya2        (joya1            ),
	.mouse_btn    (mouse_buttons    ),
	.kbd_mouse_data (kbd_mouse_data ),
	.kbd_mouse_type (kbd_mouse_type ),
	.kms_level    (kbd_mouse_level  ),
	.pwr_led      (pwr_led          ),
	.fdd_led      (fdd_led          ),

	.IO_UIO       (io_uio           ),
	.IO_FPGA      (io_fpga          ),
	.IO_STROBE    (io_strobe        ),
	.IO_WAIT      (io_wait          ),
	.IO_DIN       (io_din           ),
	.IO_DOUT      (io_dout          ),

	._hsync       (hs_n             ),
	._vsync       (vs_n             ),
	._csync       (                 ),
	.field1       (field1           ),
	.lace         (lace             ),
	.red          (red              ),
	.green        (green            ),
	.blue         (blue             ),
	.hblank       (hblank           ),
	.vblank       (vblank           ),
	.ar           (ar               ),
	.scanline     (scanline         ),
	.ce_pix       (                 ),
	.res          (res              ),
	.ntsc         (ntsc             ),

	.ldata        (ldata            ),
	.rdata        (rdata            ),
	.ldata_okk    (ldata_okk        ),
	.rdata_okk    (rdata_okk        ),
	.aud_mix      (aud_mix          ),

	.int2_ext     (ide_irq | a2065_int2 | dmac_int2),
	.int6_ext     (toccata_int6 | dmac_int6),
	.ovl          (ovl              ),
	.extrom_on    (extrom_on        ),

	.cpucfg       (cpucfg           ),
	.cachecfg     (cachecfg         ),
	.memcfg       (memcfg           ),
	.chipsetcfg   (chipsetcfg       ),
	.idecfg       (idecfg           ),

	.USER_IN      (user_in          ),
	.USER_OUT     (user_out         ),
	.user_port_mode       (user_port_mode),
	.mister_floppy_status (mister_floppy_status),
	.drive_snd    (drive_snd        )
);

endmodule
