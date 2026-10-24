// POT counter bench on the real userio (pot_top.v). The HPS's analog
// joystick enable (joy_ana_en) and port-1 joystick enable (joy1enable) are
// set as the HPS and the user would: fire on port 1 with digital joysticks
// (joy1enable), then analog mode (joy_ana_en, the OSD's joystick config,
// poked through Verilator's public access).
#include "Vpot_top.h"
#include "Vpot_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vpot_top *t;
static int errors = 0;
static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
static uint16_t rd(int reg) { t->reg_addr = reg >> 1; t->eval(); uint16_t v = t->dout; tick(); t->reg_addr = 0xff; t->eval(); return v; }
static void wr(int reg, uint16_t v) { t->reg_addr = reg >> 1; t->din = v; tick(); t->reg_addr = 0xff; t->eval(); }

// POTxDAT for a stick: Y in 15-8, X in 7-0, each the stick byte b as {~b[7], b[6:0]}
static uint16_t expect(uint16_t a) { return (uint16_t)((((a & 0xFF) ^ 0x80) << 8) | (((a >> 8) & 0xFF) ^ 0x80)); }

static void run(uint16_t a1, uint16_t a2)
{
	t->joy_ana1 = a1; t->joy_ana2 = a2;
	for (int i = 0; i < 4; i++) tick();
	wr(0x034, 0x0001);                  // POTGO START
	for (int l = 0; l < 300; l++) {     // 300 scanlines
		t->line = 1; tick(); t->line = 0;
		for (int i = 0; i < 20; i++) tick();
	}
	uint16_t p0 = rd(0x012), p1 = rd(0x014);
	printf("   joy_ana1=%04x joy_ana2=%04x -> POT0DAT %04x POT1DAT %04x\n", a1, a2, p0, p1);
	// port 1 (POT0DAT) is joy_ana2, port 2 (POT1DAT) joy_ana1, unswapped
	if (p0 != expect(a2)) { printf("FAIL POT0DAT %04x, expected %04x\n", p0, expect(a2)); errors++; }
	if (p1 != expect(a1)) { printf("FAIL POT1DAT %04x, expected %04x\n", p1, expect(a1)); errors++; }
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vpot_top;
	t->joy1 = 0xffff; t->joy2 = 0xffff; t->reg_addr = 0xff;
	t->reset = 1; for (int i = 0; i < 10; i++) tick(); t->reset = 0;
	// port-1 fire (port 1 is userio's _joy2 input when unswapped): joy1enable
	t->joy2 = 0xffef; for (int i = 0; i < 4; i++) tick();
	t->joy2 = 0xffff; for (int i = 0; i < 4; i++) tick();
	t->rootp->pot_top__DOT__u__DOT__joy_ana_en = 1;
	printf("== analog joysticks: each POTxDAT should hold its own stick's position\n");
	printf("   (expected value per stick byte b: {~b[7], b[6:0]}; ajoy1 = joy_ana2, ajoy2 = joy_ana1 unswapped)\n");
	printf("   joy1enable=%d joy_ana_en=%d\n", t->rootp->pot_top__DOT__u__DOT__joy1enable, t->rootp->pot_top__DOT__u__DOT__joy_ana_en);
	run(0x0000, 0x2010);   // port-2 stick centred (80,80), port-1 stick at (+$20,+$10) -> expect POT0DAT $A090
	run(0x4030, 0x2010);
	run(0x0000, 0x0000);
	delete t;
	printf(errors ? "tb_pot: %d failures\n" : "tb_pot: each POTxDAT its own stick\n", errors);
	return errors ? 1 : 0;
}
