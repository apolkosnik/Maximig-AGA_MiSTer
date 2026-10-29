// Menu module for the Maximig core: the Amiga 4000/040 and the AA3000+.
//
// Build:  make               (in this folder, against a Main_MiSTer checkout)
// Use:    make deploy MNU_SD_NAME=Maximig_a_aa3000.mnu
//         puts it next to the Maximig_a_aa3000_<date>.rbf files on the card
//         (menu_module=1 in MiSTer.ini)
//
// The core speaks the Minimig protocol, so the module claims the Minimig
// family: Main runs it as a Minimig (keyboard, floppies, configuration in
// Maximig.cfg, the games/Amiga folder) and the module is its whole menu:
//
//  * the main page: the floppies, the hard disks, the Kickstart and the
//    machine -- the CPU card and its clock (the A4000), the bus timing, the
//    motherboard and Zorro III RAM, the cartridge
//  * Audio & Video (the core's video and Paula settings, as Minimig's),
//    Settings (joystick, Ethernet, floppy speed), loading and saving the
//    configuration slots; Minimig's own menu is not offered, its System page
//    describes another machine
//  * a new configuration's defaults: 2 MB chip RAM, 16 MB motherboard RAM,
//    AGA, the IDE (SCSI) disks on, KICK4000.ROM (KICK3000.ROM on the AA3000+)
//  * HRTmon told the machine has no Gayle IDE
//  * the AA3000+'s SCSI disks: the core (a3kp_scsi_hps) runs the bus phases
//    on IDE channel 0 and asks with requests 1-3; the commands run here
//    (the core's hps/maximig_scsi_target.h) on the channel's drives
//
// The AA3000+ is told apart from the A4000 builds by its rbf's name
// ("aa3000" in it); it has no drive sounds.

#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <time.h>
#include <linux/input.h>

#include "mnu_api.h"
#include "mnu_minimig.h"
#include "support/minimig/minimig_config.h"
#include "maximig_scsi_target.h"

#define MAXIMIG_VERSION "1.1"

// the CPU card is the BFG9060, not the A3640: the core's status bit 56
#define MAXIMIG_EXTCFG_BFG 0x1000000

static const mnu_host_api_t *host = NULL;
static const mnu_minimig_api_t *mm = NULL;
static mm_configTYPE *cfg = NULL;
static mnu_core_info_t core;
static int aa3000 = 0;
static int dirty = 0;           // a change that waits for a reset

/////////////////////////////////////////////////////////////////////////
// the pages and their rows

enum { PG_MAIN, PG_AV, PG_SET, PG_LOAD, PG_SAVE, PG_COUNT };

enum
{
	R_GAP,              // a blank or a heading, never selected
	// main
	R_DF0, R_DF1, R_DF2, R_DF3,
	R_HD0, R_HD1,
	R_ROM, R_EXTROM, R_CART,
	R_CPU, R_BUS, R_MBRAM, R_Z3RAM,
	R_AV, R_SET, R_LOAD, R_SAVE, R_RESET, R_EXIT,
	// Audio & Video
	R_TV, R_SCAN, R_VAREA, R_AR, R_PIXCLK, R_SCALE, R_RTG,
	R_STEREO, R_FILTER, R_MODEL, R_PAULA, R_DSND, R_ADJUST,
	// Settings
	R_JOYMODE, R_JOYSWAP, R_ETH, R_FDDTURBO,
	// Load, Save
	R_SLOT0, R_SLOT9 = R_SLOT0 + 9,
	R_BACK,
};

struct row_t
{
	int  id;
	int  sel;           // can take the cursor
	char text[48];
};

static row_t rows[40];
static int nrows = 0;
static int page = PG_MAIN;
static int cur[PG_COUNT];       // the cursor's row id on each page

static const char *config_scanlines_msg[] = { "Off", "HQ2x", "CRT 25%", "CRT 50%", "CRT 75%", "???", "???", "???" };
static const char *config_blank_msg[] = { "Blank", "Blank+", "???", "???" };
static const char *config_scale[] = { "Normal", "V-Integer", "HV-Integer-", "HV-Integer+", "HV-Integer", "???", "???", "???" };
static const char *config_stereo_msg[] = { "0%", "25%", "50%", "100%" };
static const char *config_dsnd_msg[] = { "Off", "Quiet", "Normal", "Loud" };
static const char *config_joystick_mode[] = { "Digital", "Analog", "CD32", "Analog" };

static int is_bfg() { return (mm->get_extcfg() & MAXIMIG_EXTCFG_BFG) ? 1 : 0; }

static int z3_get()
{
	return ((cfg->memory >> 4) & 0x03) | ((cfg->memory & 0x80) >> 5);
}

static void z3_set(int c)
{
	cfg->memory = ((c << 4) & 0x30) | ((c << 5) & 0x80) | (cfg->memory & ~0xB0);
}

// the file name of a path, shortened to len (at most 31) characters
static const char *short_name(const char *path, int len)
{
	static char s[32];
	const char *p = strrchr(path, '/');
	p = p ? p + 1 : path;
	snprintf(s, sizeof(s), "%.*s", len, p);
	return s;
}

static row_t *add(int id, int sel, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static row_t *add(int id, int sel, const char *fmt, ...)
{
	row_t *r = &rows[nrows < 39 ? nrows++ : 39];
	r->id = id;
	r->sel = sel;
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(r->text, sizeof(r->text), fmt, ap);
	va_end(ap);
	return r;
}

static void build_main(void)
{
	static const char *mx_speed[] = { "25MHz", "33MHz", "50MHz", "56MHz" };
	static const char *mx_bfg_speed[] = { "25MHz", "37.5MHz", "50MHz", "50MHz" };
	static const char *mx_mbram[] = { "none", "4M", "8M", "16M" };
	char name[1024];

	int req = mm->floppy_requested_count();
	int act = mm->floppy_active_count();
	for (int i = 0; i < 4; i++)
	{
		if (i == req)
		{
			// the row after the last drive offers adding one
			add(R_DF0 + i, !req, " KP +/- to add/remove drives");
			break;
		}
		if (i >= act) add(R_DF0 + i, 0, " df%d: * active after reset *", i);
		else
		{
			int st = mm->floppy_status(i, name, sizeof(name));
			if (st & MNU_MM_DSK_INSERTED)
				add(R_DF0 + i, 1, " df%d: %s%s", i, short_name(name, 21), (st & MNU_MM_DSK_WRITABLE) ? "" : " \x17");
			else add(R_DF0 + i, 1, " df%d: * no disk *", i);
		}
	}
	add(R_GAP, 0, "%s", "");

	for (int i = 0; i < 2; i++)
	{
		const mm_hardfileTYPE *h = &cfg->hardfile[i];
		add(R_HD0 + i, 1, " %s %d : %s", aa3000 ? "SCSI" : "IDE ", i,
			!h->cfg ? "* disabled *" : h->filename[0] ? short_name(h->filename, 17) : "* none *");
	}
	add(R_GAP, 0, "%s", "");

	add(R_ROM, 1, " ROM      : %s", short_name(cfg->kickstart, 17));
	const char *e = mm->get_extrom();
	add(R_EXTROM, 1, " Ext.ROM  : %s", e[0] ? short_name(e, 17) : "<none>");
	add(R_CART, 1, " Cartridge: %s", !(cfg->memory & 0x40) ? "Off" :
		(mm->get_extcfg() & MINIMIG_EXTCFG_AR) ? "Action Replay" : "HRTmon");

	if (aa3000) add(R_CPU, 0, " CPU      : 68030 28MHz");
	else if (is_bfg()) add(R_CPU, 1, " CPU      : BFG9060 %s", mx_bfg_speed[cfg->cpu & 0x03]);
	else add(R_CPU, 1, " CPU      : A3640 %s", mx_speed[cfg->cpu & 0x03]);
	add(R_BUS, 1, " Bus      : %s", (cfg->cpu & 0x20) ? "Fast" : aa3000 ? "A3000" : "A4000");
	add(R_MBRAM, 1, " MB RAM   : %s", mx_mbram[(cfg->memory >> 2) & 0x03]);
	int z3 = z3_get();
	// (with the BFG9060 its 128 MB takes the 128 MB board's memory)
	if (is_bfg()) add(R_Z3RAM, 1, " Z3 RAM   : %s", (z3 >= 4) ? "256M" : "none");
	else add(R_Z3RAM, 1, " Z3 RAM   : %s", !z3 ? "none" : (z3 < 4) ? "128M" : (z3 == 4) ? "256M" : "384M");
	add(R_GAP, 0, "%s", "");

	add(R_AV, 1, " Audio & Video             \x16");
	add(R_SET, 1, " Settings                  \x16");
	add(R_LOAD, 1, " Load configuration        \x16");
	add(R_SAVE, 1, " Save configuration        \x16");
	add(R_RESET, 1, "%s", dirty ? " Reset (to apply changes)" : " Reset");
	add(R_EXIT, 1, "            exit");
}

static void build_av(void)
{
	uint32_t ext = mm->get_extcfg();
	char ar[40];
	int a = host->ar_name((cfg->scanlines >> 4) & 3, ar, sizeof(ar));
	cfg->scanlines = (uint8_t)((a << 4) | (cfg->scanlines & ~0x30));

	add(R_TV, 1, " TV Standard   : %s", (cfg->chipset & CONFIG_NTSC) ? "NTSC" : "PAL");
	add(R_GAP, 0, "%s", "");
	add(R_SCAN, 1, " Scandoubler FX: %s", config_scanlines_msg[cfg->scanlines & 7]);
	add(R_VAREA, 1, " Video area by : %s", config_blank_msg[(cfg->scanlines >> 6) & 3]);
	add(R_AR, 1, " Aspect Ratio  : %s", ar);
	add(R_PIXCLK, 1, " Pixel Clock   : %s", (ext & 0x400) ? "Adaptive" : "28MHz");
	add(R_SCALE, 1, " Scaling       : %s", config_scale[(ext >> 11) & 7]);
	add(R_RTG, 1, " RTG Upscaling : %s", (ext & 0x4000) ? "HV-Integer" : "Normal");
	add(R_GAP, 0, "%s", "");
	add(R_STEREO, 1, " Stereo mix    : %s", config_stereo_msg[cfg->audio & 3]);
	add(R_FILTER, 1, " Audio Filter  : %s", (~ext & 0x10000) ? "Auto(LED)" : (ext & 0x8000) ? "On" : "Off");
	add(R_MODEL, 1, " Model         : %s", (ext & 0x20000) ? "A1200" : "A500");
	add(R_PAULA, 1, " Paula Output  : %s", (ext & 0x40000) ? "PWM" : "Normal");
	if (!aa3000) add(R_DSND, 1, " Drive Sounds  : %s", mm->dsnd_loaded() ? config_dsnd_msg[(ext >> 19) & 3] : "No file");
	add(R_ADJUST, 1, "%s", mm->get_adjust() ? " Finish screen adjustment" : " Adjust screen position");
	add(R_GAP, 0, "%s", "");
	add(R_BACK, 1, "            back");
}

static void build_set(void)
{
	add(R_JOYMODE, 1, " Joystick      : %s", config_joystick_mode[(cfg->autofire & 6) >> 1]);
	add(R_JOYSWAP, 1, " Joystick Swap : %s", (cfg->autofire & 0x8) ? "On" : "Off");
	add(R_ETH, 1, " Ethernet      : %s", mm->net_iface_name(mm->net_get_iface()));
	add(R_FDDTURBO, 1, " FDD Turbo     : %s", cfg->floppy.speed ? "On" : "Off");
	add(R_GAP, 0, "%s", "");
	add(R_BACK, 1, "            back");
}

// the slots: 0 the startup configuration, 1-9 the others; loading offers
// only those that exist
static void build_slots(int save)
{
	add(R_GAP, 0, " Startup config:");
	for (int i = 0; i < 10; i++)
	{
		if (i == 1)
		{
			add(R_GAP, 0, "%s", "");
			add(R_GAP, 0, " Other configs:");
		}
		const char *info = mm->cfg_info(i, 1);
		if (!info)
		{
			if (save) add(R_SLOT0 + i, 1, "  < EMPTY >");
			continue;
		}
		char line[48];
		snprintf(line, sizeof(line), "%s", info[0] ? info : "NO INFO");
		char *nl = strchr(line, '\n');
		if (nl) *nl = 0;
		add(R_SLOT0 + i, 1, "  %s", line);
	}
	add(R_GAP, 0, "%s", "");
	add(R_BACK, 1, "            back");
}

static void build(void)
{
	nrows = 0;
	switch (page)
	{
	case PG_MAIN: build_main(); break;
	case PG_AV:   build_av(); break;
	case PG_SET:  build_set(); break;
	case PG_LOAD: build_slots(0); break;
	case PG_SAVE: build_slots(1); break;
	}
}

static int cursor_index(void)
{
	for (int i = 0; i < nrows; i++) if (rows[i].id == cur[page] && rows[i].sel) return i;
	for (int i = 0; i < nrows; i++) if (rows[i].sel) return i;
	return 0;
}

static void draw(void)
{
	static const char *titles[PG_COUNT] = { NULL, "Audio & Video", "Settings", "Load config", "Save config" };
	build();
	int c = cursor_index();
	cur[page] = rows[c].id;
	host->osd_set_title(page == PG_MAIN ? (aa3000 ? "AA3000+" : "Maximig") : titles[page],
		page == PG_MAIN ? (MNU_OSD_ARROW_LEFT | MNU_OSD_ARROW_RIGHT) : MNU_OSD_ARROW_LEFT);

	do
	{
		host->menu_draw_begin();
		for (int i = 0; i < nrows; i++)
			host->menu_write(i, rows[i].text, i == c, !rows[i].sel && rows[i].text[0], 0);
	} while (host->menu_draw_end());
}

static void move(int dir)
{
	build();
	int c = cursor_index();
	for (int i = 0; i < nrows; i++)
	{
		c = (c + nrows + dir) % nrows;
		if (rows[c].sel) break;
	}
	cur[page] = rows[c].id;
}

static void go_page(int p, int row)
{
	page = p;
	if (row >= 0) cur[p] = row;
	host->menu_reset_scroll();
}

/////////////////////////////////////////////////////////////////////////
// the settings

// a value row stepped forward (+1) or back (-1)
static void step(int id, int dir)
{
	int minus = dir < 0;
	uint32_t ext = mm->get_extcfg();

	switch (id)
	{
	case R_CART:
	{
		// Off -> HRTmon -> Action Replay -> Off; kept in the config and sent
		// to the core at the next reset, with the cartridge's image
		int c = !(cfg->memory & 0x40) ? 0 : (ext & MINIMIG_EXTCFG_AR) ? 2 : 1;
		c = (c + (minus ? 2 : 1)) % 3;
		cfg->memory = (cfg->memory & ~0x40) | (c ? 0x40 : 0);
		if (c == 2) cfg->ext_cfg2 |= MINIMIG_EXTCFG_AR >> 16;
		else cfg->ext_cfg2 &= ~(MINIMIG_EXTCFG_AR >> 16);
		dirty = 1;
		break;
	}

	case R_CPU:
	{
		// the card and its clock: the A3640 at 25, 33, 50, 56 MHz, the
		// BFG9060 at 25, 37.5, 50 MHz; a change of card takes effect at the
		// next reset (the core takes it in reset)
		static const int steps = 7;
		int bfg = is_bfg();
		int k = bfg ? 4 + ((cfg->cpu & 3) > 2 ? 2 : (cfg->cpu & 3)) : (cfg->cpu & 3);
		k = (k + (minus ? steps - 1 : 1)) % steps;
		int nbfg = (k >= 4);
		cfg->cpu = (cfg->cpu & ~0x03) | (nbfg ? k - 4 : k);
		if (nbfg) cfg->ext_cfg2 |= MAXIMIG_EXTCFG_BFG >> 16;
		else cfg->ext_cfg2 &= ~(MAXIMIG_EXTCFG_BFG >> 16);
		if (nbfg != bfg) dirty = 1;
		mm->config_cpu();
		break;
	}

	case R_BUS:
		cfg->cpu ^= 0x20;
		mm->config_cpu();
		break;

	case R_MBRAM:
		cfg->memory = ((cfg->memory + (minus ? -4 : 4)) & 0x0C) | (cfg->memory & ~0x0C);
		dirty = 1;
		break;

	case R_Z3RAM:
	{
		// none, 128 MB, 256 MB, 384 MB (with the BFG9060: none, 256 MB)
		static const int z3_steps[4] = { 0, 1, 4, 5 };
		int c = z3_get();
		int k = (c == 0) ? 0 : (c < 4) ? 1 : (c == 4) ? 2 : 3;
		if (is_bfg()) c = (c >= 4) ? 0 : 4;
		else c = z3_steps[(k + (minus ? 3 : 1)) & 3];
		z3_set(c);
		dirty = 1;
		break;
	}

	// Audio & Video: what Minimig's page does, on the same core bits
	case R_TV:
		cfg->chipset ^= CONFIG_NTSC;
		mm->config_chipset();
		break;

	case R_SCAN:
	{
		int s = cfg->scanlines & 7;
		s = minus ? (s ? s - 1 : 4) : (s >= 4 ? 0 : s + 1);
		cfg->scanlines = (uint8_t)(s | (cfg->scanlines & 0xF8));
		mm->config_video();
		break;
	}

	case R_VAREA:
		cfg->scanlines &= ~0x80;
		cfg->scanlines ^= 0x40;
		mm->config_video();
		break;

	case R_AR:
		cfg->scanlines = (uint8_t)((host->ar_next((cfg->scanlines >> 4) & 3, minus) << 4) | (cfg->scanlines & ~0x30));
		mm->config_video();
		break;

	case R_PIXCLK:
		mm->set_extcfg(ext ^ 0x400);
		break;

	case R_SCALE:
	{
		int m = (ext >> 11) & 7;
		m = minus ? (m <= 0 ? 4 : m - 1) : (m >= 4 ? 0 : m + 1);
		mm->set_extcfg((ext & ~0x3800) | (m << 11));
		break;
	}

	case R_RTG:
		mm->set_extcfg(ext ^ 0x4000);
		break;

	case R_STEREO:
		cfg->audio = (cfg->audio + (minus ? -1 : 1)) & 3;
		mm->config_audio();
		break;

	case R_FILTER:
	{
		// Auto(LED) -> On -> Off
		int m = (ext >> 15) & 3;
		m = minus ? (m == 2 ? 0 : m - 1) : (m == 0 ? 2 : m + 1);
		mm->set_extcfg((ext & ~0x18000) | ((m & 3) << 15));
		break;
	}

	case R_MODEL:
		mm->set_extcfg(ext ^ 0x20000);
		break;

	case R_PAULA:
		mm->set_extcfg(ext ^ 0x40000);
		break;

	case R_DSND:
		if (mm->dsnd_loaded())
		{
			int m = ((ext >> 19) + (minus ? 3 : 1)) & 3;
			mm->set_extcfg((ext & ~0x180000) | (m << 19));
		}
		break;

	// Settings
	case R_JOYMODE:
	{
		// Digital, Analog, CD32
		int x = (cfg->autofire & 6) >> 1;
		x = minus ? (x == 0 ? 2 : x - 1) : (x >= 2 ? 0 : x + 1);
		cfg->autofire = (uint8_t)((cfg->autofire & ~6) | (x << 1));
		mm->config_autofire(6);
		break;
	}

	case R_JOYSWAP:
		cfg->autofire ^= 0x8;
		mm->config_autofire(0x8);
		break;

	case R_ETH:
	{
		// OFF -> eth0 -> eth1 -> macvlan -> tap0, skipping what this box
		// cannot do; OFF and eth0 always can
		int n = mm->net_modes();
		int m = mm->net_get_iface();
		for (int i = 0; i < n; i++)
		{
			m = minus ? (m + n - 1) % n : (m + 1) % n;
			if (mm->net_mode_available(m)) break;
		}
		mm->net_set_iface(m);
		break;
	}

	case R_FDDTURBO:
		cfg->floppy.speed ^= 1;
		mm->config_floppy();
		break;
	}
}

// the info line a saved configuration shows in the slot lists
static void set_info(void)
{
	static const char *mbram[] = { "", "+4M", "+8M", "+16M" };
	static const char *z3[] = { "", "+128M", "+128M", "+128M", "+256M", "+384M", "", "" };
	int hd = (cfg->ide_cfg & 1) && (cfg->hardfile[0].cfg || cfg->hardfile[1].cfg);
	snprintf(cfg->info, sizeof(cfg->info), "%s/%s%s 2M%s%s%s\n%s",
		aa3000 ? "AA3000+" : is_bfg() ? "BFG9060" : "A3640",
		(cfg->chipset & CONFIG_NTSC) ? "N" : "P", hd ? (aa3000 ? "/SCSI" : "/HD") : "",
		mbram[(cfg->memory >> 2) & 3], z3[z3_get() & 7],
		(cfg->memory & 0x40) ? ((mm->get_extcfg() & MINIMIG_EXTCFG_AR) ? " AR" : " HRT") : "",
		short_name(cfg->kickstart, 31));
}

// what the file selector was opened for
enum { SEL_NONE, SEL_FLOPPY, SEL_HD, SEL_ROM, SEL_EXTROM };
static int sel_what = SEL_NONE;
static int sel_index = 0;
static char sel_start[1024] = "";

static void select_file(int what, int index, const char *start, const char *ext, uint32_t opts)
{
	sel_what = what;
	sel_index = index;
	snprintf(sel_start, sizeof(sel_start), "%s", start ? start : "");
	host->select_file(sel_start, ext, opts);
}

/////////////////////////////////////////////////////////////////////////
// a new configuration

static void set_defaults(void)
{
	// an A4000/040 (an AA3000+): 2 MB chip RAM, 16 MB motherboard RAM, the
	// 68040 at 25 MHz with A4000 bus timing, AGA, the IDE (the AA3000+'s
	// SCSI disks) on, the machine's Kickstart
	char rom[1024];
	snprintf(rom, sizeof(rom), "%s/%s", host->home_dir(), aa3000 ? "KICK3000.ROM" : "KICK4000.ROM");
	mm->set_kickstart(rom);
	cfg->memory = 0x0F;
	cfg->cpu = 0;
	cfg->chipset = CONFIG_AGA | CONFIG_ECS;
	cfg->ide_cfg = 1;
}

/////////////////////////////////////////////////////////////////////////
// the AA3000+'s SCSI disks

static void io_wr(void *, int reg, uint16_t v) { mm->ide_reg_set(0, (uint16_t)reg, v); }
static void io_rdregs(void *, uint16_t *v, int n) { mm->ide_recvbuf(0, 0, n, v); }
static void io_wrbuf(void *, const uint16_t *w, int n) { mm->ide_sendbuf(0, 255, n, w); }
static void io_rdbuf(void *, uint16_t *w, int n) { mm->ide_recvbuf(0, 255, n, w); }

// the core's next request (the A2065 served meanwhile, as the IDE's wait
// does); after 5 s without one the command is given up
static int io_wait(void *)
{
	struct timespec t0, t;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (;;)
	{
		int req = mm->ide_check() & 7;
		if (req) return req;
		mm->net_poll();
		clock_gettime(CLOCK_MONOTONIC, &t);
		if (t.tv_sec - t0.tv_sec > 5)
		{
			printf("maximig: SCSI: no request from the core, the command given up\n");
			return 0;
		}
	}
}

static int disk_read(void *ctx, uint32_t lba, uint8_t *buf, uint32_t cnt)
{
	return mm->drive_read(0, (int)(intptr_t)ctx, lba, buf, cnt);
}

static int disk_write(void *ctx, uint32_t lba, const uint8_t *buf, uint32_t cnt)
{
	return mm->drive_write(0, (int)(intptr_t)ctx, lba, buf, cnt);
}

static scsi_target target;

static void ide_request(int port, int req)
{
	// requests 2 and 3 belong to a command, which waits for them itself
	if (!aa3000 || port != 0 || req != SCSI_RQ_CMD) return;

	scsi_io io = { nullptr, io_wr, io_rdregs, io_wrbuf, io_rdbuf, io_wait };
	scsi_disk d[2];
	for (int i = 0; i < 2; i++)
	{
		mnu_mm_drive_t di;
		memset(&di, 0, sizeof(di));
		di.size = sizeof(di);
		mm->drive_info(0, i, &di);
		d[i] = { (void*)(intptr_t)i, di.present && !di.cd, di.total_sectors, di.cylinders, di.heads, di.spt,
		         disk_read, disk_write };
	}
	scsi_command(&target, &io, d);
}

/////////////////////////////////////////////////////////////////////////
// module entry points

static int init(const mnu_host_api_t *h, const mnu_core_info_t *c)
{
	if (!h || h->abi_version != MNU_ABI_VERSION || h->size < sizeof(mnu_host_api_t)) return 1;
	if (!c || c->size < sizeof(mnu_core_info_t)) return 2;

	const mnu_minimig_api_t *m = (const mnu_minimig_api_t *)h->family_api(MNU_FAMILY_MINIMIG);
	if (!m || m->size < sizeof(mnu_minimig_api_t)) return 3;

	host = h;
	mm = m;
	cfg = (mm_configTYPE *)mm->config;
	core = *c;
	aa3000 = strcasestr(core.rbf_path ? core.rbf_path : "", "aa3000") != NULL;
	dirty = 0;
	page = PG_MAIN;
	memset(cur, 0, sizeof(cur));
	memset(&target, 0, sizeof(target));

	// HRTmon: no Gayle IDE ($DA2000) in either machine
	mm->set_hrtmon_a1200(0);
	int restart = (cfg->memory & 0x40) && !(mm->get_extcfg() & MINIMIG_EXTCFG_AR);

	// no configuration of its own yet: the machine's, not Minimig's
	char name[256];
	snprintf(name, sizeof(name), "config/%s.cfg", core.core_name);
	if (!host->file_exists(name))
	{
		printf("maximig: no %s, the %s defaults\n", name, aa3000 ? "AA3000+" : "A4000");
		set_defaults();
		restart = 1;
	}

	// the boot went up with Minimig's settings: once more with these
	if (restart) mm->reset();

	printf("maximig: init for %s (%s)\n", core.rbf_path, aa3000 ? "AA3000+" : "A4000");
	return 0;
}

static void unload(int reason)
{
	printf("maximig: unload, reason %d\n", reason);
	host = NULL;
	mm = NULL;
	cfg = NULL;
}

static int ui_main(const mnu_event_t *ev, int id)
{
	if (ev->right) return MNU_ACT_SYSTEM_MENU;
	if (ev->left) return MNU_ACT_MISC_MENU;         // Main, the volume ..., as Minimig's menu has it

	int floppy = id >= R_DF0 && id <= R_DF3;

	if (floppy && (ev->plus || ev->minus))
	{
		mm->floppy_step_drives(ev->plus ? 1 : -1);
		cur[page] = R_DF0;
		return MNU_ACT_REDRAW;
	}

	if (ev->key == KEY_BACKSPACE && floppy)
	{
		// eject all
		for (int i = 0; i < mm->floppy_active_count(); i++) mm->floppy_eject(i);
		return MNU_ACT_REDRAW;
	}

	if (ev->plus || ev->minus)
	{
		if (id == R_EXTROM && ev->minus)
		{
			mm->set_extrom("");
			dirty = 1;
		}
		else step(id, ev->minus ? -1 : 1);
		return MNU_ACT_REDRAW;
	}

	if (!ev->select) return MNU_ACT_STAY;

	if (floppy)
	{
		int i = id - R_DF0;
		if (i >= mm->floppy_requested_count()) return MNU_ACT_STAY;
		if (mm->floppy_status(i, NULL, 0) & MNU_MM_DSK_INSERTED)
		{
			mm->floppy_eject(i);
			return MNU_ACT_REDRAW;
		}
		select_file(SEL_FLOPPY, i, "", mm->floppy_extensions(), MNU_SCAN_DIR);
		return MNU_ACT_STAY;
	}

	switch (id)
	{
	case R_HD0: case R_HD1:
	{
		int i = id - R_HD0;
		select_file(SEL_HD, i, cfg->hardfile[i].filename, "HDFVHDIMGDSK", MNU_SCAN_DIR | MNU_SCAN_UMOUNT);
		return MNU_ACT_STAY;
	}

	case R_ROM:
		select_file(SEL_ROM, 0, cfg->kickstart, "ROM", MNU_SCAN_DIR);
		return MNU_ACT_STAY;

	case R_EXTROM:
		select_file(SEL_EXTROM, 0, mm->get_extrom(), "ROM", MNU_SCAN_DIR | MNU_SCAN_UMOUNT);
		return MNU_ACT_STAY;

	case R_CART: case R_CPU: case R_BUS: case R_MBRAM: case R_Z3RAM:
		step(id, 1);
		return MNU_ACT_REDRAW;

	case R_AV:   go_page(PG_AV, -1); return MNU_ACT_REDRAW;
	case R_SET:  go_page(PG_SET, -1); return MNU_ACT_REDRAW;
	case R_LOAD: go_page(PG_LOAD, -1); return MNU_ACT_REDRAW;
	case R_SAVE: go_page(PG_SAVE, -1); return MNU_ACT_REDRAW;

	case R_RESET:
		dirty = 0;
		mm->reset();
		return MNU_ACT_CLOSE;

	case R_EXIT:
		return MNU_ACT_CLOSE;
	}

	return MNU_ACT_STAY;
}

// the sub-pages: Left, Back or their back row return to the main page
static int ui_sub(const mnu_event_t *ev, int id)
{
	static const int entry[PG_COUNT] = { 0, R_AV, R_SET, R_LOAD, R_SAVE };

	if (ev->left || ev->back || (ev->select && id == R_BACK))
	{
		go_page(PG_MAIN, entry[page]);
		return MNU_ACT_REDRAW;
	}

	if (page == PG_LOAD || page == PG_SAVE)
	{
		if (!ev->select || id < R_SLOT0 || id > R_SLOT9) return MNU_ACT_STAY;
		int n = id - R_SLOT0;
		if (page == PG_LOAD)
		{
			// the slot's configuration, its Kickstart loaded again
			mm->cfg_load(n);
			dirty = 0;
			go_page(PG_MAIN, R_LOAD);
			return MNU_ACT_CLOSE;
		}
		set_info();
		host->info(mm->cfg_save(n) ? "Configuration saved" : "Saving the configuration failed", 1500);
		go_page(PG_MAIN, R_SAVE);
		return MNU_ACT_REDRAW;
	}

	if (ev->select && id == R_ADJUST)
	{
		mm->set_adjust(!mm->get_adjust());
		return MNU_ACT_CLOSE;
	}

	if (ev->select || ev->plus || ev->minus)
	{
		step(id, ev->minus ? -1 : 1);
		return MNU_ACT_REDRAW;
	}
	return MNU_ACT_STAY;
}

static int ui(const mnu_event_t *ev)
{
	if (ev->redraw)
	{
		draw();
		return MNU_ACT_STAY;
	}

	if (ev->up) { move(-1); return MNU_ACT_REDRAW; }
	if (ev->down) { move(1); return MNU_ACT_REDRAW; }
	if (page == PG_MAIN && ev->back) return MNU_ACT_CLOSE;

	build();
	int id = rows[cursor_index()].id;
	return (page == PG_MAIN) ? ui_main(ev, id) : ui_sub(ev, id);
}

static int file_selected(const char *path)
{
	switch (sel_what)
	{
	case SEL_FLOPPY:
		if (path[0]) mm->floppy_insert(sel_index, path);
		break;

	case SEL_HD:
	{
		// the drives open at the next reset, as Minimig's disk menu has it;
		// an image makes the unit a hard disk
		mm_hardfileTYPE *h = &cfg->hardfile[sel_index];
		snprintf(h->filename, sizeof(h->filename), "%s", path);
		if (path[0])
		{
			h->cfg = 1;
			cfg->ide_cfg |= 1;
		}
		dirty = 1;
		break;
	}

	case SEL_ROM:
		if (path[0])
		{
			mm->set_kickstart(path);
			dirty = 1;
		}
		break;

	case SEL_EXTROM:
		mm->set_extrom(path);
		dirty = 1;
		break;
	}

	sel_what = SEL_NONE;
	return MNU_ACT_REDRAW;
}

static void file_cancelled(void)
{
	sel_what = SEL_NONE;
}

static void osd_closed(void)
{
	// the menu opens on its main page again
	page = PG_MAIN;
}

static const mnu_module_t module =
{
	sizeof(mnu_module_t),
	MNU_ABI_VERSION,
	MNU_FLAG_KEY_REPEAT,
	"maximig",
	MAXIMIG_VERSION,

	init,
	unload,
	ui,

	file_selected,
	file_cancelled,
	osd_closed,
	NULL,   // poll

	MNU_FAMILY_MINIMIG,
	ide_request,
};

extern "C" MNU_EXPORT const mnu_module_t *mnu_entry(void)
{
	return &module;
}
