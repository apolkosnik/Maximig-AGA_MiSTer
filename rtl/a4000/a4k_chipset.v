// a4k_chipset: the A4000's chip bus -- Alice, Lisa, Paula, the two 8520s,
// chip RAM -- as Minimig's chipset (minimig.v, Dennis van Weeren, Jakub
// Bednarski, Sascha Boing, Tobias Gubener, Alexey Melnikov et al.) with the
// A4000's configuration fixed: AGA, 2 MB chip RAM, and none of Minimig's
// cartridge, Akiko, CDTV, Gayle or 68000/68020 CPU paths.
//
// The CPU reaches the chip bus only through Alice's CPU port, the 68000-
// style minimig_m68k_bridge, driven by a4k_budgie: chip RAM, the custom
// registers (at $DFF000 and Fat Gary's mirror at $C00000-$CFFFFF) and the
// CIAs.  ROM, fast memory and the other I/O are the motherboard's
// (a4k_lbus).  The HPS still writes memory through the bridge's host port
// with the CPU halted (userio): chip RAM, the custom registers for its boot
// screen, and the Kickstart image, which this decode maps to the SDRAM's
// ROM area ($F80000 -> 0x780000; Minimig's $E00000 copy -> 0x700000).
//
// This file is part of Minimig-derived code and is distributed under the
// GNU General Public License version 3 or later.

module a4k_chipset
(
	// Alice's CPU port (a4k_budgie)
	input  [23:1] cpu_address,
	output [15:0] cpu_data,
	input  [15:0] cpudata_in,
	output  [2:0] _cpu_ipl,
	input         _cpu_as,
	input         _cpu_uds,
	input         _cpu_lds,
	input         cpu_r_w,
	input         cpu_long,
	output        chip32_en,
	output        ram_long,
	output        _cpu_dtack,
	output        _cpu_reset,     // to the CPU: the system reset
	input         _cpu_reset_in,  // from the CPU: RSTO, the RESET instruction
	input         iack7_t,        // from the card: toggles at a level-7 interrupt acknowledge

	// chip RAM (SDRAM chip port, through a4k_sdram)
	output [15:0] ram_data,
	input  [15:0] ramdata_in,
	output [24:1] ram_address,
	output        _ram_bhe,
	output        _ram_ble,
	output        _ram_we,
	output        _ram_oe,
	input  [47:0] chip48,

	// system
	input         rst_ext,
	output        rst_out,
	input         clk,
	input         clk7_en,
	input         clk7n_en,
	input         c1,
	input         c3,
	input         cck,
	input   [9:0] eclk,

	// serial
	input         rxd,
	output        txd,
	input         cts,
	output        rts,
	output        dtr,
	input         dsr,
	input         cd,
	input         ri,

	// I/O
	input  [15:0] _joy1,
	input  [15:0] _joy2,
	input  [15:0] _joy3,
	input  [15:0] _joy4,
	input  [15:0] joya1,
	input  [15:0] joya2,
	input   [2:0] mouse_btn,
	input         kms_level,
	input   [1:0] kbd_mouse_type,
	input   [7:0] kbd_mouse_data,
	output        pwr_led,
	output        fdd_led,

	// host controller interface
	input         IO_UIO,
	input         IO_FPGA,
	input         IO_STROBE,
	output        IO_WAIT,
	input  [15:0] IO_DIN,
	output [15:0] IO_DOUT,

	// video
	output        _hsync,
	output        _vsync,
	output        _csync,
	output        field1,
	output        lace,
	output        hblank,
	output        vblank,
	output  [7:0] red,
	output  [7:0] green,
	output  [7:0] blue,
	output  [1:0] ar,
	output  [2:0] scanline,
	output        ce_pix,
	output  [1:0] res,
	output reg    ntsc,

	// audio
	output [14:0] ldata,
	output [14:0] rdata,
	output  [8:0] ldata_okk,
	output  [8:0] rdata_okk,
	output  [1:0] aud_mix,

	// interrupts from the motherboard and the Zorro boards
	input         int2_ext,
	input         int6_ext,

	// the OVL bit (CIA-A PA0) for the motherboard's ROM decode
	output reg    ovl,
	output reg    extrom_on = 1'b0,   // an extension ROM has been uploaded since the last halt

	// user i/o
	output  [4:0] cpucfg,
	output  [2:0] cachecfg,
	output  [6:0] memcfg,
	output  [5:0] chipsetcfg,
	output  [5:0] idecfg,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,
	output        user_port_mode,
	output  [2:0] mister_floppy_status,
	output  [8:0] drive_snd
);

// data buses
wire [15:0] cpu_data_in;
wire [15:0] cpu_data_out;
wire [15:0] ram_data_in;
wire [15:0] ram_data_out;
wire [15:0] custom_data_in;
wire [15:0] custom_data_out;
wire [15:0] agnus_data_out;
wire [15:0] paula_data_out;
wire [15:0] denise_data_out;
wire [15:0] user_data_out;
wire [15:0] gary_data_out;
wire [15:0] cia_data_out;

// address buses
wire [23:1] cpu_address_out;
wire [20:1] dma_address_out;
wire        bitplane_dma;
wire        bitplane_fetch_phase;
wire        bitplane_fetch_phase_valid;
wire        bitplane_fetch_unit_start;

// control
wire        ram_rd, ram_hwr, ram_lwr;
wire        cpu_rd, rd_cyc, cpu_hwr, cpu_lwr;
wire  [8:1] reg_address;
wire        cpu_custom;
wire        dbr, dbwe;
wire        _led;
wire        int2, int3, int6;
wire        _fire0, _fire1, _fire0_dat, _fire1_dat;
wire  [3:0] audio_dmal, audio_dmas;
wire        disk_dmal, disk_dmas;
wire        index;

// the chip-bus decode (Gary's part of it on this side), see below
wire        cpuhlt;
wire  [23:1] a = cpu_address_out;
wire        sel_chip = !dbr && a[23:21] == 3'b000;                     // $000000-$1FFFFF
wire        sel_kick = !dbr && cpuhlt && a[23:19] == 5'b11111;         // $F80000-$FFFFFF
wire        sel_ext  = !dbr && cpuhlt && a[23:19] == 5'b11100;         // $E00000-$E7FFFF
wire        sel_reg  = a[23:16] == 8'hDF || a[23:20] == 4'hC;          // $DF0000, Fat Gary's $C00000 mirror
wire        sel_cia  = a[23:16] == 8'hBF;
wire        sel_cia_a = sel_cia & ~a[12];
wire        sel_cia_b = sel_cia & ~a[13];
wire        dbs = a[23:21] == 3'b000 || a[23:20] == 4'hC || a[23:16] == 8'hDF;
// the HRTmon cartridge (Minimig's cart.v): its RAM at $A00000-$A7FFFF (the
// HPS uploads hrtmon.rom to $A10000 with the CPU halted) and the custom
// register mirror at $A9F000; the local bus forwards these addresses only
// once the cartridge is out of stealth (a4k_lbus), so no stealth gate here
wire        sel_cart = !dbr && a[23:19] == 5'b10100;                  // $A00000-$A7FFFF
wire        sel_cmirror = !dbr && cpu_rd && a[23:12] == 12'hA9F;       // $A9F000-$A9FFFF
wire        ram_sel = dbr | sel_chip | sel_kick | sel_ext | sel_cart;

// Main uploads an extension ROM (or a 1 MB Kickstart's first half) to
// $E00000 with the CPU halted, after halting it for the reload: the local
// bus shows it at $F00000 too only then, so nothing stale there passes for
// a DiagROM ($1111) at reset
reg         cpuhlt_d = 1'b0;
always @(posedge clk) begin
	cpuhlt_d <= cpuhlt;
	if (cpuhlt && !cpuhlt_d)                    extrom_on <= 1'b0;
	else if (sel_ext && (cpu_hwr || cpu_lwr))   extrom_on <= 1'b1;
end
wire        freeze;                                                    // CIA-A: the HRTmon key

// video
wire        sol, sof, vbl_int;
wire        strhor_denise, strhor_paula;
wire  [8:0] htotal;
wire        harddis, varbeamen;

// floppy (CIA <-> Paula)
wire        _step, direc, _sel0, _sel1, _sel2, _sel3, side, _motor;
wire        _track0, _change, _ready, _wprot;

wire  [1:0] blver;
wire        hbl, hde;
assign      hblank = blver ? ~hde : hbl;

wire        IO_WAIT_PAULA, IO_WAIT_OSD;
wire [15:0] IO_DOUT_PAULA;
assign      IO_DOUT = IO_DOUT_PAULA;
assign      IO_WAIT = IO_WAIT_PAULA | IO_WAIT_OSD;

wire        bls;
wire        cpurst;
wire  [2:0] _iplx;
wire        usrrst;
wire        hires, shres;
wire  [7:0] memory_config;
wire  [4:0] floppy_config;
wire [11:0] floppy_ext_drive;
reg         floppy_disabled = 1'b0;
wire  [5:0] chipset_config;
wire  [5:0] ide_config;

wire        host_cs;
wire [23:0] host_adr;
wire        host_we;
wire  [1:0] host_bs;
wire [15:0] host_wdat;
wire [15:0] host_rdat;
wire        host_ack;

wire        sys_reset;

// RSTO comes from the CPU's clock domain: taken on clk first, so what it
// resets (and what that reaches, up to the SDRAM's chip port) starts at a
// chipset register
reg         cpu_rsto_n = 1'b1;
always @(posedge clk) cpu_rsto_n <= _cpu_reset_in;

wire        reset = sys_reset | ~cpu_rsto_n;

always @(posedge clk) if (clk7_en && reset) floppy_disabled <= floppy_config[4];
wire  [3:0] floppy_sel = {_sel3,_sel2,_sel1,_sel0} | {4{floppy_disabled}};

assign pwr_led    = ~_led;
assign memcfg     = {memory_config[7], memory_config[5:0]};
assign chipsetcfg = chipset_config;
assign idecfg     = ide_config;

wire [2:0] cachecfg_pre;
assign cachecfg = cachecfg_pre;

// NTSC/PAL from the OSD, taken at reset
always @(posedge clk) if (clk7_en && reset) ntsc <= chipset_config[1];

wire floppy_speed;

// the A4000 chipset: AGA (ECS registers included), no A1000 quirks
localparam AGA = 1'b1, ECS = 1'b1, A1K = 1'b0;

agnus AGNUS1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.cck(cck),
	.reset(reset),
	.aen(sel_reg),
	.rd(cpu_rd),
	.hwr(cpu_hwr),
	.lwr(cpu_lwr),
	.data_in(custom_data_in),
	.data_out(agnus_data_out),
	.address_in(cpu_address_out[8:1]),
	.address_out(dma_address_out),
	.reg_address_out(reg_address),
	.bitplane_dma(bitplane_dma),
	.bitplane_fetch_phase(bitplane_fetch_phase),
	.bitplane_fetch_phase_valid(bitplane_fetch_phase_valid),
	.bitplane_fetch_unit_start(bitplane_fetch_unit_start),
	.cpu_custom(cpu_custom),
	.dbr(dbr),
	.dbwe(dbwe),
	._hsync(_hsync),
	._vsync(_vsync),
	._csync(_csync),
	.hde(hde),
	.field1(field1),
	.lace(lace),
	.hblank(hbl),
	.vblank(vblank),
	.sol(sol),
	.sof(sof),
	.vbl_int(vbl_int),
	.strhor_denise(strhor_denise),
	.strhor_paula(strhor_paula),
	.htotal(htotal),
	.harddis(harddis),
	.varbeamen(varbeamen),
	.int3(int3),
	.audio_dmal(audio_dmal),
	.audio_dmas(audio_dmas),
	.disk_dmal(disk_dmal),
	.disk_dmas(disk_dmas),
	.bls(bls),
	.ntsc(ntsc),
	.a1k(A1K),
	.ecs(ECS),
	.aga(AGA),
	.floppy_speed(floppy_speed)
);

paula PAULA1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.clk7n_en(clk7n_en),
	.cck(cck),
	.reset(reset),
	.reg_address_in(reg_address),
	.data_in(custom_data_in),
	.data_out(paula_data_out),
	.txd(txd),
	.rxd(rxd),
	.ntsc(ntsc),
	.sof(sof),
	.strhor(strhor_paula),
	.vblint(vbl_int),
	.int2(int2 | int2_ext),
	.int3(int3),
	.int6(int6 | int6_ext),
	._ipl(_iplx),
	.audio_dmal(audio_dmal),
	.audio_dmas(audio_dmas),
	.disk_dmal(disk_dmal),
	.disk_dmas(disk_dmas),
	._step(_step),
	.direc(direc),
	._sel(floppy_sel),
	.side(side),
	._motor(_motor),
	._track0(_track0),
	._change(_change),
	._ready(_ready),
	._wprot(_wprot),
	.index(index),
	.fdd_led(fdd_led),
	.IO_ENA(IO_FPGA),
	.IO_STROBE(IO_STROBE),
	.IO_WAIT(IO_WAIT_PAULA),
	.IO_DIN(IO_DIN),
	.IO_DOUT(IO_DOUT_PAULA),
	.ldata(ldata),
	.rdata(rdata),
	.ldata_okk(ldata_okk),
	.rdata_okk(rdata_okk),

	.floppy_drives(floppy_config[3:2]),
	.floppy_zero_active(floppy_disabled),
	.floppy_ext_drive(floppy_ext_drive),
	.floppy_speed_allowed(floppy_config[0]),
	.floppy_speed(floppy_speed),

	.enable_mister_floppy(user_port_mode),
	.mister_floppy_status(mister_floppy_status),
	.drive_snd(drive_snd),

	.USER_IN(USER_IN),
	.USER_OUT(USER_OUT)
);

userio USERIO1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.reset(reset),
	.reg_address_in(reg_address),
	.data_in(custom_data_in),
	.data_out(user_data_out),
	.pot_cnt_en(sol & ~c1 & ~c3),
	._fire0(_fire0),
	._fire1(_fire1),
	._fire0_dat(_fire0_dat),
	._fire1_dat(_fire1_dat),
	._joy1(_joy1),
	._joy2(_joy2),
	.joy_ana1(joya1),
	.joy_ana2(joya2),
	.mouse_btn(mouse_btn),
	.kbd_mouse_type(kbd_mouse_type),
	.kms_level(kms_level),
	.kbd_mouse_data(kbd_mouse_data),
	.aud_mix(aud_mix),
	.IO_ENA(IO_UIO),
	.IO_STROBE(IO_STROBE),
	.IO_WAIT(IO_WAIT_OSD),
	.IO_DIN(IO_DIN),
	.memory_config(memory_config),
	.chipset_config(chipset_config),
	.floppy_config(floppy_config),
	.floppy_ext_drive(floppy_ext_drive),
	.user_port_mode(user_port_mode),
	.scanline(scanline),
	.ar(ar),
	.blver(blver),
	.ide_config(ide_config),
	.cpu_config(cpucfg),
	.cache_config(cachecfg_pre),
	.usrrst(usrrst),
	.cpurst(cpurst),
	.cpuhlt(cpuhlt),
	.bootrom(),
	.host_cs(host_cs),
	.host_adr(host_adr),
	.host_we(host_we),
	.host_bs(host_bs),
	.host_wdat(host_wdat),
	.host_rdat(host_rdat),
	.host_ack(host_ack)
);

assign ce_pix = shres | (hires & clk7n_en) | clk7_en;
assign res    = {shres, hires};

denise DENISE1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.c1(c1),
	.c3(c3),
	.cck(cck),
	.reset(reset),
	.strhor(strhor_denise),
	.bitplane_dma(bitplane_dma),
	.bitplane_fetch_phase(bitplane_fetch_phase),
	.bitplane_fetch_phase_valid(bitplane_fetch_phase_valid),
	.bitplane_fetch_unit_start(bitplane_fetch_unit_start),
	.reg_address_in(reg_address),
	.data_in(custom_data_in),
	.chip48(chip48),
	.data_out(denise_data_out),
	.blank(~_hsync|vblank),
	.red(red),
	.green(green),
	.blue(blue),
	.a1k(A1K),
	.ecs(ECS),
	.aga(AGA),
	.hires(hires),
	.shres(shres)
);

// CIA A
wire [3:0] porta_out;
assign {_fire1_dat,_fire0_dat,_led} = porta_out[3:1];

ciaa CIAA1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.clk7n_en(clk7n_en),
	.aen(sel_cia_a),
	.rd(cpu_rd),
	.wr(cpu_lwr|cpu_hwr),
	.reset(reset),
	.rs(cpu_address_out[11:8]),
	.data_in(cpu_data_out[7:0]),
	.data_out(cia_data_out[7:0]),
	.tick(_vsync),
	.eclk(eclk[8]),
	.cnt_in(1'b1),
	.irq(int2),
	.porta_in({_fire1,_fire0,_ready,_track0,_wprot,_change}),
	.porta_out(porta_out),
	.portb_in({_joy4[0],_joy4[1],_joy4[2],_joy4[3],_joy3[0],_joy3[1],_joy3[2],_joy3[3]}),
	.kbd_mouse_type(kbd_mouse_type),
	.kms_level(kms_level),
	.kbd_mouse_data(kbd_mouse_data),
	.freeze(freeze),
	.hrtmon_en(memory_config[6])
);

// CIA B
ciab CIAB1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.aen(sel_cia_b),
	.rd(cpu_rd),
	.wr(cpu_hwr|cpu_lwr),
	.reset(reset),
	.rs(cpu_address_out[11:8]),
	.data_in(cpu_data_out[15:8]),
	.data_out(cia_data_out[15:8]),
	.tick(_hsync),
	.eclk(eclk[8]),
	.cnt_in(1'b1),
	.irq(int6),
	.flag(index),
	.porta_in({cd,cts,dsr,ri&_joy3[4],1'b1,_joy4[4]}),
	.porta_out({dtr,rts}),
	.portb_out({_motor,_sel3,_sel2,_sel1,_sel0,side,direc,_step})
);

// 32-bit chip RAM cycles: the AGA CPU path, while the HPS is not writing
wire cpu_long_en;
assign chip32_en = ~cpuhlt;
assign ram_long  = cpu_long_en & ~dbr & sel_chip;

minimig_m68k_bridge CPU1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.clk7n_en(clk7n_en),
	.c1(c1),
	.c3(c3),
	.cck(cck),
	.eclk(eclk),
	.vpa(sel_cia),
	.dbr(dbr),
	.dbs(dbs),
	.xbs(1'b1),
	.nrdy(1'b0),
	.bls(bls),
	.memory_config(4'b0011),
	._as(_cpu_as),
	._lds(_cpu_lds),
	._uds(_cpu_uds),
	.r_w(cpu_r_w),
	.cpu_long(cpu_long),
	.long_en(cpu_long_en),
	._dtack(_cpu_dtack),
	.rd(cpu_rd),
	.rd_cyc(rd_cyc),
	.hwr(cpu_hwr),
	.lwr(cpu_lwr),
	.address(cpu_address),
	.address_out(cpu_address_out),
	.cpudatain(cpudata_in),
	.data(cpu_data),
	.data_out(cpu_data_out),
	.data_in(cpu_data_in),
	._cpu_reset (_cpu_reset),
	.cpu_halt (cpuhlt),
	.host_cs (host_cs),
	.host_adr (host_adr[23:1]),
	.host_we (host_we),
	.host_bs (host_bs),
	.host_wdat (host_wdat),
	.host_rdat (host_rdat),
	.host_ack (host_ack)
);

// the cartridge's NMI: the freeze key (CIA-A, HRTmon enabled) raises level
// 7 until the card acknowledges it
reg         freeze_d = 1'b0, int7 = 1'b0;
reg   [2:0] iack7_s = 3'd0;
always @(posedge clk) begin
	iack7_s <= {iack7_s[1:0], iack7_t};
	if (clk7_en) freeze_d <= freeze;
	if (reset)                          int7 <= 1'b0;
	else if (clk7_en && freeze && !freeze_d) int7 <= 1'b1;
	else if (iack7_s[2] != iack7_s[1])  int7 <= 1'b0;
end

// the custom registers as last written, for HRTmon to read at $A9F000
reg  [15:0] cmirror [0:255];
reg  [15:0] cmirror_q;
always @(posedge clk) begin
	if (clk7_en) cmirror[reg_address] <= custom_data_in;
	cmirror_q <= cmirror[a[8:1]];
end

assign _cpu_ipl = int7 ? 3'b000 : _iplx;

//--------------------------------------------------------------------------
// the chip-bus decode (Gary's part of it on this side): chip RAM for DMA
// and the CPU, the custom registers, the CIAs; with the CPU halted, the
// HPS's writes of the ROM image
//--------------------------------------------------------------------------


// bus multiplexers (gary.v)
assign ram_data_in    = dbr ? custom_data_out : cpu_data_out;
assign custom_data_in = dbr ? ram_data_out : cpu_rd ? 16'hFFFF : cpu_data_out;
assign gary_data_out  = dbr ? 16'h0000 : custom_data_out | ram_data_out | (sel_cmirror ? cmirror_q : 16'h0000);
assign ram_rd         = dbr ? ~dbwe : cpu_rd;
assign ram_hwr        = dbr ?  dbwe : cpu_hwr;
assign ram_lwr        = dbr ?  dbwe : cpu_lwr;

// the SDRAM word address: chip RAM at 0, the ROM at 0x780000
assign ram_address = dbr      ? {4'b0000, dma_address_out[20:1]} :
                     sel_kick ? {6'b001111, a[18:1]} :
                     sel_ext  ? {6'b001110, a[18:1]} :
                     sel_cart ? {6'b001101, a[18:1]} :
                                {4'b0000, a[20:1]};

// the sram bridge's strobes (minimig_sram_bridge)
assign _ram_we     = (!ram_hwr && !ram_lwr) | !ram_sel;
assign _ram_oe     = !ram_rd | !ram_sel;
assign _ram_bhe    = !ram_hwr | !ram_sel;
assign _ram_ble    = !ram_lwr | !ram_sel;
assign ram_data    = ram_data_in;
assign ram_data_out = (ram_sel && ram_rd) ? ramdata_in : 16'h0000;

assign cpu_data_in = gary_data_out | cia_data_out;

assign custom_data_out = agnus_data_out | paula_data_out | denise_data_out | user_data_out;

minimig_syscontrol CONTROL1
(
	.clk(clk),
	.clk7_en(clk7_en),
	.cnt(sof),
	.mrst(usrrst | rst_ext),
	.reset(sys_reset)
);

// kickstart overlay (CIA-A PA0): set by any reset, cleared by a CIA-A write
always @(posedge clk) begin
	if(~_cpu_reset | ~cpu_rsto_n)          ovl <= 1;
	else if(sel_cia_a & (cpu_lwr|cpu_hwr)) ovl <= 0;
end

assign _cpu_reset = _rst;

reg _rst;
always @(posedge clk) begin
	reg r;
	r <= ~(cpurst || sys_reset);
	_rst <= r;
end

assign rst_out = reset;

endmodule
