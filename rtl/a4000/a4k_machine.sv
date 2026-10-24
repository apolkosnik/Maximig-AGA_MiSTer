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
	parameter bit DUAL = 0,          // AP68040 dual issue (the real 68040 has none)
	parameter bit BTIC = 0           // AP68040 BTB target words
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

// CPU clock: TT 0 25 MHz (A3640), 1 33 MHz, 2 50 MHz, 3 56.75 MHz; SS 01: 40 MHz
reg [2:0] cpu_speed;
always @(posedge clk_57) begin
	if (cpucfg[4:3] == 2'b01) cpu_speed <= 3'd2;
	else case (cpucfg[1:0])
		2'd0: cpu_speed <= 3'd0;
		2'd1: cpu_speed <= 3'd1;
		2'd2: cpu_speed <= 3'd3;
		2'd3: cpu_speed <= 3'd4;
	endcase
end

wire       bus_fast = cpucfg[2];                       // P: Fast bus timing
wire [1:0] mbram    = memcfg[3:2];                     // SS: motherboard RAM
wire [2:0] z3cfg    = {memcfg[6], memcfg[5:4]};        // FF + bit 7: Zorro III RAM
wire       z3ram256_fit = (z3cfg >= 3'd4);
wire       z3ram128_fit = (z3cfg != 3'd0) && (z3cfg != 3'd4);

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
wire [31:0] cpu_vbr;            // the VBR (the HRTmon cartridge's NMI vector)
wire        iack7_t;            // the card: toggles at a level-7 interrupt acknowledge
wire  [2:0] cpu_ipl_n;

// the 68040's bus
wire [31:0] c_a, c_do, c_di;
wire        c_rw_n, c_ts_n, c_ta_n, c_tea_n, c_tci_n, c_tbi_n, c_avec_n;
wire  [1:0] c_siz, c_tt;
wire  [2:0] c_tm;

// the CPU's reset input, on its own clock's edges
reg cpu_rsti_n = 1'b0;
always @(posedge clk_57) if (cpu_ce) cpu_rsti_n <= sys_rst_n;

// the RESET instruction for the clk_sys boards (IDE, A2065, Toccata), taken
// on clk_sys (the chipset takes its own)
reg cpu_rsto_sys_n = 1'b1;
always @(posedge clk_sys) cpu_rsto_sys_n <= cpu_rsto_n;

ap68040 #(
	.DUAL(DUAL),
	.BTIC(BTIC)
) cpu (
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
	.ipl_n(cpu_ipl_n), .avec_n(c_avec_n),
	.br_n(), .bg_n(1'b0), .bb_n_i(1'b1), .bb_n_o(), .bb_oe(),
	.rsto_n(cpu_rsto_n), .cdis_n(1'b1), .mdis_n(1'b1), .ipend_n(), .pst(),

	.dbg_pc(dbg_pc), .dbg_retire(dbg_retire), .dbg_halted(dbg_halted),
	.dbg_vbr(cpu_vbr), .dbg_cacr(), .dbg_cmaint(), .dbg_fe(), .dbg_pev()
);

wire        lb_req, lb_ack, lb_we, lb_line, lb_berr, lb_ci;
wire [31:2] lb_addr;
wire  [3:0] lb_be;
wire [31:0] lb_wdata, lb_rdata;
wire  [1:0] lb_beat, lb_tt;
wire  [2:0] lb_tm;

// the card's cost per beat in A4000 timing (calibrated against a real
// A3640, docs/ARCHITECTURE.md)
wire  [2:0] card_pre  = 3'd0;
wire  [2:0] card_post = 3'd0;

a4k_a3640 a3640
(
	.clk(clk_57),
	.ce(cpu_ce),
	.reset(~cpu_rsti_n),

	.a(c_a),
	.ts_n(c_ts_n),
	.rw_n(c_rw_n),
	.siz(c_siz),
	.tt(c_tt),
	.tm(c_tm),
	.d_cpu(c_do),

	.d_mem(c_di),
	.ta_n(c_ta_n),
	.tea_n(c_tea_n),
	.tci_n(c_tci_n),
	.tbi_n(c_tbi_n),
	.avec_n(c_avec_n),
	.iack7_t(iack7_t),

	.pre(card_pre),
	.post(card_post),

	.lb_req(lb_req),
	.lb_ack(lb_ack),
	.lb_addr(lb_addr),
	.lb_be(lb_be),
	.lb_we(lb_we),
	.lb_wdata(lb_wdata),
	.lb_line(lb_line),
	.lb_beat(lb_beat),
	.lb_tt(lb_tt),
	.lb_tm(lb_tm),
	.lb_rdata(lb_rdata),
	.lb_berr(lb_berr),
	.lb_ci(lb_ci),

	.dbg_state()
);

// a beat terminating on the local bus, for the simulation's bus trace
reg lb_ack_d;
always @(posedge clk_57) lb_ack_d <= lb_ack;
assign dbg_lb_beat = lb_ack ^ lb_ack_d;
assign dbg_lb_addr = {lb_addr, 2'b00};
assign dbg_lb_we   = lb_we;
assign dbg_lb_data = lb_we ? lb_wdata : lb_rdata;

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

wire        ovl;

a4k_lbus lbus
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
	.iack7_t(iack7_t),
	.vbr(cpu_vbr),

	.lb_req(lb_req),
	.lb_ack(lb_ack),
	.lb_addr(lb_addr),
	.lb_be(lb_be),
	.lb_we(lb_we),
	.lb_wdata(lb_wdata),
	.lb_line(lb_line),
	.lb_beat(lb_beat),
	.lb_tt(lb_tt),
	.lb_tm(lb_tm),
	.lb_rdata(lb_rdata),
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
wire [15:0] ide0_mgmt_rd;

ide ide0
(
	.clk(clk_sys),
	.rst_n(sys_rst_n & cpu_rsto_sys_n),
	.irq(ide_irq),
	.drq(ide_led),
	.use_fast(1'b1),
	.no_data(ide_nodata),
	.drive_en(ide_present),

	.io_address(ide_io_addr),
	.io_read(ide_io_rd),
	.io_readdata(ide_io_rdata),
	.io_write(ide_io_wr),
	.io_writedata({16'd0, ide_io_wdata}),
	.io_32(1'b0),
	.io_wait(),

	.request(ide_req[2:0]),

	.mgmt_address(ide_mgmt_addr[3:0]),
	.mgmt_write(ide_mgmt_wr & ~ide_mgmt_addr[4]),
	.mgmt_writedata(ide_mgmt_wdata),
	.mgmt_read(ide_mgmt_rd & ~ide_mgmt_addr[4]),
	.mgmt_readdata(ide0_mgmt_rd)
);

assign ide_req[5:3]   = 3'b000;
assign ide_mgmt_rdata = ide_mgmt_addr[4] ? 16'h0000 : ide0_mgmt_rd;

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

	.int2_ext     (ide_irq | a2065_int2),
	.int6_ext     (toccata_int6     ),
	.ovl          (ovl              ),

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
