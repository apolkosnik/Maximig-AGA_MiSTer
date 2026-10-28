// Full-system simulation top: the real machine (a4k_machine: AP68040, the
// A3640 converter, the motherboard, the AGA chipset, the memory
// controllers) with an SDRAM and a DDR3 model.  The C++ driver (sim_main.cpp)
// gives the three edge-aligned clocks, plays the HPS on the IO channel, and
// watches the video, the serial port and the local bus.

module tb_top
#(
	// the machine as a4k_machine builds it (-G on the Verilator command line):
	// both CPU cards and the A4000 by default, as the regression expects
	parameter int CPU_CARD = 2,
	parameter bit A3000P   = 1'b0
)
(
	input             clk_114,
	input             clk_57,
	input             clk_sys,
	input             reset,

	// the HPS's IO channel (userio, Paula's floppy)
	input             io_uio,
	input             io_fpga,
	input             io_strobe,
	output            io_wait,
	input      [15:0] io_din,
	output     [15:0] io_dout,

	input      [64:0] rtc,
	input       [7:0] kbd_mouse_data,
	input       [1:0] kbd_mouse_type,
	input             kbd_mouse_level,
	input       [2:0] mouse_buttons,
	input             cart_ar,       // the cartridge: the Action Replay, not HRTmon
	input             card_bfg,      // the CPU card: the BFG9060, not the A3640

	// video
	output            hs_n,
	output            vs_n,
	output      [7:0] red,
	output      [7:0] green,
	output      [7:0] blue,
	output            hblank,
	output            vblank,
	output            field1,
	output            lace,
	output      [1:0] res,

	// serial
	output            uart_tx,
	output     [14:0] aud_l,
	output     [14:0] aud_r,

	// observation
	output     [31:0] dbg_pc,
	output            dbg_retire,
	output            dbg_halted,
	output            dbg_cpu_ce,
	output            dbg_lb_beat,
	output     [31:0] dbg_lb_addr,
	output            dbg_lb_we,
	output     [31:0] dbg_lb_data,
	output            dbg_xgo,          // exception processing starts
	output      [7:0] dbg_xvec,         // ... its vector
	output     [31:0] dbg_xpc,          // ... the PC it stacks
	output     [15:0] dbg_xsr,          // ... the SR it stacks
	output            pwr_led,
	output            fdd_led
);

wire [12:0] sd_a;
wire  [1:0] sd_ba;
wire [15:0] sd_dq;
wire        sd_dqml, sd_dqmh, sd_cs_n, sd_cas_n, sd_ras_n, sd_we_n, sd_cke, sd_clk;

wire        dd_clk, dd_busy, dd_dout_ready, dd_rd, dd_we;
wire  [7:0] dd_burstcnt, dd_be;
wire [28:0] dd_addr;
wire [63:0] dd_dout, dd_din;

a4k_machine #(.CPU_CARD(CPU_CARD), .A3000P(A3000P)) machine
(
	.clk_114          (clk_114),
	.clk_57           (clk_57),
	.clk_sys          (clk_sys),
	.reset            (reset),

	.clk7_en          (),
	.clk7n_en         (),
	.c1               (),
	.c3               (),
	.cck              (),

	.io_uio           (io_uio),
	.io_fpga          (io_fpga),
	.io_strobe        (io_strobe),
	.io_wait          (io_wait),
	.io_din           (io_din),
	.io_dout          (io_dout),
	.ide_mgmt_addr    (5'd0),
	.ide_mgmt_rd      (1'b0),
	.ide_mgmt_wr      (1'b0),
	.ide_mgmt_wdata   (16'd0),
	.ide_mgmt_rdata   (),
	.ide_req          (),
	.ide_led          (),
	.rtc              (rtc),

	.joy0             (16'd0),
	.joy1             (16'd0),
	.joy2             (16'd0),
	.joy3             (16'd0),
	.joya0            (16'd0),
	.joya1            (16'd0),
	.mouse_buttons    (mouse_buttons),
	.kbd_mouse_level  (kbd_mouse_level),
	.kbd_mouse_type   (kbd_mouse_type),
	.kbd_mouse_data   (kbd_mouse_data),

	.uart_rx          (1'b1),
	.uart_tx          (uart_tx),
	.uart_cts         (1'b1),
	.uart_rts         (),
	.uart_dtr         (),
	.uart_dsr         (1'b1),

	.user_in          (7'h7F),
	.user_out         (),
	.user_port_mode   (),
	.mister_floppy_status(),
	.pwr_led          (pwr_led),
	.fdd_led          (fdd_led),

	.hs_n             (hs_n),
	.vs_n             (vs_n),
	.field1           (field1),
	.lace             (lace),
	.red              (red),
	.green            (green),
	.blue             (blue),
	.hblank           (hblank),
	.vblank           (vblank),
	.ar               (),
	.scanline         (),
	.res              (res),
	.ntsc             (),

	.ldata            (aud_l),
	.rdata            (aud_r),
	.ldata_okk        (),
	.rdata_okk        (),
	.aud_mix          (),
	.toccata_l        (),
	.toccata_r        (),
	.dsnd_volume      (2'd0),
	.cart_ar          (cart_ar),
	.card_bfg         (card_bfg),
	.dsnd_l           (),
	.dsnd_r           (),

	.SDRAM_A          (sd_a),
	.SDRAM_BA         (sd_ba),
	.SDRAM_DQ         (sd_dq),
	.SDRAM_DQML       (sd_dqml),
	.SDRAM_DQMH       (sd_dqmh),
	.SDRAM_nCS        (sd_cs_n),
	.SDRAM_nCAS       (sd_cas_n),
	.SDRAM_nRAS       (sd_ras_n),
	.SDRAM_nWE        (sd_we_n),
	.SDRAM_CKE        (sd_cke),
	.SDRAM_CLK        (sd_clk),

	.DDRAM_CLK        (dd_clk),
	.DDRAM_BUSY       (dd_busy),
	.DDRAM_BURSTCNT   (dd_burstcnt),
	.DDRAM_ADDR       (dd_addr),
	.DDRAM_DOUT       (dd_dout),
	.DDRAM_DOUT_READY (dd_dout_ready),
	.DDRAM_RD         (dd_rd),
	.DDRAM_DIN        (dd_din),
	.DDRAM_BE         (dd_be),
	.DDRAM_WE         (dd_we),

	.FB_EN            (),
	.FB_FORMAT        (),
	.FB_WIDTH         (),
	.FB_HEIGHT        (),
	.FB_BASE          (),
	.FB_STRIDE        (),
	.FB_PAL_CLK       (),
	.FB_PAL_ADDR      (),
	.FB_PAL_DOUT      (),
	.FB_PAL_DIN       (24'd0),
	.FB_PAL_WR        (),

	.dbg_pc           (dbg_pc),
	.dbg_retire       (dbg_retire),
	.dbg_halted       (dbg_halted),
	.dbg_cpu_ce       (dbg_cpu_ce),
	.dbg_lb_beat      (dbg_lb_beat),
	.dbg_lb_addr      (dbg_lb_addr),
	.dbg_lb_we        (dbg_lb_we),
	.dbg_lb_data      (dbg_lb_data)
);
assign dbg_xgo  = machine.dbg_xgo;
assign dbg_xvec = machine.dbg_xvec;
assign dbg_xpc  = machine.dbg_xpc;
assign dbg_xsr  = machine.cpu.be.x_osr;

sdram_model sdram
(
	.clk   (sd_clk),
	.a     (sd_a),
	.ba    (sd_ba),
	.dq    (sd_dq),
	.dqml  (sd_dqml),
	.dqmh  (sd_dqmh),
	.cs_n  (sd_cs_n),
	.ras_n (sd_ras_n),
	.cas_n (sd_cas_n),
	.we_n  (sd_we_n)
);

ddr3_model ddr3
(
	.clk        (clk_114),
	.busy       (dd_busy),
	.burstcnt   (dd_burstcnt),
	.addr       (dd_addr),
	.dout       (dd_dout),
	.dout_ready (dd_dout_ready),
	.rd         (dd_rd),
	.din        (dd_din),
	.be         (dd_be),
	.we         (dd_we)
);

endmodule
