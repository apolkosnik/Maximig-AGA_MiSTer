//============================================================================
//  a4k_lbus: the A4000 motherboard's local bus
//
//  Takes one beat at a time from the CPU card (a4k_a3640) and answers it
//  the way the motherboard's bus controllers do:
//
//  * Gary's address decode, cache inhibit and bus timeout (FAT GARY
//    specification 390540: DSACK timeout after 32 C1 periods, ~9 us, by
//    default; BERR after ~250 ms once $DE0000 bit 7 is set; no timeout at
//    all once $DE0001 bit 7 is set; never on chip RAM or chip registers).
//  * Gary's and Ramsey's registers in the $DE0000 page, decoded as
//    WinUAE's mbres_read/mbres_write (lane A1:A0 and A7:A6 only, mirrored
//    every $100 below $DE8000).
//  * Ramsey's DRAM timing (RAMSEY specification 390541, 25 MHz): 5 clocks
//    per access, 4 with Skip, page mode 3 on a hit / 7 on a miss, refresh
//    every 154/238/380 clocks closing the page; its control register takes
//    effect at the next refresh.  The banks fill from the top of
//    $07000000-$07FFFFFF; Ramsey decodes the whole window, an unfitted bank
//    reads all ones.
//  * Buster's Zorro configuration spaces and boards (a4k_buster), the RTG
//    board's registers (rtg.v) at board+$800000.
//  * Gary's ROM timing (5-8 clocks, the ROM jumpers).
//
//  A beat's data comes from one of three ports -- SDRAM (ROM, motherboard
//  RAM), DDR3 (Zorro III RAM, the RTG framebuffer, the HPS share window)
//  or the 28 MHz slow bus (a4k_budgie: chip RAM, custom registers, CIAs,
//  RTC, IDE, Zorro II boards) -- or from here.  In A4000 bus timing a beat
//  is answered no sooner than its region's cycle time, counted in CPU
//  clocks as the motherboard counts CPUCLK; in fast timing as soon as the
//  data is there.
//
//  Every port is a toggle handshake: a request toggles req with its
//  fields stable, the port toggles ack when done (read data stable until
//  the next request).  Reads of the SDRAM come back as a quad word, of the
//  DDR3 as a 16-byte line; the last one is kept (only for the beats of the
//  line transfer in progress, and dropped on any write to it).
//
//  Data is big-endian throughout: D31-D24 is the byte at offset 0.
//============================================================================

module a4k_lbus
#(
	parameter int TOUT_DSACK = 511,           // 32 C1 periods, ~9 us, in clk cycles
	parameter int TOUT_BERR  = 14_187_500     // ~250 ms in clk cycles
)
(
	input             clk,
	input             ce,            // a CPU clock edge: the clock Ramsey/Gary count
	input             reset,         // system reset
	input             io_reset,      // the system reset or the RESET instruction (Gary's timeout bits)
	input             pwrup,         // power-up reset: sets COLDBOOT

	// configuration (stable while the system runs)
	input             fast,          // 1: no wait states
	input       [1:0] mbram,         // motherboard RAM: 0 none, 1 4 MB, 2 8 MB, 3 16 MB
	input             z3ram256_fit,
	input             z3ram128_fit,
	input             rtg_fit,
	input             a2065_fit,
	input             toccata_fit,
	input       [1:0] rom_speed,     // ROM jumpers: 5, 6, 7, 8 CPU clocks
	input             ovl,           // CIA-A OVL: ROM at $000000 for reads
	input             extrom_on,     // an extension ROM is loaded: shown at $F00000 too
	input             iack7_t,       // the card: toggles at a level-7 interrupt acknowledge
	input             cart_ar,       // the cartridge is the Action Replay (DeMoN v2), not HRTmon
	input             freeze_t,      // the chipset: toggles at the freeze key (cartridge enabled)
	output reg        nmi_t = 1'b0,  // to the chipset: toggles to raise the cartridge's NMI
	input      [31:0] dbg_pc,        // the CPU's PC, for the PC sampler
	input             rtr_frz,       // the retired-PC ring has frozen (CPU clock)
	input       [7:0] rtr_wp,        // ... its next slot: the oldest entry
	input       [7:0] rtr_xvec,      // ... the last exception's vector and
	input      [31:0] rtr_xpc,       // ... stacked PC
	output reg  [7:0] rtr_ra,        // ... read address
	input      [31:0] rtr_rd,        // ... its entry (registered)

	// the card
	input             lb_req,
	output reg        lb_ack,
	input      [31:2] lb_addr,
	input       [3:0] lb_be,
	input             lb_we,
	input      [31:0] lb_wdata,
	input             lb_line,
	input       [1:0] lb_beat,
	input       [1:0] lb_tt,
	input       [2:0] lb_tm,
	output reg [31:0] lb_rdata,
	output reg        lb_berr,
	output reg        lb_ci,

	// SDRAM: ROM and motherboard RAM
	output reg        sd_req,
	input             sd_ack,
	output reg [24:2] sd_addr,       // byte address in the SDRAM, long-word aligned
	output reg        sd_we,
	output reg  [3:0] sd_be,
	output reg [31:0] sd_wdata,
	input      [63:0] sd_rdata,      // the quad word at sd_addr[24:3]

	// DDR3: Zorro III RAM, RTG framebuffer, the HPS share window
	output reg        dd_req,
	input             dd_ack,
	output reg [28:2] dd_addr,       // byte offset from 0x20000000
	output reg        dd_we,
	output reg  [3:0] dd_be,
	output reg [31:0] dd_wdata,
	input     [127:0] dd_rdata,      // the line at dd_addr[28:4]

	// the 28 MHz slow bus
	output reg        sb_req,
	input             sb_ack,
	output reg  [2:0] sb_tgt,
	output reg [23:2] sb_addr,
	output reg        sb_we,
	output reg  [3:0] sb_be,
	output reg [31:0] sb_wdata,
	input      [31:0] sb_rdata,

	// Zorro II board bases for the slow bus
	output            a2065_ena,
	output      [7:0] a2065_base,
	output            toccata_ena,
	output      [7:0] toccata_base,

	// RTG framebuffer control (rtg.v)
	output            rtg_ena,
	output     [11:0] rtg_hsize,
	output     [11:0] rtg_vsize,
	output      [4:0] rtg_format,
	output     [31:0] rtg_base,
	output     [13:0] rtg_stride,
	output            rtg_pal_clk,
	output     [23:0] rtg_pal_dw,
	input      [23:0] rtg_pal_dr,
	output      [7:0] rtg_pal_a,
	output            rtg_pal_wr,

	// observation
	output reg        gary_ien,      // Gary's interrupt master ($DF809A bit 15): 0 masks every CPU interrupt
	output reg  [4:0] dbg_tgt,
	output            dbg_coldboot,
	output      [7:0] dbg_ramsey
);

//----------------------------------------------------------------------------
// targets
//----------------------------------------------------------------------------
localparam [4:0]
	T_NONE   = 5'd0,   // nothing answers: Gary's timeout
	T_CHIP   = 5'd1,   // slow bus: chip RAM
	T_CREG   = 5'd2,   // slow bus: custom registers
	T_CIA    = 5'd3,   // slow bus: the 8520s
	T_RTC    = 5'd4,   // slow bus: RP5C01
	T_IDE    = 5'd5,   // slow bus: A4000 IDE
	T_A2065  = 5'd6,   // slow bus: Zorro II A2065
	T_TOCC   = 5'd7,   // slow bus: Zorro II Toccata
	T_ROM    = 5'd8,   // SDRAM: Kickstart
	T_MBRAM  = 5'd9,   // SDRAM: Ramsey, a fitted bank
	T_MBNONE = 5'd10,  // Ramsey, an empty bank
	T_MBRES  = 5'd11,  // Gary/Ramsey registers
	T_ACZ2   = 5'd12,  // autoconfig at $E80000
	T_ACZ3   = 5'd13,  // autoconfig at $FF000000
	T_Z3R256 = 5'd14,  // DDR3: 256 MB Zorro III RAM
	T_Z3R128 = 5'd15,  // DDR3: 128 MB Zorro III RAM
	T_RTGFB  = 5'd16,  // DDR3: RTG framebuffer
	T_RTGREG = 5'd17,  // RTG registers and CLUT
	T_SHARE  = 5'd18,  // DDR3: HPS share window ($DD4000-$DD5FFF)
	T_CPUSP  = 5'd19,  // CPU space (MOVES with FC 7): bus error
	T_FLOAT  = 5'd20,  // nothing answers where Gary does not time out: floats
	T_NMIV   = 5'd21,  // the HRTmon cartridge's NMI vector
	T_CART   = 5'd22,  // SDRAM: the HRTmon cartridge's RAM
	T_GIEN   = 5'd23,  // Gary's interrupt enable ($DF8000-$DFBFFF)
	T_AR     = 5'd24;  // SDRAM: the Action Replay's ROM and RAM

// slow bus target numbers (a4k_budgie)
localparam [2:0] SB_CHIP = 3'd0, SB_CREG = 3'd1, SB_CIA = 3'd2, SB_RTC = 3'd3,
                 SB_IDE = 3'd4, SB_A2065 = 3'd5, SB_TOCC = 3'd6;

wire        z3ram256_ena, z3ram128_ena, rtgb_ena;
wire  [3:0] z3ram256_base;
wire  [4:0] z3ram128_base;
wire  [7:0] rtgb_base;

// fitted Ramsey banks: 4 MB each, filled from $07C00000 downwards
function automatic bank_fitted(input [1:0] cfg, input [1:0] bank);
	case (cfg)
		2'd1:    bank_fitted = (bank == 2'd3);
		2'd2:    bank_fitted = bank[1];
		2'd3:    bank_fitted = 1'b1;
		default: bank_fitted = 1'b0;
	endcase
endfunction

// the HRTmon cartridge (Minimig's cart.v, its CPU side): the level-7
// interrupt acknowledge (the freeze key's NMI) takes the cartridge out of
// stealth -- its RAM and custom register mirror at $A00000-$AFFFFF answer
// on the chip bus from then on -- and arms the NMI vector: the CPU's next
// supervisor data read (TT 0, TM 5) is the vector fetch, and it returns
// $00A1000C, HRTmon's entry.  Not matched by address: the bus carries the
// physical address, which under the MMU need not be VBR + $7C; between the
// acknowledge and the vector the 040 only writes its frame (table walks are
// TM 3/4, instruction fetches TM 6), and AP68040 takes the level-7 vector
// fetch past its data cache, so it always reaches the bus.
reg        cart_on = 1'b0;
reg        nmi_arm = 1'b0;

// the Action Replay (AR5's DeMoN v2 build, cart_ar): ROM at $A80000-$ABFFFF,
// RAM at $AC0000-$AFFFFF, both in the SDRAM at 0x600000 (the HPS uploads
// AR5.ROM there with the CPU halted).  The cartridge is hidden until it
// freezes the machine, as WinUAE's AR2/AR3 (ar.cpp) and AR5 expect:
// * the freeze key; with mode bit 1 a read of CIA-A PRA ($BFE001), with
//   mode bit 0 a write of CIA-B PRB ($BFD100) -- only while hidden;
// * a system reset: the first CPU write of a word or long word to chip RAM
//   after it (Kickstart's first), cause 3.
// A freeze shows the cartridge and raises level 7; the NMI vector is the
// ROM's ($A8007C), served for the vector fetch as HRTmon's.  The ROM's first
// long word is the control register: a write of the byte at +1 sets the
// mode and clears the cause, and the cartridge hides at the first
// instruction fetched from outside it (WinUAE: once the PC leaves the ROM
// and RAM); a read of the byte at +1 or +3 has the cause in D1-D0 (0 the
// key, 1 PRA read, 2 PRB write, 3 reset).  The custom registers as they
// were at the freeze are at $ACF000-$ACF1FF (the chipset's snapshot, read
// and written as RAM there).  Other ROM writes are ignored.
reg        ar_vis = 1'b0;      // shown: from the freeze until it hides
reg        ar_hide = 1'b0;     // the control register written: hide at the next fetch from outside
reg        ar_rst = 1'b0;      // a system reset: freeze at the first chip RAM write
reg  [1:0] ar_mode = 2'b00;    // bit 1: freeze at a PRA read, bit 0: at a PRB write
reg  [1:0] ar_cause = 2'b00;
reg        ar_vec = 1'b0;      // the beat is the NMI vector fetch, from the ROM
reg        ar_crd = 1'b0;      // the beat reads the control register

reg [4:0] dec;
always @(*) begin
	logic [31:0] a;
	a = {lb_addr, 2'b00};
	dec = T_NONE;
	if (lb_tt == 2'b10 && lb_tm == 3'd7) dec = T_CPUSP;
	else if (a[31:24] == 8'h00) begin
		// Gary's timeout covers the unanswered addresses from $B80000 up,
		// but not $E80000-$F7FFFF; below $B80000 (the Zorro II memory and
		// I/O spaces) an unanswered cycle floats too (WinUAE gary_nonrange)
		casez (a[23:16])
			// with OVL the ROM, not chip RAM, is selected at $000000-$07FFFF, for
			// writes too (it ignores them: Gary)
			8'b000?_????: dec = (ovl && a[23:19] == 5'd0) ? T_ROM : T_CHIP;             // $000000-$1FFFFF
			// the CIAs only at $BFD000-$BFDFFF and $BFE000-$BFEFFF, never both,
			// no mirrors (Gary; WinUAE: Fat Gary's CIA mapping)
			8'hBF:        dec = (a[15:12] == 4'hD || a[15:12] == 4'hE) ? T_CIA : T_NONE;
			// the cartridge: its RAM ($A00000-$A7FFFF) straight from SDRAM, where
			// it lives, so HRTmon runs at the CPU's speed; the custom register
			// mirror ($A9F000) on the chip bus
			8'hA?:        dec = cart_ar ? ((ar_vis && a[23:19] == 5'b10101) ? ((a[23:9] == 15'h5678) ? T_CREG : T_AR) : T_FLOAT) :
			                    !cart_on ? T_FLOAT : (a[23:19] == 5'b10100) ? T_CART : T_CREG;
			8'hC?:        dec = T_CREG;                                              // Fat Gary's mirror
			8'hDC:        dec = T_RTC;
			8'hDD:        dec = (a[15:13] == 3'b001) ? T_IDE : (a[15:13] == 3'b010) ? T_SHARE : T_NONE;
			8'hDE:        dec = a[15] ? T_NONE : T_MBRES;
			// the chip registers at $DFC000-$DFFFFF (4 KB, four times), Gary's
			// interrupt enable at $DF8000-$DFBFFF; $DF0000-$DF7FFF is nothing
			8'hDF:        dec = !a[15] ? T_NONE : a[14] ? T_CREG : T_GIEN;
			8'hE8:        dec = T_ACZ2;
			8'b1111_1???: dec = T_ROM;                                               // $F80000-$FFFFFF
			8'b1110_0???: dec = extrom_on ? T_ROM : T_NONE;                         // $E00000-$E7FFFF: a 1 MB ROM's other half
			8'b1111_0???: dec = extrom_on ? T_ROM : T_FLOAT;                         // $F00000-$F7FFFF: the extension ROM again (a DiagROM, residents)
			default:      dec = (a[23:16] < 8'hB8 || (a[23:16] >= 8'hE8 && a[23:16] < 8'hF8)) ? T_FLOAT : T_NONE;
		endcase
		if (a2065_ena && a[23:16] == a2065_base)     dec = T_A2065;
		if (toccata_ena && a[23:16] == toccata_base) dec = T_TOCC;
	end
	else if (a[31:24] == 8'h07) dec = bank_fitted(mbram, a[23:22]) ? T_MBRAM : T_MBNONE;
	else if (a[31:24] == 8'hFF) dec = T_ACZ3;
	else begin
		if (z3ram256_ena && a[31:28] == z3ram256_base) dec = T_Z3R256;
		if (z3ram128_ena && a[31:27] == z3ram128_base) dec = T_Z3R128;
		if (rtgb_ena && a[31:24] == rtgb_base)
			dec = !a[23] ? T_RTGFB : (a[22:16] == 7'd0) ? T_RTGREG : T_NONE;
	end
	if (nmi_arm && !lb_we && lb_tt == 2'b00 && lb_tm == 3'd5) dec = T_NMIV;
end

// cache inhibit (Gary's and the Zorro III boards' CIIN/CINH): everything
// but memory; the RTG board is inhibited as a whole, the ARM writes its
// framebuffer and mailbox behind the 68040's back
function automatic inhibited(input [4:0] t);
	case (t)
		T_CHIP, T_ROM, T_MBRAM, T_MBNONE, T_Z3R256, T_Z3R128: inhibited = 1'b0;
		default:                                               inhibited = 1'b1;
	endcase
endfunction

//----------------------------------------------------------------------------
// Gary's and Ramsey's registers
//----------------------------------------------------------------------------
reg        gary_timeout;    // $DE0000 bit 7 written: 0 DSACK timeout, 1 BERR timeout
reg        gary_timedout;   // $DE0000 bit 7 read: a bus timed out (cleared by the read)
reg        gary_toenb;      // $DE0001 bit 7: 1 timeout disabled
reg        gary_coldboot;   // $DE0002 bit 7: power-up detect
reg  [7:0] ramsey_cfg;      // in effect
reg  [7:0] ramsey_wr;       // written, in effect from the next refresh
reg        ramsey_wr_pend;

assign dbg_coldboot = gary_coldboot;
assign dbg_ramsey   = ramsey_cfg;

// Ramsey's power-up values: page/burst/wrap off, 1M x 4 DRAMs (RSIZE high),
// RAM width bit (-04) / skip off (-07): 0, refresh 238 clocks (RSPEED high)
localparam [7:0] RAMSEY_PWRUP = 8'b0010_1000;

// the mbres byte at lane l of offset off (WinUAE mbres_read)
function automatic [7:0] mbres_byte(input [15:0] off, input [1:0] l);
	logic [15:0] x;
	x = {off[15:2], l};
	case (x[1:0])
		2'd3:    mbres_byte = (x[7:6] == 2'd1) ? 8'h0F :           // Ramsey-07 version
		                      (x[7:6] == 2'd0) ? ramsey_cfg : 8'hFF;
		2'd2:    mbres_byte = {gary_coldboot, 7'h7F};
		2'd1:    mbres_byte = {gary_toenb,    7'h7F};
		default: mbres_byte = {gary_timedout, 7'h7F};
	endcase
endfunction

wire [15:0] lb_off = {lb_addr[15:2], 2'b00};
wire [31:0] mbres_rd = {mbres_byte(lb_off, 2'd0), mbres_byte(lb_off, 2'd1), mbres_byte(lb_off, 2'd2), mbres_byte(lb_off, 2'd3)};

//----------------------------------------------------------------------------
// Ramsey's refresh: counted in CPU clocks; a refresh takes 4 clocks,
// closes the open page and brings a written control value into effect
//----------------------------------------------------------------------------
reg  [8:0] rf_cnt;
reg  [2:0] rf_busy;           // clocks of refresh still to run
reg        page_open;
reg [31:11] page_row;
wire [8:0] rf_ival = (ramsey_cfg[6:5] == 2'd0) ? 9'd154 :
                     (ramsey_cfg[6:5] == 2'd1) ? 9'd238 : 9'd380;

//----------------------------------------------------------------------------
// RTG registers and CLUT (rtg.v, 16-bit registers at board+$800000)
//----------------------------------------------------------------------------
reg        rtg_cs, rtg_rd, rtg_wr;
reg [11:1] rtg_rs;
reg [15:0] rtg_din;
reg  [1:0] rtg_be;
wire [15:0] rtg_dout;
wire        rtg_ready;

rtg rtgregs
(
	.clk(clk),
	.reset(reset),
	.aen(rtg_cs),
	.rd(rtg_rd),
	.wr(rtg_wr),
	.rs(rtg_rs),
	.ready(rtg_ready),
	.data_in(rtg_din),
	.be(rtg_be),
	.data_out(rtg_dout),
	.ena(rtg_ena),
	.hsize(rtg_hsize),
	.vsize(rtg_vsize),
	.format(rtg_format),
	.base(rtg_base),
	.stride(rtg_stride),
	.pal_clk(rtg_pal_clk),
	.pal_dw(rtg_pal_dw),
	.pal_dr(rtg_pal_dr),
	.pal_a(rtg_pal_a),
	.pal_wr(rtg_pal_wr)
);

//----------------------------------------------------------------------------
// autoconfig
//----------------------------------------------------------------------------
reg        ac_wr;
wire [31:0] ac_rdata;

a4k_buster buster
(
	.clk(clk),
	.reset(reset),
	.z3ram256_fit(z3ram256_fit),
	.z3ram128_fit(z3ram128_fit),
	.rtg_fit(rtg_fit),
	.a2065_fit(a2065_fit),
	.toccata_fit(toccata_fit),
	.z3space(dec == T_ACZ3),
	.addr(lb_addr[15:2]),
	.wr(ac_wr),
	.be(lb_be),
	.wdata(lb_wdata),
	.rdata(ac_rdata),
	.z3ram256_ena(z3ram256_ena),
	.z3ram256_base(z3ram256_base),
	.z3ram128_ena(z3ram128_ena),
	.z3ram128_base(z3ram128_base),
	.rtg_ena(rtgb_ena),
	.rtg_base(rtgb_base),
	.a2065_ena(a2065_ena),
	.a2065_base(a2065_base),
	.toccata_ena(toccata_ena),
	.toccata_base(toccata_base)
);

//----------------------------------------------------------------------------
// region cycle times in CPU clocks (A4000 timing), from the start of the
// beat on the motherboard to its termination
//----------------------------------------------------------------------------
localparam [5:0] CYC_Z3RAM = 6'd10;   // Buster's Zorro III cycle on a memory board (the ZZ9000's, measured on an A3640)
localparam [5:0] CYC_RTG   = 6'd11;   // Zorro III cycle on the graphics board (ZZ9000-class)
localparam [5:0] CYC_REG   = 6'd4;    // Gary/Ramsey registers
localparam [5:0] CYC_AC    = 6'd14;   // a configuration-space Zorro II cycle

//----------------------------------------------------------------------------
// the beat
//----------------------------------------------------------------------------
localparam [3:0] S_IDLE = 4'd0, S_PORT = 4'd1, S_RTG = 4'd2, S_RTG2 = 4'd3, S_WAIT = 4'd4, S_TOUT = 4'd5, S_DONE = 4'd6,
                 S_SDQ = 4'd7, S_SDR = 4'd8, S_DDQ = 4'd9, S_DDR = 4'd10, S_PCN = 4'd11,
                 S_PCE = 4'd12;
reg  [3:0] st;
reg  [5:0] need;        // CPU clocks the beat must take
reg  [5:0] elapsed;     // CPU clocks since the beat started
reg [23:0] tout;
reg [31:0] rdata;
reg        berr;
reg        rfirst;      // the first rtg cycle (high word) of a long word

// the line being transferred: its quad words read from the SDRAM, or the
// whole line read from the DDR3
reg  [1:0] sdb_v;
reg [24:4] sdb_a;
reg [63:0] sdb_d [2];
reg        ddb_v;
reg [28:4] ddb_a;
reg[127:0] ddb_d;

wire [24:2] sd_byte = (dec == T_ROM)  ? {5'b00111, lb_addr[23:19] != 5'b11100 && lb_addr[23:19] != 5'b11110, lb_addr[18:2]}  // 0x780000 (0x700000: $E00000, $F00000) + offset
                   : (dec == T_CART) ? {6'b001101, lb_addr[18:2]}                // 0x680000 + offset
                   : (dec == T_AR)   ? {6'b001100, lb_addr[18:2]}                // 0x600000 + offset
                   : ar_vec          ? {6'b001100, 17'h0001F}                    // 0x60007C: the AR's NMI vector
                                     : {1'b1, lb_addr[23:2]};                   // 0x1000000 + offset
reg  [28:2] dd_byte;
always @(*) begin
	case (dec)
		T_Z3R256: dd_byte = {1'b1, lb_addr[27:2]};                              // 0x30000000 + offset
		T_Z3R128: dd_byte = {2'b01, lb_addr[26:2]};                             // 0x28000000 + offset
		T_SHARE:  dd_byte = {13'h07FF, lb_addr[15:2]};                          // 0x27FF0000 + offset
		default:  dd_byte = {6'b001110, lb_addr[22:2]};                         // 0x27000000 + offset
	endcase
end

wire beat_new = (lb_req != lb_ack) && st == S_IDLE;

// The PC sampler, a debug aid on real hardware: every 2^12 clk_57 cycles
// (72 us) the CPU's PC goes to a ring of 64 long words in DDR3 at
// 0x27FF6000, written when the bus is idle; at 0x27FF6100 the sample count,
// at +$104 the level-7 acknowledges and the NMI vectors served (one byte
// each).  48 samples after an NMI vector the ring stops, so it holds the
// cartridge's entry; the live PC then goes to +$108 (from the ARM: devmem 0x27FF6000 32 ...; each long word reads byte
// reversed, as all Amiga data in DDR3 does).  Only in a debug build (the
// macro MAXIMIG_PCSAMPLE, e.g. set_global_assignment -name VERILOG_MACRO
// "MAXIMIG_PCSAMPLE=1"): its DDR3 writes take the bus between the CPU's
// beats, and a CPU beat drops its count writes rather than wait behind DDR3.
`ifdef MAXIMIG_PCSAMPLE
localparam PCS_EN = 1'b1;
`else
localparam PCS_EN = 1'b0;
`endif
// the retired-PC ring (a4k_machine), once frozen: its 256 entries to
// 0x27FF6400 in slot order, then at 0x27FF610C {8'h5A, next slot}, at
// 0x27FF6110 the last exception's vector and at 0x27FF6114 its stacked PC
reg  [1:0] rtr_fs = 2'b00;
reg  [9:0] rtr_i = 10'd0;    // entries written; 256-258: the header words
reg        rtr_hdr = 1'b0;   // the header written
reg  [7:0] rtr_ra_d = 8'd0;
always @(posedge clk) begin
	rtr_fs   <= {rtr_fs[0], rtr_frz};
	rtr_ra   <= rtr_i[7:0];
	rtr_ra_d <= rtr_ra;
end
// rtr_rd is entry rtr_i: its address has been there a clock (the RAM's
// registered read)
wire       rtr_rdy = rtr_ra == rtr_i[7:0] && rtr_ra_d == rtr_i[7:0];
wire       rtr_go = PCS_EN && rtr_fs[1] && !rtr_hdr;

// the last 256 beats on this bus, frozen with the retired-PC ring and
// written to 0x27FF7000 after it, oldest first, 16 bytes each: the
// address, the data (written, or read), {target[4:0], BERR, write,
// byte enables[3:0], TT[1:0], TM[2:0], line, beat[1:0], 13'd0}, and
// {8'hB5, next slot} (the bus side of a runaway: a vector fetch's address
// and what it read, the writes before it)
`ifdef MAXIMIG_PCSAMPLE
reg [31:0] bus_a [256];
reg [31:0] bus_d [256];
reg [31:0] bus_f [256];
reg  [7:0] bus_wp = 8'd0;
reg [31:0] bus_qa, bus_qd, bus_qf;
reg  [9:0] bus_i = 10'd0;    // words written: entry bus_i[9:2], word bus_i[1:0]
reg        bus_done = 1'b0;
reg  [7:0] bus_ra = 8'd0, bus_ra_d = 8'd0;
always @(posedge clk) begin
	if (st == S_DONE && !rtr_fs[1]) begin
		bus_a[bus_wp] <= {lb_addr, 2'b00};
		bus_d[bus_wp] <= lb_we ? lb_wdata : rdata;
		bus_f[bus_wp] <= {dec, berr, lb_we, lb_be, lb_tt, lb_tm, lb_line, lb_beat, 13'd0};
		bus_wp <= bus_wp + 1'd1;
	end
	bus_ra   <= bus_wp + bus_i[9:2];
	bus_ra_d <= bus_ra;
	bus_qa   <= bus_a[bus_ra];
	bus_qd   <= bus_d[bus_ra];
	bus_qf   <= bus_f[bus_ra];
end
wire       bus_rdy = bus_ra == bus_wp + bus_i[9:2] && bus_ra_d == bus_ra;
wire       bus_go  = rtr_hdr && !bus_done;
wire [31:0] bus_q  = (bus_i[1:0] == 2'd0) ? bus_qa : (bus_i[1:0] == 2'd1) ? bus_qd :
                     (bus_i[1:0] == 2'd2) ? bus_qf : {16'h0000, 8'hB5, bus_wp};
`else
wire       bus_rdy = 1'b0, bus_go = 1'b0;
wire [31:0] bus_q  = 32'd0;
reg  [9:0] bus_i = 10'd0;
reg        bus_done = 1'b0;
`endif
reg [11:0] pcs_tmr = 12'd0;
reg        pcs_t = 1'b0, pcs_d = 1'b0;
reg [25:0] pcs_n = 26'd0;
reg  [7:0] pcs_ack = 8'd0, pcs_nmi = 8'd0;
reg  [5:0] pcs_left = 6'd0;
reg        pcs_stop = 1'b0, pcs_arm = 1'b0;
always @(posedge clk) begin
	pcs_tmr <= pcs_tmr + 1'd1;
	if (pcs_tmr == 12'hFFF) pcs_t <= ~pcs_t;
end

reg iack7_d = 1'b0;
reg [2:0] freeze_s = 3'd0;
wire      ar_idle = cart_ar && !ar_vis && !ar_rst;
wire      ar_cia  = beat_new && dec == T_CIA && lb_addr[11:8] == 4'd0 && lb_addr[15:12] == 4'hE && !lb_we &&
                    (lb_be[2] || lb_be[0]) && ar_mode[1];                                  // $BFE001 read
wire      ar_cib  = beat_new && dec == T_CIA && lb_addr[11:8] == 4'd1 && lb_addr[15:12] == 4'hD && lb_we &&
                    (lb_be[3] || lb_be[1]) && ar_mode[0];                                  // $BFD100 write
wire      ar_chw  = beat_new && dec == T_CHIP && lb_we && lb_be != 4'b1000 && lb_be != 4'b0100 &&
                    lb_be != 4'b0010 && lb_be != 4'b0001;                                  // a word or long word to chip RAM
wire      ar_ctl  = beat_new && dec == T_AR && lb_addr[18:2] == 17'd0;                     // the control register
always @(posedge clk) begin
	iack7_d  <= iack7_t;
	freeze_s <= {freeze_s[1:0], freeze_t};
	if (reset) begin
		cart_on <= 1'b0;
		nmi_arm <= 1'b0;
	end
	else if (iack7_t != iack7_d) begin
		cart_on <= !cart_ar;
		nmi_arm <= 1'b1;
	end
	else if (beat_new && dec == T_NMIV) nmi_arm <= 1'b0;

	// the freezes
	if (reset) begin
		ar_vis  <= 1'b0;
		ar_hide <= 1'b0;
		ar_rst  <= 1'b1;
		ar_mode <= 2'b00;
	end
	else if (!cart_ar) begin
		ar_rst <= 1'b0;
		if (freeze_s[2] != freeze_s[1]) nmi_t <= ~nmi_t;
	end
	else if (ar_rst && ar_chw) begin
		ar_rst   <= 1'b0;
		ar_vis   <= 1'b1;
		ar_cause <= 2'd3;
		nmi_t    <= ~nmi_t;
	end
	else if (ar_idle && (ar_cia || ar_cib || freeze_s[2] != freeze_s[1])) begin
		ar_vis   <= 1'b1;
		ar_cause <= ar_cia ? 2'd1 : ar_cib ? 2'd2 : 2'd0;
		nmi_t    <= ~nmi_t;
	end
	else if (ar_ctl && lb_we && lb_be[2]) begin
		ar_mode  <= lb_wdata[17:16];
		ar_cause <= 2'd0;
		ar_hide  <= 1'b1;
	end
	else if (ar_hide && beat_new && lb_tt == 2'b00 && (lb_tm == 3'd2 || lb_tm == 3'd6) &&
	         !(lb_addr[31:24] == 8'h00 && lb_addr[23:19] == 5'b10101)) begin
		ar_vis  <= 1'b0;
		ar_hide <= 1'b0;
	end
	if (iack7_t != iack7_d) pcs_ack <= pcs_ack + 1'd1;
	if (beat_new && dec == T_NMIV) pcs_nmi <= pcs_nmi + 1'd1;
end

// the ports: a request is outstanding while req differs from ack.  A write
// is posted (the beat terminates after its region's cycle time while the
// memory takes it); a read waits for the port to be idle, so it follows the
// posted write.  A line read's other SDRAM quad word is fetched behind the
// first (sd_pf).
wire       sd_busy = (sd_req != sd_ack);
wire       dd_busy = (dd_req != dd_ack);
reg        sd_pf;           // the outstanding SDRAM request is the line's prefetch

function automatic [31:0] q_long(input [63:0] q, input a2);
	q_long = a2 ? q[31:0] : q[63:32];
endfunction
function automatic [31:0] l_long(input [127:0] l, input [1:0] a32);
	case (a32)
		2'd0:    l_long = l[127:96];
		2'd1:    l_long = l[95:64];
		2'd2:    l_long = l[63:32];
		default: l_long = l[31:0];
	endcase
endfunction

// Ramsey starts a refresh on this clock: a beat taken on it sees the refresh
// (and its page closed), not the state before it
wire rf_start = ce && rf_busy == 0 && ramsey_cfg[6:5] != 2'd3 && rf_cnt >= rf_ival - 1'd1;
wire [2:0] rf_busy_eff = rf_start ? 3'd4 : rf_busy;
wire       page_open_eff = page_open && !rf_start;

always @(posedge clk) begin
	ac_wr  <= 1'b0;

	if (ce) begin
		if (elapsed != 6'h3F) elapsed <= elapsed + 1'd1;
		// Ramsey's refresh
		if (rf_busy != 0) begin
			rf_busy <= rf_busy - 1'd1;
			if (rf_busy == 3'd1 && ramsey_wr_pend) begin
				ramsey_cfg     <= ramsey_wr;
				ramsey_wr_pend <= 1'b0;
			end
		end
		else if (ramsey_cfg[6:5] != 2'd3) begin
			if (rf_start) begin
				rf_cnt    <= 9'd0;
				rf_busy   <= 3'd4;
				page_open <= 1'b0;
			end
			else rf_cnt <= rf_cnt + 1'd1;
		end
	end

	if (io_reset) begin
		gary_timeout <= 1'b0;
		gary_toenb   <= 1'b0;
		gary_timedout <= 1'b0;
		gary_ien     <= 1'b1;
	end

	// the line's prefetched quad word arrives
	if (sd_pf && !sd_busy) begin
		sd_pf <= 1'b0;
		if (sdb_a == sd_addr[24:4]) begin
			sdb_v[sd_addr[3]] <= 1'b1;
			sdb_d[sd_addr[3]] <= sd_rdata;
		end
	end

	if (reset) begin
		st             <= S_IDLE;
		lb_ack         <= lb_req;
		sd_req         <= sd_ack;
		dd_req         <= dd_ack;
		sb_req         <= sb_ack;
		sdb_v          <= 1'b0;
		ddb_v          <= 1'b0;
		sd_pf          <= 1'b0;
		rtg_cs         <= 1'b0;
		rtg_rd         <= 1'b0;
		rtg_wr         <= 1'b0;
		page_open      <= 1'b0;
		rf_cnt         <= 9'd0;
		rf_busy        <= 3'd0;
		ramsey_wr_pend <= 1'b0;
		if (pwrup) begin
			gary_coldboot <= 1'b1;
			ramsey_cfg    <= RAMSEY_PWRUP;
		end
	end
	else case (st)
		S_IDLE: if (rtr_go && rtr_rdy && !beat_new && !dd_busy) begin
			// the frozen retired-PC ring, one entry at a time, then its header
			dd_addr  <= rtr_i[8] ? {13'h07FF, 8'h61, 6'd3 + 6'(rtr_i[1:0])} : {13'h07FF, 6'b011001, rtr_i[7:0]};
			dd_we    <= 1'b1;
			dd_be    <= 4'hF;
			dd_wdata <= !rtr_i[8] ? rtr_rd : (rtr_i[1:0] == 2'd0) ? {24'h00005A, rtr_wp} :
			            (rtr_i[1:0] == 2'd1) ? {24'd0, rtr_xvec} : rtr_xpc;
			dd_req   <= ~dd_req;
			if (rtr_i[8] && rtr_i[1:0] == 2'd2) rtr_hdr <= 1'b1;
			rtr_i    <= rtr_i + 1'd1;
		end
		else if (bus_go && bus_rdy && !beat_new && !dd_busy) begin
			// the bus ring, a word at a time, after the retired-PC ring
			dd_addr  <= {13'h07FF, 4'h7, bus_i};
			dd_we    <= 1'b1;
			dd_be    <= 4'hF;
			dd_wdata <= bus_q;
			dd_req   <= ~dd_req;
			bus_i    <= bus_i + 1'd1;
			if (bus_i == 10'h3FF) bus_done <= 1'b1;
		end
		else if (PCS_EN && !beat_new && pcs_t != pcs_d && !dd_busy) begin
			// a PC sample: the slot (unless the ring has stopped), then the
			// count and the event counters
			pcs_d    <= pcs_t;
			dd_addr  <= pcs_stop ? {13'h07FF, 8'h61, 6'd2} : {13'h07FF, 8'h60, pcs_n[5:0]};
			dd_we    <= 1'b1;
			dd_be    <= 4'hF;
			dd_wdata <= pcs_stop ? dbg_pc : dbg_pc;    // (stopped: the live PC at +$108)
			dd_req   <= ~dd_req;
			if (!pcs_stop) pcs_n <= pcs_n + 1'd1;
			if (pcs_nmi != 8'd0 && !pcs_arm) begin pcs_arm <= 1'b1; pcs_left <= 6'd48; end
			else if (pcs_arm && !pcs_stop) begin
				pcs_left <= pcs_left - 1'd1;
				if (pcs_left == 6'd1) pcs_stop <= 1'b1;
			end
			st       <= S_PCN;
		end
		else if (beat_new) begin
			dbg_tgt <= dec;
			ar_vec  <= 1'b0;
			ar_crd  <= ar_ctl && !lb_we;
			elapsed <= 6'd0;
			berr    <= 1'b0;
			rdata   <= 32'hFFFFFFFF;
			lb_ci   <= inhibited(dec);
			// a line's quad word / line buffer serves only that line's beats
			if (!lb_line || lb_beat == 2'd0) begin
				sdb_v <= 2'b00;
				ddb_v <= 1'b0;
			end
			case (dec)
				T_CHIP, T_CREG, T_CIA, T_RTC, T_IDE, T_A2065, T_TOCC: begin
					sb_tgt   <= (dec == T_CHIP) ? SB_CHIP : (dec == T_CREG) ? SB_CREG : (dec == T_CIA) ? SB_CIA :
					            (dec == T_RTC) ? SB_RTC : (dec == T_IDE) ? SB_IDE : (dec == T_A2065) ? SB_A2065 : SB_TOCC;
					sb_addr  <= lb_addr[23:2];
					sb_we    <= lb_we;
					sb_be    <= lb_be;
					sb_wdata <= lb_wdata;
					sb_req   <= ~sb_req;
					need     <= 6'd0;
					st       <= S_PORT;
				end
				T_ROM, T_MBRAM, T_CART, T_AR: begin
					if (dec == T_ROM)
						need <= fast ? 6'd0 : {4'd0, rom_speed} + 6'd5;
					else if (dec == T_CART || dec == T_AR)
						need <= fast ? 6'd0 : 6'd5;
					else begin
						// Ramsey: wait out a refresh, then the access
						logic [5:0] acc;
						if (ramsey_cfg[0]) begin
							acc = (page_open_eff && page_row == lb_addr[31:11]) ? 6'd3 : 6'd7;
							page_open <= 1'b1;
							page_row  <= lb_addr[31:11];
						end
						else acc = ramsey_cfg[4] ? 6'd4 : 6'd5;
						need <= fast ? 6'd0 : acc + {3'd0, rf_busy_eff};
					end
					if ((dec == T_ROM || (dec == T_AR && !lb_addr[18])) && lb_we) begin
						// the ROM ignores writes
						st <= S_WAIT;
					end
					else if (!lb_we && lb_line && lb_beat != 2'd0 && sdb_v[sd_byte[3]] && sdb_a == sd_byte[24:4]) begin
						rdata <= q_long(sdb_d[sd_byte[3]], sd_byte[2]);
						st    <= S_WAIT;
					end
					else if (!lb_we && lb_line && lb_beat != 2'd0 && sd_busy && sd_pf && sdb_a == sd_byte[24:4] && sd_addr[3] == sd_byte[3]) begin
						// the prefetch of this quad word is on its way
						st <= S_SDR;
					end
					else st <= S_SDQ;
				end
				T_MBNONE: begin
					need <= fast ? 6'd0 : ramsey_cfg[4] ? 6'd4 : 6'd5;
					st   <= S_WAIT;
				end
				T_Z3R256, T_Z3R128, T_RTGFB, T_SHARE: begin
					need <= fast ? 6'd0 : (dec == T_RTGFB || dec == T_SHARE) ? CYC_RTG : CYC_Z3RAM;
					if (!lb_we && ddb_v && (lb_line && lb_beat != 2'd0) && ddb_a == dd_byte[28:4]) begin
						rdata <= l_long(ddb_d, dd_byte[3:2]);
						st    <= S_WAIT;
					end
					else st <= S_DDQ;
				end
				T_MBRES: begin
					need <= fast ? 6'd0 : CYC_REG;
					rdata <= mbres_rd;
					// reading $DE0000 (lane 0 of a long word below $DE8000) returns
					// the timed-out bit and resets it
					if (!lb_we && !lb_off[15] && lb_be[3]) gary_timedout <= 1'b0;
					if (lb_we && !lb_off[15]) begin
						// (WinUAE mbres_write: below $DE8000)
						if (lb_be[0] && lb_off[7:6] == 2'd0) begin ramsey_wr <= lb_wdata[7:0]; ramsey_wr_pend <= 1'b1; end
						if (lb_be[1]) gary_coldboot <= lb_wdata[15];
						if (lb_be[2]) gary_toenb    <= lb_wdata[23];
						if (lb_be[3]) gary_timeout  <= lb_wdata[31];
					end
					st <= S_WAIT;
				end
				T_ACZ2, T_ACZ3: begin
					need  <= fast ? 6'd0 : CYC_AC;
					rdata <= ac_rdata;
					ac_wr <= lb_we;
					st    <= S_WAIT;
				end
				T_RTGREG: begin
					// 16-bit registers: a long word is two cycles, high word first
					need    <= fast ? 6'd0 : CYC_RTG;
					rfirst  <= 1'b1;
					rtg_cs  <= 1'b1;
					rtg_rs  <= {lb_addr[11:2], ~(lb_be[3] | lb_be[2])};
					rtg_din <= (lb_be[3] | lb_be[2]) ? lb_wdata[31:16] : lb_wdata[15:0];
					rtg_be  <= (lb_be[3] | lb_be[2]) ? lb_be[3:2] : lb_be[1:0];
					rtg_rd  <= !lb_we;
					rtg_wr  <= lb_we;
					st      <= S_RTG;
				end
				T_CPUSP: begin
					berr <= 1'b1;
					st   <= S_DONE;
				end
				T_FLOAT: begin
					need <= fast ? 6'd0 : CYC_AC;
					st   <= S_WAIT;
				end
				T_GIEN: begin
					// Gary's 16-bit interrupt enable at offset $09A of each 4 KB:
					// only bit 15 exists (Gary spec, System Interrupt Control)
					need <= fast ? 6'd0 : CYC_REG;
					if (lb_we && lb_off[11:2] == 10'h026 && lb_be[1]) gary_ien <= lb_wdata[15];
					st   <= S_WAIT;
				end
				T_NMIV: begin
					// HRTmon's entry, or the Action Replay ROM's vector
					rdata  <= 32'h00A1000C;
					need   <= fast ? 6'd0 : cart_ar ? 6'd5 : CYC_REG;
					ar_vec <= cart_ar;
					st     <= cart_ar ? S_SDQ : S_WAIT;
				end
				default: begin
					// nothing decodes the address: Gary's timeout
					tout <= gary_timeout ? 24'(TOUT_BERR) : 24'(TOUT_DSACK);
					st   <= S_TOUT;
				end
			endcase
		end

		S_PORT: if (sb_ack == sb_req) begin
			// the slow bus's data
			rdata <= sb_rdata;
			st    <= S_WAIT;
		end

		S_SDQ: if (!sd_busy) begin
			// the SDRAM is idle (a posted write or a prefetch done): issue
			sd_addr  <= sd_byte;
			sd_we    <= lb_we;
			sd_be    <= lb_be;
			sd_wdata <= lb_wdata;
			sd_req   <= ~sd_req;
			sd_pf    <= 1'b0;
			if (lb_we) begin
				if (sdb_a == sd_byte[24:4]) sdb_v <= 2'b00;
				st <= S_WAIT;
			end
			else st <= S_SDR;
		end

		S_SDR: if (!sd_busy) begin
			// the quad word is here; the AR's control register reads the
			// freeze cause in D1-D0 of its odd bytes
			rdata <= ar_crd ? ((q_long(sd_rdata, sd_byte[2]) & 32'hFFFCFFFC) | {14'd0, ar_cause, 14'd0, ar_cause})
			                : q_long(sd_rdata, sd_byte[2]);
			if (lb_line) begin
				sdb_a             <= sd_byte[24:4];
				sdb_v[sd_byte[3]] <= 1'b1;
				sdb_d[sd_byte[3]] <= sd_rdata;
				if (lb_beat == 2'd0) begin
					// fetch the line's other quad word behind this one
					sdb_v[~sd_byte[3]] <= 1'b0;
					sd_addr <= {sd_byte[24:4], ~sd_byte[3], 1'b0};
					sd_we   <= 1'b0;
					sd_req  <= ~sd_req;
					sd_pf   <= 1'b1;
				end
			end
			st <= S_WAIT;
		end

		S_DDQ: if (!dd_busy) begin
			dd_addr  <= dd_byte;
			dd_we    <= lb_we;
			dd_be    <= lb_be;
			dd_wdata <= lb_wdata;
			dd_req   <= ~dd_req;
			if (lb_we) begin
				if (ddb_v && ddb_a == dd_byte[28:4]) ddb_v <= 1'b0;
				st <= S_WAIT;
			end
			else st <= S_DDR;
		end

		S_PCN: if (lb_req != lb_ack) st <= S_IDLE;   // a CPU beat: not behind DDR3
		else if (!dd_busy) begin
			dd_addr  <= {13'h07FF, 8'h61, 6'd0};
			dd_wdata <= {6'd0, pcs_n};
			dd_req   <= ~dd_req;
			st       <= S_PCE;
		end

		S_PCE: if (lb_req != lb_ack) st <= S_IDLE;
		else if (!dd_busy) begin
			dd_addr  <= {13'h07FF, 8'h61, 6'd1};
			dd_wdata <= {8'd0, pcs_ack, 8'd0, pcs_nmi};
			dd_req   <= ~dd_req;
			st       <= S_IDLE;
		end

		S_DDR: if (!dd_busy) begin
			rdata <= l_long(dd_rdata, dd_addr[3:2]);
			if (lb_line) begin
				ddb_v <= 1'b1;
				ddb_a <= dd_addr[28:4];
				ddb_d <= dd_rdata;
			end
			st <= S_WAIT;
		end

		S_RTG: if (rtg_ready) begin
			// rtg.v: a register write is taken at once, a read answers a
			// clock (a register) or three (the CLUT) later, as does a CLUT
			// write (it keeps the entry's other components)
			rtg_cs <= 1'b0;
			rtg_rd <= 1'b0;
			rtg_wr <= 1'b0;
			if (!lb_we) begin
				if (rtg_rs[1]) rdata[15:0]  <= rtg_dout;
				else           rdata[31:16] <= rtg_dout;
			end
			if (rfirst && (lb_be[3] | lb_be[2]) && (lb_be[1] | lb_be[0])) begin
				rfirst <= 1'b0;
				st     <= S_RTG2;
			end
			else st <= S_WAIT;
		end

		S_RTG2: begin
			// the low word of a long word
			rtg_cs  <= 1'b1;
			rtg_rs  <= {lb_addr[11:2], 1'b1};
			rtg_din <= lb_wdata[15:0];
			rtg_be  <= lb_be[1:0];
			rtg_rd  <= !lb_we;
			rtg_wr  <= lb_we;
			st      <= S_RTG;
		end

		S_TOUT: begin
			if (!gary_toenb) begin
				if (tout != 0) tout <= tout - 1'd1;
				else begin
					berr <= gary_timeout;
					gary_timedout <= 1'b1;
					st   <= S_DONE;
				end
			end
		end

		S_WAIT: begin
			// the region's cycle time
			if (elapsed >= need) st <= S_DONE;
		end

		S_DONE: begin
			lb_rdata <= rdata;
			lb_berr  <= berr;
			lb_ack   <= lb_req;
			st       <= S_IDLE;
		end

		default: st <= S_IDLE;
	endcase
end

endmodule
