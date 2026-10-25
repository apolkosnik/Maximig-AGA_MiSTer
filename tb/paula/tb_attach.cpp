// Audio attachment on the real paula + agnus_audiodma (paula_top.v): channel 0
// playing by DMA with ADKCON ATVOL0, ATPER0 or both.  Its words become
// channel 1's AUD1VOL / AUD1PER in order (both: volume and period by turns,
// HRM chapter 5, WinUAE audio.cpp loaddat), channel 0's own output is silent,
// and its DMA fetches come once per sample pair (one word each), or once per
// sample with both (two words).  Without attachment channel 0 plays and
// channel 1's registers are as written.  (After an audit's probe,
// 2026-10-25: ADKCON 7-0 latched and read back and did nothing.)
#include "Vpaula_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vpaula_top *t;
static uint64_t cyc = 0;
static int errors = 0;

static void tick()
{
	t->eval();
	t->clk = 0; t->eval();
	t->clk = 1; t->eval();
	cyc++;
}

static void ramw(uint32_t waddr, uint16_t v)
{
	t->ram_we = 1; t->ram_waddr = waddr; t->ram_wdata = v;
	tick();
	t->ram_we = 0;
}

// a CPU register write: on a cycle that is not an audio DMA slot
static void wr(uint32_t reg, uint16_t v)
{
	for (;;) {
		t->cpu_reg = reg >> 1; t->cpu_data = v; t->eval();
		if (!t->dma) break;
		t->cpu_reg = 0x1fe >> 1; tick();
	}
	tick();
	t->cpu_reg = 0x1fe >> 1;
	t->eval();
}

static void reset()
{
	t->reset = 1; t->cpu_reg = 0x1fe >> 1; t->rxd = 1;
	for (int i = 0; i < 20; i++) tick();
	t->reset = 0;
	for (int i = 0; i < 10; i++) tick();
}

static void check(bool ok, const char *what)
{
	printf("%s %s\n", ok ? "PASS" : "FAIL", what);
	if (!ok) errors++;
}

// the values a register took, in order, from the second (the first may be
// the word that only restarts the pointer): each base + step * n, n rising by
// one, at least min of them
static bool consecutive(const std::vector<int> &v, int step, size_t min)
{
	if (v.size() < min) return false;
	for (size_t i = 1; i < v.size(); i++)
		if (v[i] - v[i - 1] != step) return false;
	return true;
}

static void print(const char *name, const std::vector<int> &v)
{
	printf("  %s:", name);
	for (size_t i = 0; i < v.size() && i < 16; i++) printf(" %d", v[i]);
	printf("%s\n", v.size() > 16 ? " ..." : "");
}

// adk: ADKCON bits for channel 0; words: the table at word 0x1000
static void run_case(const char *name, uint16_t adk, const std::vector<uint16_t> &words, int per, int lines,
                     int exp_fetch_cck, bool exp_vol, bool exp_per, int vol_step, int per_step)
{
	reset();
	for (uint32_t i = 0; i < words.size(); i++) ramw(0x1000 + i, words[i]);
	wr(0x0a0, 0x0000);                    // AUD0LCH
	wr(0x0a2, 0x2000);                    // AUD0LCL (word 0x1000)
	wr(0x0a4, (uint16_t)words.size());    // AUD0LEN
	wr(0x0a6, per);                       // AUD0PER
	wr(0x0a8, 64);                        // AUD0VOL
	wr(0x0b6, 1000);                      // AUD1PER, AUD1VOL as written
	wr(0x0b8, 0x22);
	wr(0x09e, 0x00ff);                    // ADKCON: clear the attachment bits
	if (adk) wr(0x09e, 0x8000 | adk);
	printf("== %s (ADKCON %02X, AUD0PER %d)\n", name, adk, per);
	wr(0x096, 0x8201);                    // DMACON SET DMAEN|AUD0EN

	std::vector<int> vols, pers, fetch;
	int pv = t->vol1, pp = t->per1, nz = 0;
	uint64_t t0 = cyc, end = cyc + (uint64_t)lines * 454;
	while (cyc < end) {
		t->eval();
		if (t->dma && t->hpos_o == 0x25) fetch.push_back((int)((cyc - t0) / 2));
		if (t->sample0) nz++;
		if (t->vol1 != pv) { pv = t->vol1; vols.push_back(pv); }
		if (t->per1 != pp) { pp = t->per1; pers.push_back(pp); }
		tick();
	}
	wr(0x096, 0x0001);
	print("AUD1VOL loads", vols);
	print("AUD1PER loads", pers);
	// fetches after the first two (pointer restart, first word)
	double avg = fetch.size() > 4 ? (double)(fetch.back() - fetch[2]) / (fetch.size() - 3) : 0;
	printf("  %zu fetches, %.1f CCKs apart; channel 0's sample non-zero for %d clocks\n", fetch.size(), avg, nz);

	char b[160];
	snprintf(b, sizeof b, "%s: channel 0 fetches every %d CCKs (%.1f)", name, exp_fetch_cck, avg);
	check(avg > exp_fetch_cck * 0.97 && avg < exp_fetch_cck * 1.03, b);
	if (adk) {
		snprintf(b, sizeof b, "%s: channel 0 silent", name);
		check(nz == 0, b);
	} else {
		snprintf(b, sizeof b, "%s: channel 0 plays", name);
		check(nz > 0, b);
	}
	snprintf(b, sizeof b, "%s: AUD1VOL %s", name, exp_vol ? "takes channel 0's words in order" : "as written");
	check(exp_vol ? consecutive(vols, vol_step, 6) : vols.empty() && t->vol1 == 0x22, b);
	snprintf(b, sizeof b, "%s: AUD1PER %s", name, exp_per ? "takes channel 0's words in order" : "as written");
	check(exp_per ? consecutive(pers, per_step, 6) : pers.empty() && t->per1 == 1000, b);
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vpaula_top;
	const int per = 300;
	std::vector<uint16_t> vol, prd, both, snd;
	for (int i = 0; i < 64; i++) {
		vol.push_back(i);                 // volumes 0..63
		prd.push_back(400 + 8 * i);       // periods
		both.push_back((i & 1) ? 500 + 4 * (i >> 1) : (i >> 1));   // volume, period, volume, ...
		snd.push_back(0x4080 + i);
	}
	run_case("no attachment", 0x00, snd, per, 40, 2 * per, false, false, 0, 0);
	run_case("ATVOL0", 0x01, vol, per, 40, 2 * per, true, false, 1, 0);
	run_case("ATPER0", 0x10, prd, per, 40, 2 * per, false, true, 0, 8);
	run_case("ATVOL0+ATPER0", 0x11, both, per, 40, per, true, true, 1, 4);
	delete t;
	printf(errors ? "tb_attach: %d failures\n" : "tb_attach: PASS\n", errors);
	return errors ? 1 : 0;
}
