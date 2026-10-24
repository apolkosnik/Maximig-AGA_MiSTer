// Audio DMA bench on the real paula + agnus_audiodma (paula_top.v).
// Prints every channel-0 DMA fetch (word, pointer-restart flag), every AUD0
// interrupt request, and the sample bytes played, for several AUD0LEN values,
// and checks that every block between pointer restarts is AUD0LEN words: the
// first one too (WinUAE audio.cpp: the length counts at state 1's word, not
// at state 5's).  (After an audit's bench, 2026-10-24.)
#include "Vpaula_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vpaula_top *t;
static uint64_t cyc = 0;

static bool logon = false;
static uint64_t t0 = 0;
static int nf = 0, prev_irq = 0, prev_sample = -1;
static std::vector<uint16_t> played;
static std::vector<int> blocks;      // fetches between pointer restarts
static int cur = 0, errors = 0;
static void logcycle()
{
	if (t->dma && t->hpos_o == 0x25) {
		printf("  fetch %2d cck %6llu: addr %05x data %04x%s\n", nf,
		       (unsigned long long)((cyc - t0) / 2), t->dma_addr << 1, t->dma_data,
		       (t->dmas_o & 1) ? "  [DMAS: pointer restart]" : "");
		nf++;
		cur++;
		if (t->dmas_o & 1) { blocks.push_back(cur); cur = 0; }
	}
	int irq = (t->intreq_o >> 7) & 1;
	if (irq && !prev_irq)
		printf("  AUD0 IRQ   cck %6llu (lencnt %u)\n", (unsigned long long)((cyc - t0) / 2), t->lencnt0);
	prev_irq = irq;
	if (t->sample0 != prev_sample) {
		played.push_back(t->sample0);
		prev_sample = t->sample0;
	}
}
static void tick()
{
	t->eval();
	if (logon) logcycle();
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

static uint16_t rd(uint32_t reg)
{
	t->cpu_reg = reg >> 1; t->eval();
	uint16_t v = t->rd_data;
	tick();
	t->cpu_reg = 0x1fe >> 1;
	t->eval();
	return v;
}

static void reset()
{
	t->reset = 1; t->cpu_reg = 0x1fe >> 1; t->rxd = 1;
	for (int i = 0; i < 20; i++) tick();
	t->reset = 0;
	for (int i = 0; i < 10; i++) tick();
}

// run one case: len words at word address 0x1000, ack each IRQ like a CPU
static void run_case(uint16_t len, uint16_t per, int lines, bool ack)
{
	reset();
	for (uint32_t a = 0; a < 0x40; a++) ramw(a, 0xDE00 | a);
	for (uint32_t i = 0; i < 0x200; i++) ramw(0x1000 + i, 0xA000 + i);
	wr(0x0a0, 0x0000);      // AUD0LCH
	wr(0x0a2, 0x2000);      // AUD0LCL (word 0x1000)
	wr(0x0a4, len);         // AUD0LEN
	wr(0x0a6, per);         // AUD0PER
	wr(0x0a8, 64);          // AUD0VOL
	wr(0x09a, 0xc080);      // INTENA AUD0
	wr(0x09c, 0x7fff);      // clear INTREQ
	printf("== AUD0LEN=%u AUD0PER=%u\n", len, per);
	wr(0x096, 0x8201);      // DMACON SET DMAEN|AUD0EN
	t0 = cyc; nf = 0; prev_irq = 0; prev_sample = -1; played.clear(); blocks.clear(); cur = 0;
	logon = true;
	uint64_t end = cyc + (uint64_t)lines * 454;
	uint64_t ackat = 0;
	while (cyc < end) {
		t->eval();
		if (((t->intreq_o >> 7) & 1) && ack && !ackat)
			ackat = cyc + 200;   // acknowledge 100 CCKs later, as a handler would
		if (ackat && cyc >= ackat) {
			wr(0x09c, 0x0080);
			ackat = 0;
			continue;
		}
		tick();
	}
	logon = false;
	printf("  sample bytes played (changes): ");
	for (size_t i = 0; i < played.size() && i < 40; i++) printf("%02x ", played[i]);
	printf("\n  silence=%d\n", t->silence0);
	// the first fetch after DMA on restarts the pointer (its word only loads
	// it): the blocks are counted from there
	if (len != 0) {
		if (blocks.size() < 3) { printf("FAIL AUD0LEN=%u: %zu blocks\n", len, blocks.size()); errors++; }
		for (size_t i = 1; i < blocks.size(); i++)
			if (blocks[i] != len) { printf("FAIL AUD0LEN=%u: block %zu is %d words\n", len, i, blocks[i]); errors++; }
	}
	wr(0x096, 0x0001);
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vpaula_top;
	run_case(4, 300, 20, true);
	run_case(2, 300, 12, true);
	run_case(1, 300, 10, true);
	run_case(0, 300, 10, false);
	delete t;
	printf(errors ? "tb_audio: %d failures\n" : "tb_audio: every block AUD0LEN words\n", errors);
	return errors ? 1 : 0;
}
