// Full-system simulation driver for the Maximig (A4000/040) core.
//
//   ./obj_dir/Vtb_top --rom FILE [options]
//     --rom FILE        Kickstart (or a test program) image, 256 KB or 512 KB,
//                       loaded into the SDRAM's ROM area (0x780000) the way
//                       the HPS uploads it
//     --ms N            simulated milliseconds to run (default 1000)
//     --speed N         CPU clock (config TT): 0 25 MHz, 1 33, 2 50, 3 56.75
//     --fast            Fast bus timing (config P)
//     --mbram N         motherboard RAM: 0 none, 1 4 MB, 2 8 MB, 3 16 MB (default 3)
//     --z3 N            Zorro III RAM config: 0 none, 1 128 MB, 4 256 MB, 5 384 MB
//     --ntsc            NTSC
//     --frames DIR      write captured frames as DIR/frame_NNNN.ppm
//     --frame-every N   only every Nth frame (default 1)
//     --baud N          decode Paula's serial output at N baud (default 9600)
//     --lbtrace         print every local-bus beat
//     --lbtrace-from MS start the beat trace at MS milliseconds
//     --pctrace N       print the PC every N clk_57 cycles
//     --iostat          bus beats per region every 100 ms
//     --customtrace     print writes to DMACON, COP1LC/2LC, COPJMP, BPLCON0, INTENA,
//                       INTREQ, COLOR00
//     --dumpchip MS FILE write the 2 MB of chip RAM to FILE at MS milliseconds
//     --cart FILE       upload FILE at $A10000 through Main's UIO_MM2_WR
//                       protocol (HRTmon is enabled in the config)
//     --ddrpeek ADDR    at the end, print the long word at DDR3 physical ADDR
//     --extrom FILE     load FILE at $E00000 (SDRAM 0x700000), as Main does
//     --cart-config     after --cart, write HRTmon's configuration as Main does
//     --freeze-ms N     press F11 after N simulated milliseconds of running
//     --quiet           no progress lines
//     --vcd FILE        (TRACE=1 builds) write an FST waveform of
//     --vcd-from MS     ... the window from MS
//     --vcd-to MS       ... to MS
//
//   A test program reports through the mailbox at $00F00000 (nothing on the
//   A4000 decodes it, so Gary times the write out; the simulation sees the
//   beat): +0 result ($600D0000 + n PASS, $BAD00000 + n FAIL: the run ends),
//   +4 a character, +8 a value printed in hex, +12 a mark (3: the share
//   window check; 4: the bench presses the HRTmon key, Help, $5F).
#include "Vtb_top.h"
#include "Vtb_top__Dpi.h"
#include "verilated.h"
#include "svdpi.h"
#if VM_TRACE
#include "verilated_fst_c.h"
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <sys/stat.h>

static Vtb_top *top;
static uint64_t halfstep = 0;       // half periods of clk_114
#if VM_TRACE
static VerilatedFstC *tfp = nullptr;
static uint64_t trace_from = 0, trace_to = 0;
#endif
static const double CLK114_HZ = 113500640.0;

// three edge-aligned clocks: clk_114, clk_57 = /2, clk_sys = /4
static void step_half()
{
	uint64_t p = halfstep++;
	top->clk_114 = (p & 1) ? 0 : 1;
	top->clk_57  = ((p >> 1) & 1) ? 0 : 1;
	top->clk_sys = ((p >> 2) & 1) ? 0 : 1;
	top->eval();
#if VM_TRACE
	if (tfp && p >= trace_from && p < trace_to) tfp->dump(p * 4405);   // ps
#endif
}

static double sim_ms() { return halfstep / (2.0 * CLK114_HZ) * 1000.0; }

// one clk_sys period (8 half steps), calling fn after each clk_sys rising edge
template <typename F> static void sys_cycle(F fn)
{
	for (int i = 0; i < 8; i++) {
		step_half();
		if ((halfstep - 1) % 8 == 0) fn();
	}
}

//----------------------------------------------------------------------------
// the HPS: Minimig's userio commands on the IO channel
//----------------------------------------------------------------------------
static void idle_sys(int n) { for (int i = 0; i < n; i++) sys_cycle([]{}); }

static void uio_cmd(const std::vector<uint8_t> &bytes)
{
	top->io_uio = 1;
	idle_sys(2);
	for (uint8_t b : bytes) {
		top->io_din = b;
		top->io_strobe = 1;
		idle_sys(1);
		top->io_strobe = 0;
		idle_sys(4);
		while (top->io_wait) idle_sys(1);
	}
	top->io_uio = 0;
	idle_sys(4);
}

//----------------------------------------------------------------------------
// memories
//----------------------------------------------------------------------------
static void sdram_scope() { svSetScope(svGetScopeFromName("TOP.tb_top.sdram")); }
static void ddr_scope() { svSetScope(svGetScopeFromName("TOP.tb_top.ddr3")); }

// The HPS share window as Main's minimig_share.cpp sees it (DDR3 0x27FF4000,
// the ARM's byte order).  At mark 3 t_board has written a request flag the
// way L:MiSTerFileSystem does, $5104A55A at $DD4000.  minimig_share_poll()
// takes a request when the flag, read as a uint32, has 0x5AA5 in its top
// half and ((id - 77) & 0xFF) == ((id >> 8) & 0xFF); it acknowledges by
// storing (uint16_t)id at +2, which t_board reads back as $51045104.
static bool share_check()
{
	const uint32_t w = 0x27FF4000u >> 3;
	ddr_scope();
	uint64_t v = ddr_peek64(w);
	uint32_t id = (uint32_t)v;
	bool taken = ((id >> 16) & 0xFFFF) == 0x5AA5 && ((id - 77) & 0xFF) == ((id >> 8) & 0xFF);
	printf("[share] request flag as Main reads it: %08X (%s)\n", id, taken ? "a request" : "not a request");
	if (!taken) return false;
	v = (v & 0xFFFFFFFF0000FFFFull) | ((uint64_t)(id & 0xFFFF) << 16);
	ddr_poke64(w, v);
	return true;
}

static bool load_rom(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
	std::vector<uint8_t> b(0x80000);
	size_t n = fread(b.data(), 1, b.size(), f);
	fclose(f);
	if (n == 0x40000) memcpy(b.data() + 0x40000, b.data(), 0x40000);   // a 256 KB ROM is mirrored
	else if (n != 0x80000) { fprintf(stderr, "%s: %zu bytes, want 256 or 512 KB\n", path, n); return false; }
	sdram_scope();
	for (uint32_t i = 0; i < 0x80000; i += 2)
		sdram_poke16((0x780000 + i) >> 1, (b[i] << 8) | b[i + 1]);
	return true;
}

// an extension ROM, where Main uploads the other half of a 1 MB Kickstart
// ($E00000-$E7FFFF, SDRAM 0x700000)
static bool load_extrom(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
	std::vector<uint8_t> b(0x80000, 0);
	size_t n = fread(b.data(), 1, b.size(), f);
	fclose(f);
	sdram_scope();
	for (uint32_t i = 0; i < n; i += 2)
		sdram_poke16((0x700000 + i) >> 1, (b[i] << 8) | b[i + 1]);
	return true;
}

// Upload through userio and the halted CPU's chip-bus bridge, as Main's
// SendFileV2 does.  Direct SDRAM pokes would miss upload/decode failures.
static bool load_cart(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
	std::vector<uint8_t> b(0x70000);
	size_t n = fread(b.data(), 1, b.size(), f);
	fclose(f);
	for (uint32_t i = 0; i < n; i += 512) {
		uint32_t a = 0xA10000 + i;
		std::vector<uint8_t> cmd = {0xF0, (uint8_t)a, (uint8_t)(a >> 8), (uint8_t)(a >> 16), 0};
		for (uint32_t j = 0; j < 512; j++) cmd.push_back(i + j < n ? b[i + j] : 0);
		uio_cmd(cmd);
	}
	return true;
}

static void dump_chip(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return; }
	sdram_scope();
	for (uint32_t w = 0; w < 0x100000; w++) {
		uint32_t v = sdram_peek16(w);
		fputc((v >> 8) & 0xFF, f);
		fputc(v & 0xFF, f);
	}
	fclose(f);
}

//----------------------------------------------------------------------------
// video capture
//----------------------------------------------------------------------------
struct Video {
	std::string dir;
	int every = 1, xscale = 2;
	int x = 0, y = 0, frame = 0, written = 0;
	int maxx = 0;
	bool old_hs = 1, old_vs = 1;
	static const int W = 2048, H = 700;
	std::vector<uint8_t> buf = std::vector<uint8_t>(W * H * 3);
	int sub = 0;

	void sample()
	{
		bool hs = top->hs_n, vs = top->vs_n;
		if (old_vs && !vs) {
			if (!dir.empty() && (frame % every) == 0) write();
			frame++;
			y = 0;
		}
		if (old_hs && !hs) { if (x > maxx) maxx = x; x = 0; y++; sub = 0; }
		old_hs = hs; old_vs = vs;
		if (++sub < xscale) return;
		sub = 0;
		if (x < W && y < H) {
			uint8_t *p = &buf[(y * W + x) * 3];
			p[0] = top->red; p[1] = top->green; p[2] = top->blue;
		}
		x++;
	}
	void write()
	{
		char name[512];
		snprintf(name, sizeof name, "%s/frame_%04d.ppm", dir.c_str(), frame);
		FILE *f = fopen(name, "wb");
		if (!f) return;
		int w = maxx < W ? maxx : W, h = H < 640 ? H : 640;
		if (w <= 0) w = 1;
		fprintf(f, "P6\n%d %d\n255\n", w, h);
		for (int yy = 0; yy < h; yy++) fwrite(&buf[yy * W * 3], 1, w * 3, f);
		fclose(f);
		written++;
	}
};

//----------------------------------------------------------------------------
// Paula's serial output
//----------------------------------------------------------------------------
struct Uart {
	double bit_sys = 28375160.0 / 9600.0;   // clk_sys cycles per bit
	int state = 0; double cnt = 0; int bits = 0, val = 0;
	std::string line;
	void sample()
	{
		bool rx = top->uart_tx;
		if (state == 0) { if (!rx) { state = 1; cnt = bit_sys * 1.5; bits = 0; val = 0; } return; }
		if (--cnt > 0) return;
		if (bits < 8) { val |= (rx ? 1 : 0) << bits; bits++; cnt += bit_sys; return; }
		state = 0;
		if (val == '\n') { printf("[serial] %s\n", line.c_str()); fflush(stdout); line.clear(); }
		else if (val != '\r') line += (val >= 32 && val < 127) ? (char)val : '.';
	}
};

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	top = new Vtb_top;

	const char *rom = nullptr;
	double run_ms = 1000;
	int speed = 0, mbram = 3, z3 = 0, baud = 9600;
	bool fast = false, ntsc = false, lbtrace = false, quiet = false, iostat = false, customtrace = false;
	double lbtrace_from = 0, dump_ms = -1, freeze_ms = -1;
	const char *dump_file = nullptr, *cart = nullptr;
	bool cart_config = false;
	const char *extrom = nullptr;
	std::vector<uint32_t> ddrpeek;
	long pctrace = 0;
	Video video;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() { return (i + 1 < argc) ? argv[++i] : (char *)""; };
		if (a == "--rom") rom = next();
		else if (a == "--ms") run_ms = atof(next());
		else if (a == "--speed") speed = atoi(next());
		else if (a == "--fast") fast = true;
		else if (a == "--mbram") mbram = atoi(next());
		else if (a == "--z3") z3 = atoi(next());
		else if (a == "--ntsc") ntsc = true;
		else if (a == "--frames") { video.dir = next(); mkdir(video.dir.c_str(), 0755); }
		else if (a == "--frame-every") video.every = atoi(next());
		else if (a == "--baud") baud = atoi(next());
		else if (a == "--lbtrace") lbtrace = true;
		else if (a == "--lbtrace-from") { lbtrace = true; lbtrace_from = atof(next()); }
		else if (a == "--pctrace") pctrace = atol(next());
		else if (a == "--quiet") quiet = true;
		else if (a == "--iostat") iostat = true;
		else if (a == "--customtrace") customtrace = true;
		else if (a == "--dumpchip") { dump_ms = atof(next()); dump_file = next(); }
		else if (a == "--cart") cart = next();
		else if (a == "--cart-config") cart_config = true;
		else if (a == "--extrom") extrom = next();
		else if (a == "--ddrpeek") ddrpeek.push_back((uint32_t)strtoul(next(), nullptr, 0));
		else if (a == "--freeze-ms") freeze_ms = atof(next());
#if VM_TRACE
		else if (a == "--vcd") {
			Verilated::traceEverOn(true);
			tfp = new VerilatedFstC;
			top->trace(tfp, 99);
			tfp->open(next());
		}
		else if (a == "--vcd-from") trace_from = (uint64_t)(atof(next()) / 1000.0 * 2.0 * CLK114_HZ);
		else if (a == "--vcd-to")   trace_to   = (uint64_t)(atof(next()) / 1000.0 * 2.0 * CLK114_HZ);
#endif
	}
	if (!rom) { fprintf(stderr, "usage: %s --rom FILE [options]\n", argv[0]); return 2; }

	Uart uart;
	uart.bit_sys = (ntsc ? 28636360.0 : 28375160.0) / baud;

	top->reset = 1;
	top->io_uio = 0; top->io_fpga = 0; top->io_strobe = 0; top->io_din = 0;
	for (int i = 0; i < 3; i++) top->rtc[i] = 0;
	top->kbd_mouse_data = 0; top->kbd_mouse_type = 0; top->kbd_mouse_level = 0;
	idle_sys(64);
	if (!load_rom(rom)) return 2;
	top->reset = 0;
	idle_sys(64);

	// the HPS's configuration (minimig_config.cpp order), then a reset to
	// take it (userio takes the config words while the chipset is in reset)
	uio_cmd({0xF1, 0x07});                                      // halt, CPU reset, user reset
	uio_cmd({0xF3, (uint8_t)(0x10 | (ntsc ? 0x02 : 0x00))});   // chipset: AGA (+NTSC)
	uio_cmd({0xF4, (uint8_t)((fast ? 0x20 : 0x00) | (speed & 3))});
	uio_cmd({0xF5, (uint8_t)(0x43 | ((mbram & 3) << 2) | ((z3 & 3) << 4) | ((z3 & 4) ? 0x80 : 0))});   // (0x40: HRTmon)
	uio_cmd({0xF7, 0x00});                                      // floppy: one drive
	uio_cmd({0xF8, 0x00});                                      // no hard disks
	if (cart && !load_cart(cart)) return 2;
	if (extrom && !load_extrom(extrom)) return 2;
	if (cart && cart_config) {
		// the configuration Main's UploadActionReplay() writes after the image
		// (support/minimig/minimig_config.cpp): +20 and +68 of $A10000; for
		// Maximig a1200 = 0, so HRTmon drives the A4000 IDE ($DD2020, $DD3020),
		// not Gayle's ($DA2000), which nothing answers here
		uio_cmd({0xF0, 0x14, 0x00, 0xA1, 0x00,
		         0x00, 0x80, 0x00, 0x00,     // mon_size
		         0x00, 0x5A, 0x0F, 0xFF,     // col0h col0l col1h col1l
		         0xFF, 0x00, 0xFF, 0xFF,     // right keyboard key ide
		         0x00, 0xFF, 0xFF, 0x0F,     // a1200 aga insert delay
		         0xFF, 0x00, (uint8_t)(ntsc ? 1 : 0), 0xFF,   // lview cd32 screenmode novbr
		         0x00, 0x01});               // entered hexmode
		uio_cmd({0xF0, 0x44, 0x00, 0xA1, 0x00, 0x00, 0x20, 0x00, 0x00});   // maxchip: 2 MB
	}
	uio_cmd({0xF1, 0x03});                                      // release halt, keep reset
	idle_sys(1000);
	uio_cmd({0xF1, 0x00});                                      // run

	uint64_t end_half = halfstep + (uint64_t)(run_ms / 1000.0 * 2.0 * CLK114_HZ);
	uint64_t next_report = halfstep;
	bool old_beat = 0;
	long pc_cnt = 0;
	int result = -1;
	bool halted_reported = false;
	uint64_t beats = 0, retired = 0;
	uint64_t key_at = freeze_ms < 0 ? 0 : halfstep + (uint64_t)(freeze_ms / 1000.0 * 2.0 * CLK114_HZ);
	int key_step = 0;
	bool prev_ce = 0;
	static const char *rname[] = {"chip","mbram","rom","custom","cia","ide","rtc","gary","acfg","z2io","z3","float","other"};
	uint64_t rcnt[13] = {0};
	auto region = [](uint32_t a) -> int {
		if (a < 0x200000) return 0;
		if ((a >> 24) == 0x07) return 1;
		if (a >= 0xF80000 && a < 0x1000000) return 2;
		if ((a >> 16) == 0xDF || (a >> 20) == 0xC) return 3;
		if ((a >> 16) == 0xBF) return 4;
		if ((a >> 16) == 0xDD) return 5;
		if ((a >> 16) == 0xDC) return 6;
		if ((a >> 16) == 0xDE) return 7;
		if ((a >> 16) == 0xE8 || (a >> 24) == 0xFF) return 8;
		if (a >= 0xE90000 && a < 0xF00000) return 9;
		if (a >= 0x10000000 && a < 0x80000000u) return 10;
		if (a < 0xB80000 || (a >= 0xF00000 && a < 0xF80000)) return 11;
		return 12;
	};

	while (halfstep < end_half && result < 0) {
		step_half();
		// a key as Main sends one: type 2 (keyboard), the code, the level toggled
		if (key_at && key_step == 0 && halfstep >= key_at) {
			top->kbd_mouse_type = 2; top->kbd_mouse_data = 0x5F; top->kbd_mouse_level ^= 1; key_step = 1;
		}
		else if (key_step == 1 && halfstep >= key_at + (uint64_t)(0.0002 * 2.0 * CLK114_HZ)) {
			top->kbd_mouse_data = 0xDF; top->kbd_mouse_level ^= 1; key_step = 2;
		}
		uint64_t ph = (halfstep - 1) % 8;
		if (ph == 0) { video.sample(); uart.sample(); }
		if (ph % 4 == 0) {
			// a clk_57 rising edge; the CPU's registers moved at it if cpu_ce
			// was set before it (the CPU's outputs then hold a new cycle)
			if (prev_ce && top->dbg_retire) retired++;
			prev_ce = top->dbg_cpu_ce;
			if (top->dbg_lb_beat) {
				beats++;
				uint32_t ad = top->dbg_lb_addr, d = top->dbg_lb_data;
				rcnt[region(ad)]++;
				if (customtrace && top->dbg_lb_we && (ad & 0xFFFFF000) == 0x00DFF000) {
					uint32_t r = ad & 0xFFC;
					if (r == 0x094 || r == 0x080 || r == 0x084 || r == 0x088 || r == 0x098 || r == 0x09C ||
					    r == 0x100 || r == 0x180)
						printf("[custom] %10.4f ms  W %08X %08X\n", sim_ms(), ad, d);
				}
				if (lbtrace && sim_ms() >= lbtrace_from)
					printf("%10.4f ms  %c %08X %08X\n", sim_ms(), top->dbg_lb_we ? 'W' : 'R', ad, d);
				if (top->dbg_lb_we && (ad & 0xFFFF0000) == 0x00F00000) {
					uint32_t off = ad & 0xFFFF;
					if (off == 0) {
						printf("[mailbox] %.4f ms result %08X\n", sim_ms(), d);
						result = ((d & 0xFFFF0000) == 0x600D0000) ? 0 : 1;
					}
					else if (off == 4) { putchar((int)(d & 0xFF)); fflush(stdout); }
					else if (off == 8) { printf("%08X\n", d); fflush(stdout); }
					else if (off == 12) {
						printf("[mark] %u at %.6f ms\n", d, sim_ms()); fflush(stdout);
						if (d == 3 && !share_check()) { printf("[share] FAIL: Main would not see the request\n"); result = 1; }
						if (d == 4) { key_at = halfstep; printf("[hrtmon] the HRTmon key\n"); }
					}
				}
			}
			if (pctrace && ++pc_cnt >= pctrace) { pc_cnt = 0; printf("%10.4f ms  PC %08X\n", sim_ms(), top->dbg_pc); }
			if (top->dbg_halted && !halted_reported) {
				printf("[cpu] halted (double bus fault) at %.4f ms, PC %08X\n", sim_ms(), top->dbg_pc);
				halted_reported = true;
				result = 1;
			}
		}
		if (dump_file && dump_ms >= 0 && sim_ms() >= dump_ms) {
			dump_chip(dump_file);
			printf("[dump] chip RAM to %s at %.3f ms\n", dump_file, sim_ms());
			dump_ms = -1;
		}
		if (!quiet && halfstep >= next_report) {
			printf("[sim] %.1f ms  PC %08X  beats %lu  retired %lu  frames %d\n", sim_ms(), top->dbg_pc,
			       (unsigned long)beats, (unsigned long)retired, video.frame);
			fflush(stdout);
			next_report = halfstep + (uint64_t)(0.1 * 2.0 * CLK114_HZ);   // every 100 ms
			if (iostat) {
				printf("[io]");
				for (int i = 0; i < 13; i++) if (rcnt[i]) printf(" %s=%lu", rname[i], (unsigned long)rcnt[i]);
				printf("\n");
				memset(rcnt, 0, sizeof rcnt);
			}
		}
	}
	if (!uart.line.empty()) printf("[serial] %s\n", uart.line.c_str());
	for (uint32_t a : ddrpeek) {
		ddr_scope();
		uint64_t v = ddr_peek64(a >> 3);
		printf("[ddr] %08X: %08X (as the ARM reads it)\n", a, (uint32_t)(v >> ((a & 4) ? 32 : 0)));
	}
	printf("[sim] end at %.3f ms, PC %08X, %lu beats, %lu retired, %d frames (%d written)\n", sim_ms(), top->dbg_pc,
	       (unsigned long)beats, (unsigned long)retired, video.frame, video.written);
	top->final();
#if VM_TRACE
	if (tfp) tfp->close();
#endif
	delete top;
	return result < 0 ? 0 : result;
}
