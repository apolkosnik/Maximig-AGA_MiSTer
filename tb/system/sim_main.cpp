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
//     --hdf FILE        a hard disk image on IDE channel 0's master (the A4000
//                       port; the AA3000+'s SCSI ID 0), served as Main does;
//                       --hdf1 its slave (SCSI ID 1), --hdf2 channel 1's master
//                       (the AA3000+'s A4000 IDE port); --idetrace logs the commands
//     --exctrace        print every exception the CPU takes: vector, the PC
//                       and SR it stacks
//     --iostat          bus beats per region every 100 ms
//     --customtrace     print writes to DMACON, COP1LC/2LC, COPJMP, BPLCON0, INTENA,
//                       INTREQ, COLOR00
//     --dumpchip MS FILE write the 2 MB of chip RAM to FILE at MS milliseconds
//     --dumpsd OFF LEN FILE  at the end, LEN bytes of the SDRAM from byte OFF
//                       (motherboard RAM $07xxxxxx is at 0x1000000 + A23-A0)
//                       (MS "end": when the run ends)
//     --cart FILE       upload FILE at $A10000 through Main's UIO_MM2_WR
//                       protocol (HRTmon is enabled in the config)
//     --ddrpeek ADDR    at the end, print the long word at DDR3 physical ADDR
//     --ddrdump ADDR LEN FILE  at the end, LEN bytes of DDR3 from physical ADDR
//                       to FILE, as the ARM reads them (memdump's format)
//     --extrom FILE     upload FILE at $E00000 as Main does (the core then shows
//                       it at $F00000 too)
//     --cart-config     after --cart, write HRTmon's configuration as Main does
//     --ar FILE         the cartridge is the Action Replay (Main's ext_cfg bit
//                       21, status[53]): upload FILE (AR5.ROM, up to 512 KB)
//                       at $A80000 as Main does
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
//   window check; 4: the bench presses the HRTmon key, Help, $5F; 5: the
//   next complete frame's dominant colour goes to chip RAM $1F10; 6: line
//   150's first and last non-black 35 ns samples and their count, $1F20).
#include "Vtb_top.h"
#include "Vtb_top__Dpi.h"
#include "verilated.h"
#include "svdpi.h"
#if VM_TRACE
#include "verilated_fst_c.h"
#endif
#include <cstdio>
#include <map>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <ucontext.h>
#include "../../hps/maximig_scsi_target.h"

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
// Main's IDE service (support/minimig ide handling): hard disk images on the
// IDE channels' drives, through ide.v's management port as Main drives it
// (the status word in register 5: bits 15/14/12/11/8 the status's BSY,
// DRDY, DSC, DRQ, ERR, 13 fast read, 10 the interrupt, 9 the last block,
// 7-0 the drive register; register 0: the error byte and the block size;
// register 6: the drives present; register 15: the data, streamed).
// The image's word order is the ARM's: a word holds its first byte low.
//----------------------------------------------------------------------------
struct Hdf {
	FILE *f = nullptr;
	uint32_t sectors = 0;
	uint16_t cyl = 0, heads = 16, spt = 63;
};
static Hdf hdf[4];                      // channel 0 master/slave, channel 1 master/slave
struct IdeCmd {
	bool active = false;
	uint8_t cmd = 0, drv = 0;
	uint32_t lba = 0, left = 0;
};
static IdeCmd ide_cmd[2];
static bool ide_trace = false;

static void mgmt_wr(int ch, int a, uint16_t d)
{
	top->ide_mgmt_addr = (ch << 4) | a;
	top->ide_mgmt_wdata = d;
	top->ide_mgmt_wr = 1;
	idle_sys(1);
	top->ide_mgmt_wr = 0;
	idle_sys(1);
}
static uint16_t mgmt_rd(int ch, int a)
{
	top->ide_mgmt_addr = (ch << 4) | a;
	idle_sys(2);
	uint16_t v = top->ide_mgmt_rdata;
	top->ide_mgmt_rd = 1;
	idle_sys(1);
	top->ide_mgmt_rd = 0;
	idle_sys(1);
	return v;
}

static bool hdf_open(int n, const char *path)
{
	Hdf &h = hdf[n];
	h.f = fopen(path, "r+b");
	if (!h.f) { fprintf(stderr, "cannot open %s\n", path); return false; }
	fseek(h.f, 0, SEEK_END);
	h.sectors = (uint32_t)(ftell(h.f) / 512);
	h.heads = 16; h.spt = 63;
	uint32_t c = h.sectors / (16 * 63);
	h.cyl = c > 16383 ? 16383 : c;
	printf("[ide] drive %d: %s, %u sectors\n", n, path, h.sectors);
	return true;
}

static void put_str(uint16_t *w, const char *s, int words)
{
	for (int i = 0; i < words; i++) {
		char a = *s ? *s++ : ' ', b = *s ? *s++ : ' ';
		w[i] = (uint16_t)((a << 8) | (uint8_t)b);
	}
}

static void ide_present()
{
	for (int ch = 0; ch < 2; ch++) {
		uint16_t v = 0;
		if (hdf[ch * 2].f)     v |= 0x0009;
		if (hdf[ch * 2 + 1].f) v |= 0x0090;
		if (v) { mgmt_wr(ch, 6, v); mgmt_wr(ch, 5, 0x50A0); }
	}
}

// one block (a sector) to the drive's buffer, and the status that announces it
static void ide_load_sector(int ch, Hdf &h, uint32_t lba, bool last, uint8_t drv)
{
	uint8_t b[512];
	memset(b, 0, sizeof b);
	if (lba < h.sectors) { fseek(h.f, (long)lba * 512, SEEK_SET); fread(b, 1, 512, h.f); }
	top->ide_mgmt_addr = (ch << 4) | 15;
	for (int i = 0; i < 512; i += 2) {
		top->ide_mgmt_wdata = (uint16_t)(b[i] | (b[i + 1] << 8));
		top->ide_mgmt_wr = 1;
		idle_sys(1);
		top->ide_mgmt_wr = 0;
		idle_sys(1);
	}
	mgmt_wr(ch, 0, 1);
	mgmt_wr(ch, 5, (last ? 0x5E00 : 0x5C00) | drv);
}

//----------------------------------------------------------------------------
// Main's SCSI service for the AA3000+ (a3kp_scsi_hps on IDE channel 0,
// request codes 1-3): Main's own command code, hps/maximig_scsi_target.h,
// run as a coroutine beside the machine -- each register access and each
// wait for a request yields to the main loop, which goes on ticking (and
// watching the mailbox) and resumes it after so many clk_sys cycles or once
// the core requests
//----------------------------------------------------------------------------
static ucontext_t co_main, co_scsi;
static std::vector<char> co_stack(1 << 20);
static bool     co_active = false;       // a command is being served
static bool     co_wait_req = false;     // ... waiting for the core's request
static uint64_t co_until = 0;            // ... else sleeping until this clk_sys cycle
static uint64_t sys_cycles = 0;          // the main loop's clk_sys cycles
static scsi_target co_t;

static void co_sleep(int n)
{
	co_until = sys_cycles + n;
	swapcontext(&co_scsi, &co_main);
}
static void co_mgmt_wr(int a, uint16_t d)
{
	top->ide_mgmt_addr = a; top->ide_mgmt_wdata = d; top->ide_mgmt_wr = 1;
	co_sleep(1);
	top->ide_mgmt_wr = 0;
	co_sleep(1);
}
static uint16_t co_mgmt_rd(int a)
{
	top->ide_mgmt_addr = a;
	co_sleep(2);
	uint16_t v = top->ide_mgmt_rdata;
	top->ide_mgmt_rd = 1;
	co_sleep(1);
	top->ide_mgmt_rd = 0;
	co_sleep(1);
	return v;
}
static void sio_wr(void *, int reg, uint16_t v) { co_mgmt_wr(reg, v); }
static void sio_rdregs(void *, uint16_t *v, int n) { for (int i = 0; i < n; i++) v[i] = co_mgmt_rd(i); }
static void sio_wrbuf(void *, const uint16_t *w, int n) { for (int i = 0; i < n; i++) co_mgmt_wr(15, w[i]); }
static void sio_rdbuf(void *, uint16_t *w, int n) { for (int i = 0; i < n; i++) w[i] = co_mgmt_rd(15); }
static int sio_wait(void *)
{
	co_wait_req = true;
	swapcontext(&co_scsi, &co_main);
	co_wait_req = false;
	return top->ide_req & 7;
}
static int sdisk_read(void *ctx, uint32_t lba, uint8_t *b, uint32_t cnt)
{
	Hdf &h = *(Hdf *)ctx;
	if (ide_trace) printf("[scsi] %.4f ms read %u count %u\n", sim_ms(), lba, cnt);
	fseek(h.f, (long)lba * 512, SEEK_SET);
	return fread(b, 512, cnt, h.f) == cnt;
}
static int sdisk_write(void *ctx, uint32_t lba, const uint8_t *b, uint32_t cnt)
{
	Hdf &h = *(Hdf *)ctx;
	if (ide_trace) printf("[scsi] %.4f ms write %u count %u\n", sim_ms(), lba, cnt);
	fseek(h.f, (long)lba * 512, SEEK_SET);
	int ok = fwrite(b, 512, cnt, h.f) == cnt;
	fflush(h.f);
	return ok;
}
static void co_entry()
{
	scsi_io io = { nullptr, sio_wr, sio_rdregs, sio_wrbuf, sio_rdbuf, sio_wait };
	scsi_disk d[2];
	for (int i = 0; i < 2; i++) {
		Hdf &h = hdf[i];
		d[i] = { &h, h.f != nullptr, h.sectors, h.cyl, h.heads, h.spt, sdisk_read, sdisk_write };
	}
	if (ide_trace) printf("[scsi] %.4f ms command\n", sim_ms());
	scsi_command(&co_t, &io, d);
	co_active = false;
	swapcontext(&co_scsi, &co_main);
}

// each clk_sys cycle of the main loop: start or resume the service
static void scsi_service()
{
	sys_cycles++;
	uint8_t r = top->ide_req & 7;
	if (!co_active) {
		if (r != SCSI_RQ_CMD) return;
		getcontext(&co_scsi);
		co_scsi.uc_stack.ss_sp = co_stack.data();
		co_scsi.uc_stack.ss_size = co_stack.size();
		co_scsi.uc_link = nullptr;
		makecontext(&co_scsi, co_entry, 0);
		co_active = true;
		co_wait_req = false;
		swapcontext(&co_main, &co_scsi);
	}
	else if (co_wait_req ? (r >= SCSI_RQ_CMD && r <= SCSI_RQ_DIN) : (sys_cycles >= co_until))
		swapcontext(&co_main, &co_scsi);
}

static void ide_service()
{
	uint8_t req = top->ide_req;
	for (int ch = 0; ch < 2; ch++) {
		uint8_t r = (req >> (ch * 3)) & 7;
		if (r == 0 || (r >= SCSI_RQ_CMD && r <= SCSI_RQ_DIN)) continue;   // (the SCSI service's)
		IdeCmd &c = ide_cmd[ch];
		if (r == 6) {
			// a reset: ready
			c.active = false;
			mgmt_wr(ch, 5, 0x50A0);
			continue;
		}
		if (r == 4) {
			uint16_t r1 = mgmt_rd(ch, 1), r2 = mgmt_rd(ch, 2), r5 = mgmt_rd(ch, 5);
			c.cmd = r5 >> 8; c.drv = r5 & 0xFF;
			Hdf &h = hdf[ch * 2 + ((c.drv >> 4) & 1)];
			uint32_t cnt = r1 & 0xFF;
			c.lba = ((uint32_t)(c.drv & 0x0F) << 24) | ((uint32_t)r2 << 8) | (r1 >> 8);
			c.left = cnt ? cnt : 256;
			if (ide_trace) printf("[ide] %.4f ms ch %d drv %02X cmd %02X lba %u count %u\n", sim_ms(), ch, c.drv, c.cmd, c.lba, c.left);
			if (!h.f) { mgmt_wr(ch, 0, 0x0400); mgmt_wr(ch, 5, 0x5500 | c.drv); continue; }
			if (c.cmd == 0xEC) {
				uint16_t w[256];
				memset(w, 0, sizeof w);
				w[0] = 0x0040; w[1] = h.cyl; w[3] = h.heads; w[6] = h.spt;
				put_str(w + 10, "MISTER0001", 10); put_str(w + 23, "1.0", 4); put_str(w + 27, "MiSTer HDF", 20);
				w[47] = 0x8010; w[49] = 0x0200; w[53] = 0x0001;
				w[54] = h.cyl; w[55] = h.heads; w[56] = h.spt;
				uint32_t chs = (uint32_t)h.cyl * h.heads * h.spt;
				w[57] = chs & 0xFFFF; w[58] = chs >> 16;
				w[60] = h.sectors & 0xFFFF; w[61] = h.sectors >> 16;
				top->ide_mgmt_addr = (ch << 4) | 15;
				for (int i = 0; i < 256; i++) {
					top->ide_mgmt_wdata = w[i];
					top->ide_mgmt_wr = 1; idle_sys(1); top->ide_mgmt_wr = 0; idle_sys(1);
				}
				mgmt_wr(ch, 0, 1);
				mgmt_wr(ch, 5, 0x5E00 | c.drv);
			}
			else if (c.cmd == 0x20 || c.cmd == 0x21) {
				c.active = true;
				c.left--;
				ide_load_sector(ch, h, c.lba++, c.left == 0, c.drv);
			}
			else if (c.cmd == 0x30 || c.cmd == 0x31) {
				c.active = true;
				mgmt_wr(ch, 0, 1);
				mgmt_wr(ch, 5, 0x5800 | c.drv);           // DRQ: the first block
			}
			else mgmt_wr(ch, 5, 0x5400 | c.drv);         // done (INITIALIZE, SET MULTIPLE, FLUSH, ...)
			continue;
		}
		if (r == 5 && c.active) {
			Hdf &h = hdf[ch * 2 + ((c.drv >> 4) & 1)];
			if (c.cmd == 0x20 || c.cmd == 0x21) {
				if (c.left == 0) { c.active = false; mgmt_wr(ch, 5, 0x5000 | c.drv); continue; }
				c.left--;
				ide_load_sector(ch, h, c.lba++, c.left == 0, c.drv);
			}
			else {
				// a written block: the data back from the buffer
				uint8_t b[512];
				mgmt_rd(ch, 5);                           // (the cursor back to the buffer's start)
				for (int i = 0; i < 512; i += 2) {
					uint16_t v = mgmt_rd(ch, 15);
					b[i] = v & 0xFF; b[i + 1] = v >> 8;
				}
				if (c.lba < h.sectors) { fseek(h.f, (long)c.lba * 512, SEEK_SET); fwrite(b, 1, 512, h.f); fflush(h.f); }
				c.lba++;
				if (--c.left == 0) { c.active = false; mgmt_wr(ch, 5, 0x5400 | c.drv); }
				else { mgmt_wr(ch, 0, 1); mgmt_wr(ch, 5, 0x5C00 | c.drv); }
			}
		}
	}
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
	// through userio with the CPU halted, as Main's UploadKickstartWithExtRom
	// does: the chipset marks the extension ROM loaded (shown at $F00000 too)
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
	std::vector<uint8_t> b(0x80000, 0);
	size_t n = fread(b.data(), 1, b.size(), f);
	fclose(f);
	for (uint32_t i = 0; i < n; i += 512) {
		uint32_t a = 0xE00000 + i;
		std::vector<uint8_t> cmd = {0xF0, (uint8_t)a, (uint8_t)(a >> 8), (uint8_t)(a >> 16), 0};
		for (uint32_t k = 0; k < 512; k++) cmd.push_back(i + k < n ? b[i + k] : 0);
		uio_cmd(cmd);
	}
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

// AR5.ROM: the ROM ($A80000) and the RAM image ($AC0000), as Main uploads it
static bool load_ar(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
	std::vector<uint8_t> b(0x80000);
	size_t n = fread(b.data(), 1, b.size(), f);
	fclose(f);
	for (uint32_t i = 0; i < n; i += 512) {
		uint32_t a = 0xA80000 + i;
		std::vector<uint8_t> cmd = {0xF0, (uint8_t)a, (uint8_t)(a >> 8), (uint8_t)(a >> 16), 0};
		for (uint32_t j = 0; j < 512; j++) cmd.push_back(i + j < n ? b[i + j] : 0);
		uio_cmd(cmd);
	}
	return true;
}

static void dump_sd(const char *path, uint32_t off, uint32_t len)
{
	FILE *f = fopen(path, "wb");
	if (!f) { fprintf(stderr, "cannot open %s\n", path); return; }
	sdram_scope();
	for (uint32_t w = off / 2; w < (off + len) / 2; w++) {
		uint32_t v = sdram_peek16(w);
		fputc((v >> 8) & 0xFF, f);
		fputc(v & 0xFF, f);
	}
	fclose(f);
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
	int colour_req = 0;   // frames until the dominant-colour report (mark 5)
	// mark 6: on line EDGE_Y of the next complete frame, the first and the
	// last non-black sample and how many, at every sample (35 ns, not xscale)
	static const int EDGE_Y = 150;
	int edge_req = 0, xs = 0, e_first = -1, e_last = -1, e_count = 0;

	void sample()
	{
		bool hs = top->hs_n, vs = top->vs_n;
		if (old_vs && !vs) {
			if (!dir.empty() && (frame % every) == 0) write();
			if (colour_req > 0 && --colour_req == 0) report_colour();
			if (edge_req == 1) { report_edge(); edge_req = 0; }
			else if (edge_req == 2) { edge_req = 1; e_first = e_last = -1; e_count = 0; }
			frame++;
			y = 0;
		}
		if (old_hs && !hs) { if (x > maxx) maxx = x; x = 0; y++; sub = 0; xs = 0; }
		old_hs = hs; old_vs = vs;
		if (edge_req == 1 && y == EDGE_Y) {
			if (top->red || top->green || top->blue) {
				if (e_first < 0) e_first = xs;
				e_last = xs;
				e_count++;
			}
		}
		xs++;
		if (++sub < xscale) return;
		sub = 0;
		if (x < W && y < H) {
			uint8_t *p = &buf[(y * W + x) * 3];
			p[0] = top->red; p[1] = top->green; p[2] = top->blue;
		}
		x++;
	}
	// the frame's most frequent colour other than black, for t_chipset: at
	// chip RAM $1F10 its red, $1F12 green and blue, $1F16 its sample count
	// (long), $1F14 $AA55 (done)
	void report_colour()
	{
		std::map<uint32_t, int> n;
		for (int yy = 0; yy < H; yy++)
			for (int xx = 0; xx < maxx && xx < W; xx++) {
				uint8_t *p = &buf[(yy * W + xx) * 3];
				uint32_t c = (p[0] << 16) | (p[1] << 8) | p[2];
				if (c) n[c]++;
			}
		uint32_t best = 0; int bn = 0;
		for (auto &kv : n) if (kv.second > bn) { bn = kv.second; best = kv.first; }
		printf("[video] dominant colour %06X (%d samples)\n", best, bn);
		sdram_scope();
		sdram_poke16(0x1F10 >> 1, best >> 16);
		sdram_poke16(0x1F12 >> 1, best & 0xFFFF);
		sdram_poke16(0x1F16 >> 1, (uint32_t)bn >> 16);   // its sample count
		sdram_poke16(0x1F18 >> 1, (uint32_t)bn & 0xFFFF);
		sdram_poke16(0x1F14 >> 1, 0xAA55);
	}
	// mark 6's report: chip RAM $1F20 the first sample, $1F22 the last,
	// $1F24 the count, $1F26 $AA55 (done)
	void report_edge()
	{
		printf("[video] line %d: first %d last %d count %d\n", EDGE_Y, e_first, e_last, e_count);
		sdram_scope();
		sdram_poke16(0x1F20 >> 1, (uint16_t)e_first);
		sdram_poke16(0x1F22 >> 1, (uint16_t)e_last);
		sdram_poke16(0x1F24 >> 1, (uint16_t)e_count);
		sdram_poke16(0x1F26 >> 1, 0xAA55);
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
	bool dump_end = false;
	const char *dump_file = nullptr, *cart = nullptr;
	const char *dsd_file = nullptr;
	uint32_t dsd_off = 0, dsd_len = 0;
	bool cart_config = false;
	const char *extrom = nullptr, *arrom = nullptr;
	std::vector<uint32_t> ddrpeek;
	uint32_t ddd_addr = 0, ddd_len = 0;
	const char *ddd_file = nullptr;
	long pctrace = 0;
	bool exctrace = false;
	int mainreset = -1;
	const char *mouse_file = nullptr;  // timed mouse events: "MS DX DY BUTTONS" a line
	bool bfg = false;            // the BFG9060 card in place of the A3640          // mark 7: Main's reset, the machine running for this many clk_sys cycles halted
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
		else if (a == "--exctrace") exctrace = true;
		else if (a == "--quiet") quiet = true;
		else if (a == "--iostat") iostat = true;
		else if (a == "--customtrace") customtrace = true;
		else if (a == "--dumpsd") { dsd_off = strtoul(next(), nullptr, 0); dsd_len = strtoul(next(), nullptr, 0); dsd_file = next(); }
		else if (a == "--dumpchip") { const char *t = next(); dump_end = !strcmp(t, "end"); dump_ms = dump_end ? -1 : atof(t); dump_file = next(); }
		else if (a == "--cart") cart = next();
		else if (a == "--cart-config") cart_config = true;
		else if (a == "--extrom") extrom = next();
		else if (a == "--ar") arrom = next();
		else if (a == "--ddrpeek") ddrpeek.push_back((uint32_t)strtoul(next(), nullptr, 0));
		else if (a == "--ddrdump") { ddd_addr = strtoul(next(), nullptr, 0); ddd_len = strtoul(next(), nullptr, 0); ddd_file = next(); }
		else if (a == "--freeze-ms") freeze_ms = atof(next());
		else if (a == "--mainreset") mainreset = atoi(next());
		else if (a == "--bfg") bfg = true;
		else if (a == "--mouse") mouse_file = next();
		else if (a == "--hdf")  { if (!hdf_open(0, next())) return 2; }
		else if (a == "--hdf1") { if (!hdf_open(1, next())) return 2; }
		else if (a == "--hdf2") { if (!hdf_open(2, next())) return 2; }
		else if (a == "--idetrace") ide_trace = true;
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
	top->mouse_buttons = 0;
	top->ide_mgmt_addr = 0; top->ide_mgmt_rd = 0; top->ide_mgmt_wr = 0; top->ide_mgmt_wdata = 0;
	top->cart_ar = arrom != nullptr;
	top->card_bfg = bfg;
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
	if (arrom && !load_ar(arrom)) return 2;
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
	ide_present();

	// the mouse as Main sends it (UIO_MOUSE): a movement is X counts (type 0)
	// and Y counts (type 1), each a signed byte with the level toggled; the
	// buttons as they are.  The script's moves go out a chunk at a time.
	struct MouseEv { double ms; int dx, dy, btn; };
	std::vector<MouseEv> mev;
	if (mouse_file) {
		FILE *mf = fopen(mouse_file, "r");
		if (!mf) { perror(mouse_file); return 2; }
		MouseEv e;
		while (fscanf(mf, "%lf %d %d %d", &e.ms, &e.dx, &e.dy, &e.btn) == 4) mev.push_back(e);
		fclose(mf);
	}
	size_t mev_i = 0;
	std::vector<std::pair<int, int>> mq;      // (type, count) to send
	uint64_t mq_next = 0;

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
		if (mev_i < mev.size() && sim_ms() >= mev[mev_i].ms) {
			const MouseEv &e = mev[mev_i++];
			// (a packet is X then Y: userio takes a Y that follows a Y as the wheel)
			for (int dx = e.dx, dy = e.dy; dx != 0 || dy != 0; ) {
				int cx = dx > 100 ? 100 : dx < -100 ? -100 : dx;
				int cy = dy > 100 ? 100 : dy < -100 ? -100 : dy;
				mq.push_back({0, cx});
				mq.push_back({1, cy});
				dx -= cx; dy -= cy;
			}
			top->mouse_buttons = e.btn;
			printf("[mouse] %.3f ms move %d,%d buttons %d\n", sim_ms(), e.dx, e.dy, e.btn); fflush(stdout);
		}
		if (!mq.empty() && halfstep >= mq_next && !key_step) {
			top->kbd_mouse_type = mq.front().first;
			top->kbd_mouse_data = (uint8_t)(int8_t)mq.front().second;
			top->kbd_mouse_level ^= 1;
			mq.erase(mq.begin());
			mq_next = halfstep + 4000;
		}
		// a key as Main sends one: type 2 (keyboard), the code, the level toggled
		if (key_at && key_step == 0 && halfstep >= key_at) {
			top->kbd_mouse_type = 2; top->kbd_mouse_data = 0x5F; top->kbd_mouse_level ^= 1; key_step = 1;
		}
		else if (key_step == 1 && halfstep >= key_at + (uint64_t)(0.0002 * 2.0 * CLK114_HZ)) {
			top->kbd_mouse_data = 0xDF; top->kbd_mouse_level ^= 1; key_step = 2;
		}
		uint64_t ph = (halfstep - 1) % 8;
		if (ph == 0) { video.sample(); uart.sample(); }
		if (ph == 0) scsi_service();
		if (ph == 0 && top->ide_req && !co_active) ide_service();
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
						if (d == 5) video.colour_req = 2;   // the next complete frame
						if (d == 6) video.edge_req = 2;
						if (d == 7 && mainreset >= 0) {
							// minimig_reset's ApplyConfiguration(0): halt, the
							// configuration written with the machine running, then
							// HLT|RST_CPU|RST_USR, then 0
							printf("[reset] Main's reset at %.4f ms\n", sim_ms()); fflush(stdout);
							uio_cmd({0xF1, 0x04});
							idle_sys(mainreset);
							uio_cmd({0xF1, 0x07});
							idle_sys(1000);
							uio_cmd({0xF1, 0x00});
							printf("[reset] released at %.4f ms\n", sim_ms()); fflush(stdout);
						}
					}
				}
			}
			if (exctrace && top->dbg_xgo)
				printf("%10.4f ms  [exc] vector %3u  PC %08X  SR %04X\n", sim_ms(), top->dbg_xvec, top->dbg_xpc, top->dbg_xsr);
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
	if (dsd_file) {
		dump_sd(dsd_file, dsd_off, dsd_len);
		printf("[dump] SDRAM %08X+%X to %s\n", dsd_off, dsd_len, dsd_file);
	}
	if (dump_file && dump_end) {
		dump_chip(dump_file);
		printf("[dump] chip RAM to %s at %.3f ms\n", dump_file, sim_ms());
	}
	for (uint32_t a : ddrpeek) {
		ddr_scope();
		uint64_t v = ddr_peek64(a >> 3);
		printf("[ddr] %08X: %08X (as the ARM reads it)\n", a, (uint32_t)(v >> ((a & 4) ? 32 : 0)));
	}
	if (ddd_file) {
		FILE *f = fopen(ddd_file, "wb");
		if (!f) { perror(ddd_file); return 1; }
		ddr_scope();
		for (uint32_t a = ddd_addr; a < ddd_addr + ddd_len; a += 4) {
			uint64_t v = ddr_peek64(a >> 3);
			uint32_t w = (uint32_t)(v >> ((a & 4) ? 32 : 0));
			uint8_t b[4] = { (uint8_t)w, (uint8_t)(w >> 8), (uint8_t)(w >> 16), (uint8_t)(w >> 24) };
			fwrite(b, 1, 4, f);
		}
		fclose(f);
		printf("[ddr] %08X+%X to %s\n", ddd_addr, ddd_len, ddd_file);
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
