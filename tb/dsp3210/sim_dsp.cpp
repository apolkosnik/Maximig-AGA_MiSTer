// The DSP3210 bench's driver:
//   Vtb_dsp IMAGE [--cycles N] [--waits N] [--dump ADDR LEN] [--irq0 CYC] [--irq1 CYC] [--cmode]
// The image loads at external address 0; the run ends when the word at
// 0x000FFFF0 becomes 0x600DD0E5 (the program's done mark) or after N
// instruction cycles' worth of clocks.  --dump prints words.
#include "Vtb_dsp.h"
#include "Vtb_dsp___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

static Vtb_dsp *top;
static void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	top = new Vtb_dsp;
	const char *img = nullptr;
	long cycles = 200000;
	int waits = 1;
	std::vector<std::pair<uint32_t, uint32_t>> dumps;
	long irq0 = -1, irq1 = -1;
	bool cmode = false;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		if (a == "--cycles") cycles = atol(argv[++i]);
		else if (a == "--waits") waits = atoi(argv[++i]);
		else if (a == "--dump") { uint32_t ad = strtoul(argv[i + 1], 0, 0), n = strtoul(argv[i + 2], 0, 0); dumps.push_back({ad, n}); i += 2; }
		else if (a == "--irq0") irq0 = atol(argv[++i]);
		else if (a == "--irq1") irq1 = atol(argv[++i]);
		else if (a == "--cmode") cmode = true;
		else img = argv[i];
	}
	if (!img) { fprintf(stderr, "usage: %s IMAGE [options]\n", argv[0]); return 2; }
	auto *r = top->rootp;
	FILE *f = fopen(img, "rb");
	if (!f) { perror(img); return 2; }
	std::vector<uint8_t> b(1 << 20);
	size_t n = fread(b.data(), 1, b.size(), f);
	fclose(f);
	for (size_t i = 0; i < n; i += 4)
		r->tb_dsp__DOT__mem[i >> 2] = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
	top->waits = waits;
	top->ir0_n = 1; top->ir1_n = 1;
	top->bio_in = cmode ? 0xC0 : 0x40;          // bio7: Computer mode; bio6 high (R/WN)
	top->ce = 1;
	top->reset = 1;
	for (int i = 0; i < 16; i++) tick();
	top->reset = 0;
	long retired = 0, t;
	for (t = 0; t < cycles * 4; t++) {
		tick();
		if (top->retire) retired++;
		long ic = t / 4;
		top->ir0_n = !(irq0 >= 0 && ic >= irq0 && ic < irq0 + 4);
		top->ir1_n = !(irq1 >= 0 && ic >= irq1 && ic < irq1 + 4);
		if (r->tb_dsp__DOT__mem[0xFFFF0 >> 2] == 0x600DD0E5u) break;
		if (top->halted) { printf("[dsp] halted (double error) at %ld\n", t); break; }
		if (Verilated::gotFinish()) { printf("[dsp] $finish at %ld\n", t); return 1; }   // (a failed check)
	}
	printf("[dsp] end after %ld clocks, %ld instructions retired, pc %08X%s\n", t, retired, top->pc,
	       r->tb_dsp__DOT__mem[0xFFFF0 >> 2] == 0x600DD0E5u ? ", done" : "");
	for (auto &d : dumps)
		for (uint32_t a = d.first; a < d.first + d.second; a += 4)
			printf("%08X %08X\n", a, r->tb_dsp__DOT__mem[(a & 0xFFFFF) >> 2]);
	delete top;
	return 0;
}
