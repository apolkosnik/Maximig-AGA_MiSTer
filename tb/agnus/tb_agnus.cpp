// Driver for tb_agnus (the real Agnus RTL). Usage: obj/tb_agnus TEST [ntsc]
#include "Vtb_agnus.h"
#include "Vtb_agnus___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>

static Vtb_agnus *t;
static uint64_t cyc = 0;
#define R(x) (t->rootp->tb_agnus__DOT__AGNUS1__DOT__##x)

static void eval() { t->eval(); }
// one 28 MHz period: logic samples on the rising edge
static void step()
{
	t->clk = 0; eval();
	t->clk = 1; eval();
	cyc++;
}
// advance to the next clk7_en edge (the next 7 MHz slot) and execute it
static void slot()
{
	for (;;) {
		t->clk = 0; eval();
		bool en = t->clk7_en;
		t->clk = 1; eval(); cyc++;
		if (en) return;
	}
}
static int hp() { return t->hpos >> 1; }       // CCK (Agnus internal)
static int vp() { return t->vpos; }

// the CPU: wait for a chipset (cck=1) slot the DMA leaves free (the bridge's
// DTACK condition), then access the register in the following CPU slot
static void wait_free_cck()
{
	for (;;) {
		t->clk = 0; eval();
		bool en = t->clk7_en, c = t->cck, d = t->dbr;
		t->clk = 1; eval(); cyc++;
		if (en && c && !d) return;
	}
}
static void cpu_write(int reg, int val)
{
	wait_free_cck();
	t->aen = 1; t->hwr = 1; t->lwr = 1; t->rd = 0; t->cpu_addr = (reg >> 1) & 0xFF; t->cpu_wdata = val & 0xFFFF;
	slot();
	t->aen = 0; t->hwr = 0; t->lwr = 0;
	eval();
}
// returns the value and the position the read was taken at
static int last_rd_h, last_rd_v;
static int cpu_read(int reg)
{
	wait_free_cck();
	t->aen = 1; t->rd = 1; t->cpu_addr = (reg >> 1) & 0xFF;
	t->clk = 0; eval();
	while (!t->clk7_en) { t->clk = 1; eval(); cyc++; t->clk = 0; eval(); }
	int v = t->cpu_rdata;
	last_rd_h = hp(); last_rd_v = vp();
	t->clk = 1; eval(); cyc++;
	t->aen = 0; t->rd = 0; eval();
	return v;
}
static void mem_w(uint32_t addr, int val)
{
	t->mem_we = 1; t->mem_addr = (addr >> 1) & 0xFFFFF; t->mem_wdata = val; step(); t->mem_we = 0; eval();
}
static void wait_pos(int v, int h)   // wait until internal CCK h of line v
{
	for (;;) { slot(); if (vp() == v && hp() == h) return; }
}

// slot owner at the coming chipset slot (call before the edge, cck=1)
static const char *owner()
{
	if (!t->dbr) return t->cpu_custom ? "." : "?";
	if (R(dma_dsk)) return "DSK";
	if (R(dma_ref)) return "REF";
	if (R(dma_aud)) return "AUD";
	if (R(dma_bpl)) return "BPL";
	if (R(ack_spr)) return "SPR";
	if (R(ack_cop)) return "COP";
	if (R(ack_blt)) return "BLT";
	return "???";
}

// record a whole line: for each CCK the owner of the chipset slot
struct LineMap { std::vector<std::string> o; std::vector<int> reg; int len; };
static LineMap record_line(int v)
{
	LineMap m; m.len = 0;
	// sync to CCK 0 of line v (hpos rolls to 0, vpos changes at CCK 1)
	for (;;) { slot(); if (hp() == 0 && vp() == (v == 0 ? 0 : v - 1) + (0)) break; }
	// vpos increments at CCK 1; start at CCK 0 of the line whose vpos becomes v
	while (!(vp() == v && hp() == 2)) slot();
	// now go back: record from CCK 2 through to the next line's CCK 1
	int startv = vp();
	for (;;) {
		t->clk = 0; eval();
		bool en = t->clk7_en, c = t->cck;
		std::string own = (en && c) ? owner() : "";
		int h = hp(), vv = vp(), reg = t->reg_addr;
		t->clk = 1; eval(); cyc++;
		if (en && c && vv != startv) break;   // the line is the CCKs with vpos == v
		if (en && c) {
			if ((int)m.o.size() <= h) { m.o.resize(h + 1); m.reg.resize(h + 1); }
			m.o[h] = own; m.reg[h] = reg;
			if (h + 1 > m.len) m.len = h + 1;
		}
	}
	return m;
}
static void print_map(const LineMap &m)
{
	for (int h = 0; h < (int)m.o.size(); h++) {
		if (m.o[h] == "." ) continue;
		printf("  CCK %02X (VHPOSR %02X): %s reg %03X\n", h, h ? h - 1 : 0xE2, m.o[h].c_str(), m.reg[h] << 1);
	}
}

static void reset_chip(bool ntsc)
{
	t->ntsc = ntsc; t->reset_n = 0; t->reset = 1;
	for (int i = 0; i < 64; i++) step();
	t->reset_n = 1;
	for (int i = 0; i < 64; i++) step();
	t->reset = 0;
	for (int i = 0; i < 64; i++) step();
}

static int fails = 0;
static void check(const char *what, long got, long exp)
{
	printf("%s %s: got %ld ($%lX) expected %ld ($%lX)\n", got == exp ? "PASS" : "FAIL", what, got, got, exp, exp);
	if (got != exp) fails++;
}

// copper list helper
static uint32_t cl_ptr;
static void cmove(int reg, int val) { mem_w(cl_ptr, reg); mem_w(cl_ptr + 2, val); cl_ptr += 4; }
static void cwait(int vh, int mask) { mem_w(cl_ptr, vh | 1); mem_w(cl_ptr + 2, mask & 0xFFFE); cl_ptr += 4; }
static void cskip(int vh, int mask) { mem_w(cl_ptr, vh | 1); mem_w(cl_ptr + 2, (mask & 0xFFFE) | 1); cl_ptr += 4; }
static void cend() { cwait(0xFFDF, 0xFFFE); cwait(0xFFFF, 0xFFFE); }
static void start_copper(uint32_t at)
{
	cpu_write(0x080, at >> 16); cpu_write(0x082, at & 0xFFFF);
	cpu_write(0x096, 0x8280);   // DMAEN | COPEN
	cpu_write(0x088, 0);        // COPJMP1
}

// ---------------------------------------------------------------------------
// beam: frame lengths, line lengths, VPOSR id/LOF/LOL
static void t_beam(bool ntsc)
{
	reset_chip(ntsc);
	// read VPOSR in line 100
	wait_pos(100, 0x40);
	int v = cpu_read(0x004);
	printf("VPOSR = %04X (id bits 14-8 = %02X)\n", v, (v >> 8) & 0x7F);
	check("VPOSR Alice id (bits 14-8)", (v >> 8) & 0x7F, ntsc ? 0x33 : 0x23);
	// frame and line lengths over 3 frames
	for (int f = 0; f < 3; f++) {
		while (!(vp() == 0 && hp() == 2)) slot();
		int lines = 0, maxv = 0; std::map<int,int> linelen;
		int prevv = 0, cck = 0;
		std::vector<int> lens;
		for (;;) {
			slot();
			if (t->cck) continue;   // count CCKs at one phase
			cck++;
			if (vp() != prevv) {
				lens.push_back(cck); cck = 0;
				if (vp() == 0) break;
				prevv = vp(); if (prevv > maxv) maxv = prevv;
			}
		}
		lines = maxv + 1;
		printf("frame %d: %d lines; line lengths (CCK) of lines 10..13: %d %d %d %d\n", f, lines,
			lens[10], lens[11], lens[12], lens[13]);
		if (ntsc) {
			check("NTSC line 10 + line 11 length (CCK, real 227+228=455)", lens[10] + lens[11], 455);
		} else {
			check("PAL line length (CCK)", lens[10], 227);
		}
	}
}

// LOL bit and VPOSW clearing it (NTSC)
static void t_lol()
{
	reset_chip(true);
	wait_pos(50, 0x60);
	int a = cpu_read(0x004);
	wait_pos(51, 0x60);
	int b = cpu_read(0x004);
	printf("VPOSR line 50 %04X, line 51 %04X (LOL = bit 7)\n", a, b);
	check("LOL alternates between lines", ((a ^ b) >> 7) & 1, 1);
	// find a line with LOL set, write VPOSW keeping the position, read back
	int l = (a & 0x80) ? 52 : 53;
	wait_pos(l, 0x40);
	int c = cpu_read(0x004);
	cpu_write(0x02A, c & 0x8007);   // VPOSW: same LOF and V10-8
	int d = cpu_read(0x004);
	printf("line %d: VPOSR %04X, after VPOSW %04X\n", l, c, d);
	check("VPOSW clears LOL (WinUAE VPOSW)", (d >> 7) & 1, 0);
}

// DMACON bits 12/11 do not exist (WinUAE: dmacon &= 0x07FF)
static void t_dmacon()
{
	reset_chip(false);
	cpu_write(0x096, 0x9800 | 0x0000);  // set bits 12, 11
	int v = cpu_read(0x002);
	printf("DMACONR after writing $9800: %04X\n", v);
	check("DMACONR bits 12-11 after set", v & 0x1800, 0);
	cpu_write(0x096, 0x1800);
}

// slot map of one line: refresh, disk, audio, sprites, copper, bitplanes
static LineMap last_map;
static void t_slots(bool ntsc, int bpu, int ddfstrt)
{
	reset_chip(ntsc);
	// sprites: all 8 pointing at a sprite that starts at line 0x40 and ends at 0x80
	for (int s = 0; s < 8; s++) {
		uint32_t a = 0x10000 + s * 0x100;
		mem_w(a, 0x4040); mem_w(a + 2, 0x8000);
		for (int i = 4; i < 0x100; i += 2) mem_w(a + i, 0x5555);
		cpu_write(0x120 + s * 4, a >> 16); cpu_write(0x122 + s * 4, a & 0xFFFF);
	}
	// copper: a run of MOVEs to COLOR00 (copper DMA in every free even slot)
	cl_ptr = 0x20000;
	cwait(0x6001, 0xFFFE);
	for (int i = 0; i < 400; i++) cmove(0x180, i);
	cend();
	cpu_write(0x08E, 0x2C81); cpu_write(0x090, 0x2CC1);
	cpu_write(0x092, ddfstrt); cpu_write(0x094, 0x00D0);
	cpu_write(0x100, ((bpu & 7) << 12) | ((bpu & 8) << 1) | 0x0200);
	if (getenv("FMODE")) cpu_write(0x1FC, strtol(getenv("FMODE"), 0, 16));
	for (int p = 0; p < 6; p++) { cpu_write(0x0E0 + p * 4, 3); cpu_write(0x0E2 + p * 4, p * 0x1000); }
	start_copper(0x20000);
	cpu_write(0x096, 0x83A0 | (bpu ? 0x100 : 0)); // SPREN COPEN BPLEN DMAEN
	// a whole frame after the setup: sprites start from their vblank POS/CTL fetch
	while (vp() != 300) slot();
	for (int s = 0; s < 8; s++) {   // the pointers again, as a copper list would in the vertical blank
		uint32_t a = 0x10000 + s * 0x100;
		cpu_write(0x120 + s * 4, a >> 16); cpu_write(0x122 + s * 4, a & 0xFFFF);
	}
	while (vp() != 10) slot();
	t->audio_dmal = 0xF; t->disk_dmal = 1;      // every audio and disk slot requested
	LineMap m = record_line(0x60);
	last_map = m;
	if (getenv("QUIET")) return;
	printf("slot map of line $60 (PAL=%d, %d planes, DDFSTRT %02X):\n", !ntsc, bpu, ddfstrt);
	print_map(m);
	t->audio_dmal = 0; t->disk_dmal = 0;
	int n[8] = {0}; const char *nm[] = {"REF","DSK","AUD","SPR","COP","BPL","BLT"};
	for (auto &o : m.o) for (int k = 0; k < 7; k++) if (o == nm[k]) n[k]++;
	{ int lost = 0; printf("sprite slots lost:"); for (int h = 0x1A; h <= 0x38; h += 2) if (h < (int)m.o.size() && m.o[h] != "SPR") { printf(" VHPOSR %02X (sprite %d) [%s]", h - 1, (h - 0x1A) / 4, m.o[h].c_str()); lost++; } printf(" (%d)\n", lost); }
	printf("counts: REF %d DSK %d AUD %d SPR %d COP %d BPL %d BLT %d\n", n[0], n[1], n[2], n[3], n[4], n[5], n[6]);
}

// bitplane fetches on one line: per plane count, first and last CCK
static void t_ddf(int fmode, int bplcon0, int ddfstrt, int ddfstop)
{
	reset_chip(false);
	cpu_write(0x08E, 0x2C81); cpu_write(0x090, 0x2CC1);
	cpu_write(0x092, ddfstrt); cpu_write(0x094, ddfstop);
	cpu_write(0x1FC, fmode);
	cpu_write(0x100, bplcon0);
	cpu_write(0x108, 0); cpu_write(0x10A, 0);
	cpu_write(0x096, 0x8300);
	LineMap m = record_line(0x60);
	int cnt[8] = {0}, first = -1, last = -1;
	std::string seq;
	for (int h = 0; h < (int)m.o.size(); h++) if (m.o[h] == "BPL") {
		int pl = m.reg[h] - 0x88; cnt[pl & 7]++; if (first < 0) first = h; last = h;
	}
	printf("FMODE %X BPLCON0 %04X DDFSTRT %02X DDFSTOP %02X: plane1 fetches %d (first CCK %02X last %02X)",
		fmode, bplcon0, ddfstrt, ddfstop, cnt[0], first, last);
	for (int p = 1; p < 8; p++) printf(" p%d=%d", p + 1, cnt[p]);
	printf("\n");
	if (getenv("MAP")) print_map(m);
}

// run until frame/line limit, logging copper MOVE bus writes (not COPINS)
struct CopW { int v, h, reg, val; };
static std::vector<CopW> run_log_copper(int frames_lines, bool all = false)
{
	std::vector<CopW> w;
	int lines = 0, prevv = vp();
	while (lines < frames_lines) {
		t->clk = 0; eval();
		bool en = t->clk7_en, c = t->cck;
		if (en && c && t->dbr && R(ack_cop) && (all || (t->reg_addr != 0x46 && t->reg_addr != 0xFF)))
			w.push_back({vp(), hp(), t->reg_addr << 1, t->bus_data});
		t->clk = 1; eval(); cyc++;
		if (vp() != prevv) { prevv = vp(); lines++; }
	}
	return w;
}
static void print_w(const std::vector<CopW> &w, int max = 50)
{
	for (int i = 0; i < (int)w.size() && i < max; i++)
		printf("  copper write line %3d ($%03X) CCK %02X (VHPOSR %02X): reg %03X = %04X\n", w[i].v, w[i].v, w[i].h,
			w[i].h ? w[i].h - 1 : 0xE2, w[i].reg, w[i].val);
}
static int cdang_cpu = 0;
static void copper_case(const char *name, void (*build)(), int lines, bool all = false)
{
	reset_chip(false);
	cl_ptr = 0x20000; build(); cend();
	wait_pos(300, 0x10);
	cpu_write(0x080, 2); cpu_write(0x082, 0);
	cpu_write(0x02E, cdang_cpu);
	cpu_write(0x096, 0x8280);
	// the vertical blank strobe starts the list at line 0
	while (!(vp() == 312 && hp() == 0xE0)) slot();
	printf("%s:\n", name);
	auto w = run_log_copper(lines, all);
	print_w(w);
}
static void b_wrap() { cwait(0xFFDF, 0xFFFE); cwait(0x2C01, 0xFFFE); cmove(0x180, 0x0111); }
static void b_wrap_late() { cwait(0xFFE1, 0xFFFE); cmove(0x180, 0x0FFF); cwait(0x2C01, 0xFFFE); cmove(0x180, 0x0111); }
static void b_hend() { cwait(0x40E4, 0xFFFE); cmove(0x180, 0x0222); cwait(0x41E2, 0xFFFE); cmove(0x180, 0x0333); }
static void b_first() { cmove(0x180, 0x0444); }
static void b_skip() { cwait(0x4001, 0xFFFE); cskip(0x3F01, 0xFFFE); cmove(0x180, 0x0BAD); cmove(0x180, 0x0555);
	cskip(0x6001, 0xFFFE); cmove(0x180, 0x0666); }
static void b_mask() { cwait(0x4F01, 0xFFFE); cwait(0x0001, 0x8F00); cmove(0x180, 0x0777); }
static void b_dang0() { cwait(0x4001, 0xFFFE); cmove(0x040, 0x0123); cmove(0x180, 0x0888); }
static void b_dang1() { cwait(0x4001, 0xFFFE); cmove(0x040, 0x0123); cmove(0x020, 0x0000); cmove(0x180, 0x0999); }
static void b_dang2() { cwait(0x4001, 0xFFFE); cmove(0x07E, 0x0123); cmove(0x030, 0x0000); cmove(0x180, 0x0AAA); }
static void b_vhpos() { cwait(0x4001, 0xFFFE); cmove(0x180, 0x0001); cmove(0x180, 0x0002); cmove(0x180, 0x0003); cwait(0x4041, 0xFFFE); cmove(0x180, 0x0004); }

// interlace: frame lengths and VPOSR LOF; vertical blank interrupt position
static void t_lace(bool ntsc)
{
	reset_chip(ntsc);
	cpu_write(0x100, 0x0204);   // LACE
	for (int f = 0; f < 4; f++) {
		while (!(vp() == 0 && hp() == 0x10)) slot();
		int lof = (cpu_read(0x004) >> 15) & 1;
		int maxv = 0, vbl_v = -1, vbl_h = -1;
		for (;;) {
			slot();
			if (t->vbl_int && vbl_v < 0) { vbl_v = vp(); vbl_h = hp(); }
			if (vp() > maxv) maxv = vp();
			if (vp() == 0 && hp() == 0x10) break;
		}
		printf("frame %d: LOF %d, %d lines; vertical blank interrupt at line %d CCK %02X\n", f, lof, maxv + 1, vbl_v, vbl_h);
		check("lines = base + LOF", maxv + 1, (ntsc ? 262 : 312) + lof);
	}
}

// bitplane DMA on the frame's last line (WinUAE: forced off on the VB start line)
static void t_lastline()
{
	reset_chip(false);
	cpu_write(0x08E, 0x2C81); cpu_write(0x090, 0x2CC1);
	cpu_write(0x1E4, 0x0700);   // DIWHIGH: V10-8 of DIWSTOP = 7 (beyond the frame)
	cpu_write(0x092, 0x38); cpu_write(0x094, 0xD0);
	cpu_write(0x100, 0x1200);
	cpu_write(0x096, 0x8300);
	printf("vdiwstrt %03X vdiwstop %03X\n", (int)R(bpd1__DOT__vdiwstrt), (int)R(bpd1__DOT__vdiwstop));
	while (!(vp() == 311 && hp() == 0x80)) slot();
	{ int pv = R(bpd1__DOT__vdiwena); for (int i = 0; i < 2000; i++) { slot(); if (R(bpd1__DOT__vdiwena) != pv) { pv = R(bpd1__DOT__vdiwena); printf("vdiwena -> %d at line %d CCK %02X\n", pv, vp(), hp()); } } }
	for (int l : {311, 312}) { while (!(vp() == l && hp() == 0x40)) slot(); printf("line %d CCK 40: softena %d hardena %d ddfena %d ddfrun %d vdiwena %d dmaena_d %d\n", l, (int)R(bpd1__DOT__softena), (int)R(bpd1__DOT__hardena), (int)R(bpd1__DOT__ddfena), (int)R(bpd1__DOT__ddfrun), (int)R(bpd1__DOT__vdiwena), (int)R(bpd1__DOT__dmaena_delayed)); }
	for (int l : {311, 312, 0, 1}) {
		LineMap m = record_line(l);
		int n = 0, nr = 0; for (auto &o : m.o) { if (o == "BPL") n++; if (o == "REF") nr++; }
		printf("line %d: %d refresh slots recorded, vdiwena %d\n", l, nr, (int)R(bpd1__DOT__vdiwena));
		printf("line %d: %d bitplane fetches\n", l, n);
		if (l == 312) { check("bitplane fetches on the last line (VB start line)", n, 0); print_map(m); }
	}
}

// VHPOSR read values around the line wrap (WinUAE: 80E1 80E2 8000 8001 8102 8103)
static void t_vhposr()
{
	reset_chip(false);
	for (int h : {0xE0, 0xE1, 0xE2, 0x00, 0x01, 0x02, 0x03}) {
		int line = h >= 0xE0 ? 0x80 : 0x81;
		// position the CPU so that its read lands on successive CCKs
		while (!(vp() == line && hp() == h)) slot();
		int v = cpu_read(0x006);
		printf("VHPOSR read at internal CCK %02X of line %02X: %04X\n", last_rd_h, last_rd_v, v);
	}
}

// sprite DMA inside the bitplane DMA window: WinUAE generate_sprites does no
// sprite DMA while BPRUN is set, whether or not the plane uses the slot
static void sprwin_case(int fmode, int bpu, int ddfstrt, int first_lost_sprite)
{
	char f[8]; snprintf(f, sizeof f, "%X", fmode); setenv("FMODE", f, 1); setenv("QUIET", "1", 1);
	t_slots(false, bpu, ddfstrt);
	int kept = 0; std::string ks;
	for (int spr = first_lost_sprite; spr < 8; spr++)
		for (int w = 0; w < 2; w++) {
			int h = 0x1A + spr * 4 + w * 2;
			if (last_map.o[h] == "SPR") { kept++; char b[32]; snprintf(b, sizeof b, " spr%d.%d@%02X", spr, w, h - 1); ks += b; }
		}
	printf("FMODE %X, %d planes lores, DDFSTRT $%02X: sprite slots of sprites %d-7 still fetched:%s\n", fmode, bpu, ddfstrt, first_lost_sprite, ks.c_str());
	check("sprite DMA slots inside the bitplane window (WinUAE: none)", kept, 0);
}

// BLTPRI: with the CPU waiting (BLS) and BLTPRI=0 the CPU gets a slot after
// 3 cycles it waited (WinUAE BLIT_NASTY_CPU_STEAL_CYCLE_COUNT 3)
static void t_nasty(int pri)
{
	reset_chip(false);
	cpu_write(0x096, 0x7FFF);
	cpu_write(0x096, 0x8240 | (pri ? 0x400 : 0));       // DMAEN BLTEN (BLTPRI)
	cpu_write(0x040, 0x09F0); cpu_write(0x042, 0);         // A->D copy
	cpu_write(0x044, 0xFFFF); cpu_write(0x046, 0xFFFF);
	cpu_write(0x050, 0x0004); cpu_write(0x052, 0);
	cpu_write(0x054, 0x0006); cpu_write(0x056, 0);
	cpu_write(0x064, 0); cpu_write(0x066, 0);
	while (!(vp() == 100 && hp() == 0x40)) slot();
	cpu_write(0x058, (64 << 6) | 32);                      // BLTSIZE: 64 x 32 words
	t->bls = 1;                                            // the CPU wants the bus from now on
	std::string pat;
	int blt = 0, freec = 0;
	// the bridge: BLS while the CPU waits; a free chipset slot gives it DTACK, so
	// BLS drops for the following CPU slot, then the next access waits again
	for (int i = 0; i < 8 * 120; i++) {
		t->clk = 0; eval();
		bool en = t->clk7_en, c = t->cck;
		const char *o = (en && c) ? owner() : nullptr;
		t->clk = 1; eval(); cyc++;
		if (en && !c) t->bls = 1;
		if (o) { std::string so = o; if (so == "BLT") { blt++; pat += 'B'; } else if (so == ".") { freec++; pat += '.'; t->bls = 0; } else pat += 'o'; }
	}
	t->bls = 0;
	printf("BLTPRI=%d, CPU waiting: chipset slots over 120 CCK: blitter %d, free (CPU) %d\n  %s\n", pri, blt, freec, pat.c_str());
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vtb_agnus;
	std::string test = argc > 1 ? argv[1] : "beam";
	bool ntsc = argc > 2 && !strcmp(argv[2], "ntsc");
	setvbuf(stdout, 0, _IONBF, 0);
	setvbuf(stdout, 0, _IONBF, 0);
	if (test == "dbg") { reset_chip(false); for (int i = 0; i < 40; i++) { t->clk=0; eval(); printf("clk7_en %d cck %d hpos %03X vpos %d dbr %d\n", t->clk7_en, t->cck, t->hpos, t->vpos, t->dbr); t->clk=1; eval(); } return 0; }
	if (test == "beam") t_beam(ntsc);
	else if (test == "lol") t_lol();
	else if (test == "dmacon") t_dmacon();
	else if (test == "ddf") t_ddf(strtol(argv[2],0,16), strtol(argv[3],0,16), strtol(argv[4],0,16), strtol(argv[5],0,16));
	else if (test == "cop") {
		copper_case("WAIT $FFDF, WAIT $2C01, MOVE (line $12C expected)", b_wrap, 320);
		copper_case("WAIT $FFE1, MOVE, WAIT $2C01, MOVE", b_wrap_late, 320);
		copper_case("WAIT $40E4 (beyond line end), MOVE; WAIT $41E2, MOVE", b_hend, 100);
		copper_case("first copper bus cycles after the vertical blank restart", b_first, 3, true);
		copper_case("SKIP true skips one MOVE; SKIP false does not", b_skip, 120);
		copper_case("WAIT with VE mask $0F (V7 always compared)", b_mask, 120);
		copper_case("CDANG=0: MOVE $040 stops the copper", b_dang0, 120);
		cdang_cpu = 2;
		copper_case("CDANG=1: MOVE $040 and $020 allowed (ECS/AGA)", b_dang1, 120);
		copper_case("CDANG=1: MOVE $07E and $030 allowed on ECS/AGA", b_dang2, 120);
		cdang_cpu = 0;
		copper_case("CDANG=0: MOVE $07E stops the copper", b_dang2, 120);
		copper_case("MOVE timing: 3 MOVEs after WAIT $4001, WAIT $4041", b_vhpos, 70);
	}
	else if (test == "vhposr") t_vhposr();
	else if (test == "sprwin") {
		sprwin_case(0, 1, 0x30, 7);
		sprwin_case(0, 3, 0x30, 7);
		sprwin_case(3, 8, 0x28, 7);
		sprwin_case(3, 8, 0x18, 3);
	}
	else if (test == "nasty") { t_nasty(0); t_nasty(1); }
	else if (test == "lace") t_lace(ntsc);
	else if (test == "lastline") t_lastline();
	else if (test == "slots") t_slots(ntsc, argc > 3 ? atoi(argv[3]) : 0, argc > 4 ? strtol(argv[4], 0, 16) : 0x38);
	else { printf("unknown test\n"); return 2; }
	printf("%s: %d failure(s)\n", test.c_str(), fails);
	delete t;
	return fails ? 1 : 0;
}
