//============================================================================
//  Maximig: an Amiga 4000/040 for MiSTer
//
//  The CPU card (an A3640: AP68040 and its bus converter), the A4000
//  motherboard (local bus, Gary, Ramsey, Budgie, Buster, IDE, RTC), the AGA
//  chipset and the Zorro boards.  docs/ARCHITECTURE.md describes it.
//
//  The MiSTer glue (HPS, video, audio) follows Minimig.sv (Alexey Melnikov).
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign BUTTONS = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

`include "build_id.v"
localparam CONF_STR = {
`ifdef MAXIMIG_AS_MINIMIG
	"Minimig;UART115200:230400,MIDI;",
`else
	"Maximig;UART115200:230400,MIDI;",
`endif
	"J,Red(Fire),Blue,Yellow,Green,RT,LT,Pause;",
	"jn,A,B,X,Y,R,L,Start;",
	"jp,B,A,X,Y,R,L,Start;",
	"-;",
	"I,",
	"MT32-pi: SoundFont #0,",
	"MT32-pi: SoundFont #1,",
	"MT32-pi: SoundFont #2,",
	"MT32-pi: SoundFont #3,",
	"MT32-pi: SoundFont #4,",
	"MT32-pi: SoundFont #5,",
	"MT32-pi: SoundFont #6,",
	"MT32-pi: SoundFont #7,",
	"MT32-pi: MT-32 v1,",
	"MT32-pi: MT-32 v2,",
	"MT32-pi: CM-32L,",
	"MT32-pi: Unknown mode;",
	"V,v",`BUILD_DATE
};

wire [15:0] JOY0;
wire [15:0] JOY1;
wire [15:0] JOY2;
wire [15:0] JOY3;
wire [15:0] JOYA0;
wire [15:0] JOYA1;
wire  [7:0] kbd_mouse_data;
wire        kbd_mouse_level;
wire  [1:0] kbd_mouse_type;
wire  [2:0] mouse_buttons;
wire [64:0] RTC;

wire        ce_pix;
wire  [1:0] buttons;
wire [63:0] status;
wire        forced_scandoubler;

wire        io_strobe;
wire        io_wait;
wire        io_fpga;
wire        io_uio;
wire [15:0] io_din;
wire [15:0] fpga_dout;

wire [21:0] gamma_bus;
wire  [7:0] uart_mode;
wire  [2:0] mister_floppy_status;

hps_io #(.CONF_STR(CONF_STR), .CONF_STR_BRAM(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS({HPS_BUS[45:42],ce_pix,HPS_BUS[40:0]}),

	.status(status),
	.status_menumask({mister_floppy_status, mt32_cfg, mt32_available}),
	.info_req(mt32_info_req),
	.info(mt32_info_disp),

	.joystick_0(JOY0),
	.joystick_1(JOY1),
	.joystick_2(JOY2),
	.joystick_3(JOY3),
	.joystick_l_analog_0(JOYA0),
	.joystick_l_analog_1(JOYA1),

	.ioctl_wait(io_wait),

	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),

	.uart_mode(uart_mode),

	.RTC(RTC),
	.gamma_bus(gamma_bus),

	.EXT_BUS(EXT_BUS)
);

// the Minimig HPS protocol: IDE, mouse and keyboard, video mode
wire [15:0] ide_din;
wire [15:0] ide_dout;
wire  [4:0] ide_addr;
wire        ide_rd;
wire        ide_wr;
wire  [5:0] ide_req;

wire [35:0] EXT_BUS;
wire [11:0] shbl_l, shbl_r, svbl_t, svbl_b;
wire        sset;

hps_ext hps_ext
(
	.clk_sys(clk_sys),
	.EXT_BUS(EXT_BUS),
	.io_strobe(io_strobe),
	.io_fpga(io_fpga),
	.io_uio(io_uio),
	.io_din(io_din),
	.fpga_dout(fpga_dout),

	.ide_din(ide_din),
	.ide_dout(ide_dout),
	.ide_addr(ide_addr),
	.ide_rd(ide_rd),
	.ide_wr(ide_wr),
	.ide_req(ide_req),

	.mouse_buttons(mouse_buttons),
	.kbd_mouse_level(kbd_mouse_level),
	.kbd_mouse_type(kbd_mouse_type),
	.kbd_mouse_data(kbd_mouse_data),

	.scr_hbl_l(scr_hbl_l),
	.scr_hbl_r(scr_hbl_r),
	.scr_hsize(scr_hsize),
	.scr_vbl_t(scr_vbl_t),
	.scr_vbl_b(scr_vbl_b),
	.scr_vsize(scr_vsize),
	.scr_flg(scr_flg),
	.scr_res(scr_res),

	.shbl_l(shbl_l),
	.shbl_r(shbl_r),
	.svbl_t(svbl_t),
	.svbl_b(svbl_b),
	.sset(sset),

	.cdda_req(1'b0),
	.cdda_wr(),
	.cdda_dout(),

	.akiko_din(16'h0000),
	.akiko_dout(),
	.akiko_wr(),
	.akiko_rd(),
	.akiko_cs(),
	.akiko_cs_sec(),
	.akiko_cs_nvr(),
	.akiko_cs_subcode(),
	.akiko_req(1'b0),
	.akiko_sec_req(1'b0),
	.akiko_rx_busy(1'b0),
	.akiko_nvr_dirty(1'b0),

	.cdtv_din(16'h0000),
	.cdtv_dout(),
	.cdtv_wr(),
	.cdtv_rd(),
	.cdtv_cs(),
	.cdtv_cs_sec(),
	.cdtv_cs_stch(),
	.cdtv_cs_nvr(),
	.cdtv_cs_card(),
	.cdtv_req(1'b0),
	.cdtv_nvr_dirty(1'b0),
	.cdtv_card_dirty(1'b0)
);

assign LED_POWER[1] = 1;
assign LED_DISK     = {1'b0, ide_led};
assign VGA_SCALER   = FB_EN;

//////////////////////////////  clocks  //////////////////////////////////

wire clk_114;
wire clk_sys;
wire clk_57;
wire locked;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_114),
	.outclk_1(clk_sys),
	.outclk_2(clk_57),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// PAL/NTSC: the VCO's fractional multiplier (every output scales with it)
always @(posedge CLK_50M) begin
	reg ntscd = 0, ntscd2 = 0;
	reg [2:0] state = 0;
	reg ntsc_r;

	ntscd <= ntsc;
	ntscd2 <= ntscd;

	cfg_write <= 0;
	if(ntscd2 == ntscd && ntscd2 != ntsc_r) begin
		state <= 1;
		ntsc_r <= ntscd2;
	end

	if(!cfg_waitrequest) begin
		if(state) state<=state+1'd1;
		case(state)
			1: begin
					cfg_address <= 0;
					cfg_data <= 0;
					cfg_write <= 1;
				end
			3: begin
					cfg_address <= 7;
					cfg_data <= ntsc_r ? 702807747 : 343817200;
					cfg_write <= 1;
				end
			5: begin
					cfg_address <= 2;
					cfg_data <= 0;
					cfg_write <= 1;
				end
		endcase
	end
end

wire reset = ~locked | buttons[1] | RESET;

reg reset_d;
always @(posedge clk_sys, posedge reset) begin
	reg [7:0] reset_s;
	reg rs;

	if(reset) reset_s <= '1;
	else begin
		reset_s <= reset_s << 1;
		rs <= reset_s[7];
		reset_d <= rs;
	end
end

// the Amiga
wire        clk7_en, clk7n_en, c1, c3, cck;
wire        hs, vs;
wire [14:0] ldata, rdata;
wire  [8:0] ldata_okk, rdata_okk;
wire  [1:0] ar;
wire        ntsc;
wire        ide_led;
wire [15:0] toccata_aud_left, toccata_aud_right;
wire [15:0] dsnd_l, dsnd_r;
wire        pwr_led;

wire uart_cts, uart_dsr, uart_rts, uart_dtr;
wire uart_tx, uart_rx;

wire  [6:0] IndirectUserOutmt32;
wire  [6:0] IndirectUserOutFlop;
wire        user_port_mode;
assign USER_OUT = user_port_mode ? IndirectUserOutFlop : IndirectUserOutmt32;

// this branch's machine: the AA3000+ (docs/AA3000.md) with the BFG9060;
// no drive sounds (room for the DSP3210)
// (the DSP3210 core does not fit beside the rest yet: docs/AA3000.md)
a4k_machine #(.CPU_CARD(1), .A3000P(1'b1), .DSP3210(1'b0), .DRIVE_SOUNDS(1'b0)) machine
(
	.clk_114          (clk_114),
	.clk_57           (clk_57),
	.clk_sys          (clk_sys),
	.reset            (reset_d),

	.clk7_en          (clk7_en),
	.clk7n_en         (clk7n_en),
	.c1               (c1),
	.c3               (c3),
	.cck              (cck),

	.io_uio           (io_uio),
	.io_fpga          (io_fpga),
	.io_strobe        (io_strobe),
	.io_wait          (io_wait),
	.io_din           (io_din),
	.io_dout          (fpga_dout),
	.ide_mgmt_addr    (ide_addr),
	.ide_mgmt_rd      (ide_rd),
	.ide_mgmt_wr      (ide_wr),
	.ide_mgmt_wdata   (ide_dout),
	.ide_mgmt_rdata   (ide_din),
	.ide_req          (ide_req),
	.ide_led          (ide_led),
	.rtc              (RTC),

	.joy0             (JOY0),
	.joy1             (JOY1),
	.joy2             (JOY2),
	.joy3             (JOY3),
	.joya0            (JOYA0),
	.joya1            (JOYA1),
	.mouse_buttons    (mouse_buttons),
	.kbd_mouse_level  (kbd_mouse_level),
	.kbd_mouse_type   (kbd_mouse_type),
	.kbd_mouse_data   (kbd_mouse_data),

	.uart_rx          (uart_rx),
	.uart_tx          (uart_tx),
	.uart_cts         (uart_cts),
	.uart_rts         (uart_rts),
	.uart_dtr         (uart_dtr),
	.uart_dsr         (uart_dsr),

	.user_in          (USER_IN),
	.user_out         (IndirectUserOutFlop),
	.user_port_mode   (user_port_mode),
	.mister_floppy_status(mister_floppy_status),
	.pwr_led          (pwr_led),
	.fdd_led          (LED_USER),

	.hs_n             (hs),
	.vs_n             (vs),
	.field1           (field1),
	.lace             (lace),
	.red              (r),
	.green            (g),
	.blue             (b),
	.hblank           (hblank),
	.vblank           (vbl),
	.ar               (ar),
	.scanline         (fx),
	.res              (res),
	.ntsc             (ntsc),

	.ldata            (ldata),
	.rdata            (rdata),
	.ldata_okk        (ldata_okk),
	.rdata_okk        (rdata_okk),
	.aud_mix          (AUDIO_MIX),
	.toccata_l        (toccata_aud_left),
	.toccata_r        (toccata_aud_right),
	.dsnd_volume      (status[52:51]),
	.cart_ar          (status[55]),     // Main's ext_cfg bit 23, as Minimig's (bits 19-22 are Minimig's)
	.card_bfg         (status[56]),     // ext_cfg bit 24
	.dsnd_l           (dsnd_l),
	.dsnd_r           (dsnd_r),

	.SDRAM_A          (SDRAM_A),
	.SDRAM_BA         (SDRAM_BA),
	.SDRAM_DQ         (SDRAM_DQ),
	.SDRAM_DQML       (SDRAM_DQML),
	.SDRAM_DQMH       (SDRAM_DQMH),
	.SDRAM_nCS        (SDRAM_nCS),
	.SDRAM_nCAS       (SDRAM_nCAS),
	.SDRAM_nRAS       (SDRAM_nRAS),
	.SDRAM_nWE        (SDRAM_nWE),
	.SDRAM_CKE        (SDRAM_CKE),
	.SDRAM_CLK        (SDRAM_CLK),

	.DDRAM_CLK        (DDRAM_CLK),
	.DDRAM_BUSY       (DDRAM_BUSY),
	.DDRAM_BURSTCNT   (DDRAM_BURSTCNT),
	.DDRAM_ADDR       (DDRAM_ADDR),
	.DDRAM_DOUT       (DDRAM_DOUT),
	.DDRAM_DOUT_READY (DDRAM_DOUT_READY),
	.DDRAM_RD         (DDRAM_RD),
	.DDRAM_DIN        (DDRAM_DIN),
	.DDRAM_BE         (DDRAM_BE),
	.DDRAM_WE         (DDRAM_WE),

	.FB_EN            (FB_EN),
	.FB_FORMAT        (FB_FORMAT),
	.FB_WIDTH         (FB_WIDTH),
	.FB_HEIGHT        (FB_HEIGHT),
	.FB_BASE          (FB_BASE),
	.FB_STRIDE        (FB_STRIDE),
	.FB_PAL_CLK       (FB_PAL_CLK),
	.FB_PAL_ADDR      (FB_PAL_ADDR),
	.FB_PAL_DOUT      (FB_PAL_DOUT),
	.FB_PAL_DIN       (FB_PAL_DIN),
	.FB_PAL_WR        (FB_PAL_WR),

	.dbg_pc           (),
	.dbg_retire       (),
	.dbg_halted       (),
	.dbg_cpu_ce       (),
	.dbg_lb_beat      (),
	.dbg_lb_addr      (),
	.dbg_lb_we        (),
	.dbg_lb_data      ()
);

assign FB_FORCE_BLANK = 0;

////////////////////////////  UART  ////////////////////////////////////

wire hps_mpu = (uart_mode >= 3);

assign UART_RTS = ~hps_mpu & uart_rts;
assign UART_DTR = ~hps_mpu & uart_dtr;
assign uart_cts = ~hps_mpu & UART_CTS;
assign uart_dsr = ~hps_mpu & UART_DSR;
assign uart_rx  = uart_mode ? UART_RXD : midi_rx;
assign UART_TXD = (hps_mpu & mt32_use) | uart_tx;

// power LED
reg [5:0] led_cnt;
reg led_dim;

always @ (posedge clk_sys) begin
	led_cnt <= led_cnt + 1'd1;
	led_dim <= |led_cnt[5:2];
end

assign LED_POWER[0] = pwr_led | ~led_dim;

//////////////////////////////  video  //////////////////////////////////////

reg ce_out = 0;
always @(posedge CLK_VIDEO) begin
	reg [3:0] div;
	reg [3:0] add;
	reg [1:0] fs_res;
	reg old_vs;

	div <= div + add;
	if(~hblank & ~vblank) fs_res <= fs_res | res;

	old_vs <= vs;
	if(old_vs & ~vs) begin
		fs_res <= 0;
		div <= 0;
		add <= 1; // 7MHz
		if(fs_res[0]) add <= 2; // 14MHz
		if(fs_res[1] | (~status[42] & ~scandoubler)) add <= 4; // 28MHz
	end

	ce_out <= div[3] & !div[2:0];
end

assign ce_pix = ce_out;

wire [2:0] fx;
wire       scandoubler = (fx || forced_scandoubler) & ~lace;
wire [7:0] R,G,B;

video_mixer #(.LINE_LENGTH(2000), .HALF_DEPTH(0), .GAMMA(1)) video_mixer
(
	.*,
	.hq2x(fx==1),
	.ce_pix(ce_out),
	.freeze_sync(),

	.R(r),
	.G(g),
	.B(b),
	.HSync(~hs),
	.VSync(~vs),
	.HBlank(~hde),
	.VBlank(~vde),

	.VGA_R(R),
	.VGA_G(G),
	.VGA_B(B)
);

assign CLK_VIDEO = clk_114;
assign VGA_F1    = field1;
assign VGA_R     = mt32_lcd ? {{2{mt32_lcd_pix}},R[7:2]} : R;
assign VGA_G     = mt32_lcd ? {{2{mt32_lcd_pix}},G[7:2]} : G;
assign VGA_B     = mt32_lcd ? {{2{mt32_lcd_pix}},B[7:2]} : B;

wire [12:0] arx,ary;
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.VIDEO_ARX(arx),
	.VIDEO_ARY(ary),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[45:43])
);

reg [11:0] fb_arx, fb_ary;
always @(posedge CLK_VIDEO) begin
	reg [11:0] x, y, x1, y1;
	reg [1:0] cnt;

	cnt <= cnt + 1'd1;
	case(cnt)
		0: begin
				x1 <= FB_WIDTH;
				y1 <= FB_HEIGHT;
				x  <= FB_WIDTH;
				y  <= FB_HEIGHT;
			end

		1: if(x && ((x+x1) <= HDMI_WIDTH) && y && ((y+y1) <= HDMI_HEIGHT)) begin
				x <= x+x1;
				y <= y+y1;
				cnt <= 1;
			end

		2: begin
				fb_arx <= x;
				fb_ary <= y;
			end
	endcase
end

assign VIDEO_ARX = FB_EN ? {status[46], fb_arx} : arx;
assign VIDEO_ARY = FB_EN ? {status[46], fb_ary} : ary;

wire [2:0] sl = fx ? fx - 1'd1 : 3'd0;
assign VGA_SL = sl[1:0];

reg  hde;
wire vde = ~(fvbl | svbl);

wire [7:0] r,g,b;
wire lace, field1;
wire hblank, vbl;
wire vblank = vbl | ~vs;
reg  fhbl, fvbl, shbl, svbl;
wire hbl = fhbl | shbl | ~hs;

wire  [1:0] res;

reg  [11:0] hbl_l=0, hbl_r=0;
reg  [11:0] hsta, hend, hmax, hcnt;
reg  [11:0] hsize;
always @(posedge clk_sys) begin
	reg old_hs;
	reg old_hblank;

	old_hs <= hs;
	old_hblank <= hblank;

	hcnt <= hcnt + 1'd1;
	if(~hs) hcnt <= 0;

	if(old_hblank & ~hblank) hend <= hcnt;
	if(~old_hblank & hblank) hsta <= hcnt;
	if(old_hs & ~hs)         hmax <= hcnt;

	if(hcnt == hend+hbl_l-2'd2) shbl <= 0;
	if(hcnt == hsta+hbl_r-2'd2) shbl <= 1;

	//force hblank
	if(hcnt == 8)         fhbl <= 0;
	if(hcnt == hmax-4'd8) fhbl <= 1;

	if(~old_hblank & hblank & ~field1 & (vcnt == 1'd1)) hsize <= hcnt - hend;
end

reg [11:0] vbl_t=0, vbl_b=0;
reg [11:0] vend, vmax, f1_vend, f1_vsize, vcnt, vs_end;
reg [11:0] vsize;
always @(posedge clk_sys) begin
	reg old_vs;
	reg old_vblank, old_hs, old_hbl;

	old_vs <= vs;
	old_hs <= hs;
	old_vblank <= vblank;

	if(old_hs & ~hs) vcnt <= vcnt + 1'd1;
	if(~old_vblank & vblank) vcnt <= 0;

	if(~lace | ~field1) begin
		if(old_vblank & ~vblank) vend <= vcnt;
		if(~old_vs & vs)         vs_end <= vcnt;

		if(~old_vblank & vblank) begin
			vmax <= vcnt;
			vsize <= vcnt - vend + f1_vsize;
			f1_vsize <= 0;
		end
	end
	else begin
		if(old_vblank & ~vblank) f1_vend <= vcnt;
		if(~old_vblank & vblank) begin
			f1_vsize <= vcnt - f1_vend;
		end
	end

	old_hbl <= hbl;
	if((old_hbl & ~hbl) | !vcnt) begin
		if(vcnt == vend+vbl_t) svbl <= 0;
		if(vcnt == (vbl_b[11] ? vmax+vbl_b : vbl_b) ) svbl <= 1;

		//force vblank
		if(vcnt == vmax-1)    fvbl <= 1;
		if(vcnt == vs_end+2)  fvbl <= 0;
	end

	hde <= ~hbl;
end

always @(posedge clk_sys) begin
	reg old_level;
	reg alt = 0;

	old_level <= kbd_mouse_level;
	if((old_level ^ kbd_mouse_level) && (kbd_mouse_type==3)) begin
		if(kbd_mouse_data == 'h41) begin //backspace
			vbl_t <= 0; vbl_b <= 0;
			hbl_l <= 0; hbl_r <= 0;
		end
		else if(kbd_mouse_data == 'h4c) begin //up
			if(alt) vbl_b <= vbl_b + 1'd1;
			else    vbl_t <= vbl_t + 1'd1;
		end
		else if(kbd_mouse_data == 'h4d) begin //down
			if(alt) vbl_b <= vbl_b - 1'd1;
			else    vbl_t <= vbl_t - 1'd1;
		end
		else if(kbd_mouse_data == 'h4f) begin //left
			if(alt) hbl_r <= hbl_r + 3'd4;
			else    hbl_l <= hbl_l + 3'd4;
		end
		else if(kbd_mouse_data == 'h4e) begin //right
			if(alt) hbl_r <= hbl_r - 3'd4;
			else    hbl_l <= hbl_l - 3'd4;
		end
		else if(kbd_mouse_data == 'h64 || kbd_mouse_data == 'h65) begin //alt press
			alt <= 1;
		end
		else if(kbd_mouse_data == 'hE4 || kbd_mouse_data == 'hE5) begin //alt release
			alt <= 0;
		end
	end

	if(sset) begin
		vbl_t <= svbl_t; vbl_b <= svbl_b;
		hbl_l <= shbl_l; hbl_r <= shbl_r;
	end
end

reg [11:0] scr_hbl_l, scr_hbl_r;
reg [11:0] scr_vbl_t, scr_vbl_b;
reg [11:0] scr_hsize, scr_vsize;
reg  [1:0] scr_res;
reg  [6:0] scr_flg;

always @(posedge clk_sys) begin
	reg old_vblank;

	old_vblank <= vblank;
	if(old_vblank & ~vblank) begin
		scr_hbl_l <= hbl_l;
		scr_hbl_r <= hbl_r;
		scr_vbl_t <= vbl_t;
		scr_vbl_b <= vbl_b;
		scr_hsize <= hsize;
		scr_vsize <= vsize;
		scr_res   <= res;

		if(scr_res != res || scr_vsize != vsize || scr_hsize != hsize) scr_flg <= scr_flg + 1'd1;
	end
end

////////////////////////////  MT32pi  //////////////////////////////////

reg   userport_change_reset;
wire        mt32_reset    = status[32] | reset | userport_change_reset;
wire        mt32_disable  = status[33];
wire        mt32_mode_req = status[34];
wire  [1:0] mt32_rom_req  = status[36:35];
wire  [7:0] mt32_sf_req   = status[39:37];
wire  [1:0] mt32_info     = status[41:40];
wire        midi_tx       = uart_tx;

wire [15:0] mt32_i2s_r, mt32_i2s_l;
wire  [7:0] mt32_mode, mt32_rom, mt32_sf;
wire        mt32_lcd_en, mt32_lcd_pix, mt32_lcd_update;
wire        midi_rx;

wire mt32_newmode;
wire mt32_available;
wire mt32_use  = mt32_available & ~mt32_disable;
wire mt32_mute = mt32_available &  mt32_disable;

mt32pi mt32pi
(
	.*,
	.USER_IN(USER_IN),
	.USER_OUT(IndirectUserOutmt32),

	.CE_PIXEL(ce_pix_mt32),
	.reset(mt32_reset),
	.midi_tx(midi_tx | mt32_mute)
);

wire  [4:0] mt32_cfg = (mt32_mode == 'hA2) ? {mt32_sf[2:0],  2'b10} :
                       (mt32_mode == 'hA1) ? {mt32_rom[1:0], 2'b01} : 5'd0;

reg mt32_info_req;
reg [3:0] mt32_info_disp;
reg last_userport_mode;
always @(posedge clk_sys) begin
	reg old_mode;

	userport_change_reset <= 0;
	last_userport_mode <= user_port_mode;
	if (last_userport_mode != user_port_mode) userport_change_reset <= 1;

	old_mode <= mt32_newmode;
	mt32_info_req <= (old_mode ^ mt32_newmode) && (mt32_info == 1);

	mt32_info_disp <= (mt32_mode == 'hA2) ? (4'd1 + mt32_sf[2:0]) :
                     (mt32_mode == 'hA1 && mt32_rom == 0) ?  4'd9 :
                     (mt32_mode == 'hA1 && mt32_rom == 1) ?  4'd10 :
                     (mt32_mode == 'hA1 && mt32_rom == 2) ?  4'd11 : 4'd12;
end

reg mt32_lcd_on;
always @(posedge CLK_VIDEO) begin
	int to;
	reg old_update;

	old_update <= mt32_lcd_update;
	if(to) to <= to - 1;

	if(mt32_info == 2) mt32_lcd_on <= 1;
	else if(mt32_info != 3) mt32_lcd_on <= 0;
	else begin
		if(!to) mt32_lcd_on <= 0;
		if(old_update ^ mt32_lcd_update) begin
			mt32_lcd_on <= 1;
			to <= 114000000 * 2;
		end
	end
end

wire mt32_lcd = mt32_lcd_on & mt32_lcd_en;

reg ce_pix_mt32;
always @(posedge CLK_VIDEO) begin
	reg [3:0] div;

	div <= div + 1'd1;
	ce_pix_mt32 <= !div;
end

//////////////////////////////  audio  ///////////////////////////////////////

wire flt_en    = ~status[48] ? pwr_led : status[47];
wire aud_1200  = status[49];
wire paula_pwm = status[50];

wire [15:0] paula_smp_l = (paula_pwm ? {ldata_okk[8:0], 7'b0} : {ldata[14:0], 1'b0});
wire [15:0] paula_smp_r = (paula_pwm ? {rdata_okk[8:0], 7'b0} : {rdata[14:0], 1'b0});

// LPF 4400Hz, 1st order, 6db/oct
wire [15:0] lpf4400_l, lpf4400_r;
IIR_filter #(0) lpf4400
(
	.clk(clk_sys),
	.reset(reset),

	.ce(clk7_en | clk7n_en),
	.sample_ce(1),

	.cx (40'd4304835800),
	.cx0(1),
	.cy0(-2088941),

	.input_l(paula_smp_l),
	.input_r(paula_smp_r),
	.output_l(lpf4400_l),
	.output_r(lpf4400_r)
);

wire [15:0] audm_l = aud_1200 ? paula_smp_l : lpf4400_l;
wire [15:0] audm_r = aud_1200 ? paula_smp_r : lpf4400_r;

// LPF 3000Hz 1st + 3400Hz 1st
wire [15:0] lpf3275_l, lpf3275_r;
IIR_filter #(0) lpf3275
(
	.clk(clk_sys),
	.reset(reset),

	.ce(clk7_en | clk7n_en),
	.sample_ce(1),

	.cx (40'd8536629),
	.cx0(2),
	.cx1(1),
	.cy0(-4182432),
	.cy1(2085297),

	.input_l(audm_l),
	.input_r(audm_r),
	.output_l(lpf3275_l),
	.output_r(lpf3275_r)
);

reg [15:0] aud_l, aud_r;
always @(posedge CLK_AUDIO) begin
	reg [15:0] old_l0, old_l1, old_r0, old_r1;

	old_l0 <= flt_en ? lpf3275_l : audm_l;
	old_l1 <= old_l0;
	if(old_l0 == old_l1) aud_l <= old_l1;

	old_r0 <= flt_en ? lpf3275_r : audm_r;
	old_r1 <= old_r0;
	if(old_r0 == old_r1) aud_r <= old_r1;
end

reg [15:0] dsnd_al, dsnd_ar;
always @(posedge CLK_AUDIO) begin
	reg [31:0] old_d0, old_d1;

	old_d0 <= {dsnd_l, dsnd_r};
	old_d1 <= old_d0;
	if(old_d0 == old_d1) {dsnd_al, dsnd_ar} <= old_d1;
end

reg [15:0] out_l, out_r;
always @(posedge CLK_AUDIO) begin
	reg [17:0] tmp_l, tmp_r;

	tmp_l <= {{2{aud_l[15]}},aud_l} + {{2{toccata_aud_left[15]}},toccata_aud_left} + (mt32_mute ? 18'd0 : {{2{mt32_i2s_l[15]}},mt32_i2s_l}) + {{2{dsnd_al[15]}}, dsnd_al};
	tmp_r <= {{2{aud_r[15]}},aud_r} + {{2{toccata_aud_right[15]}},toccata_aud_right} + (mt32_mute ? 18'd0 : {{2{mt32_i2s_r[15]}},mt32_i2s_r}) + {{2{dsnd_ar[15]}}, dsnd_ar};

	// clamp the output
	out_l <= (tmp_l[17:15] == 3'b000 || tmp_l[17:15] == 3'b111) ? tmp_l[15:0] : {tmp_l[17], {15{~tmp_l[17]}}};
	out_r <= (tmp_r[17:15] == 3'b000 || tmp_r[17:15] == 3'b111) ? tmp_r[15:0] : {tmp_r[17], {15{~tmp_r[17]}}};
end

assign AUDIO_S = 1;
assign AUDIO_L = out_l;
assign AUDIO_R = out_r;

endmodule
