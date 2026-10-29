// The Maximig menu module (menu/maximig.cpp) on Main_MiSTer's real host side
// (mnu.cpp, mnu_path.cpp) through Main's test stub layer (tests/mnu/stubs.cpp).
// argv[1] = fixture directory prepared by run.sh.
//
// The Minimig family's service table is a fake here (its real one,
// mnu_minimig.cpp, is the host's Minimig code); it keeps a real
// mm_configTYPE and models the Maximig core's side of IDE channel 0 as the
// AA3000+'s a3kp_scsi_hps has it (maximig_scsi_target.h's register map), so
// the module's SCSI commands run against the same protocol the core speaks.
//
// Module and host printf() output is captured in <fixture>/stdout_maximig.log.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

#include "mnu.h"
#include "mnu_minimig.h"
#include "cfg.h"
#include "user_io.h"
#include "support/minimig/minimig_config.h"
#include "stubs.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_INT(got, want) do { long g_ = (long)(got), w_ = (long)(want); checks++; if (g_ != w_) { failures++; fprintf(stderr, "FAIL %s:%d: %s = %ld, want %ld\n", __FILE__, __LINE__, #got, g_, w_); } } while (0)
#define CHECK_STR(got, want) do { const char *g_ = (got), *w_ = (want); checks++; if (strcmp(g_, w_)) { failures++; fprintf(stderr, "FAIL %s:%d: %s = \"%s\", want \"%s\"\n", __FILE__, __LINE__, #got, g_, w_); } } while (0)

static char logpath[1100];

static int log_count(const char *needle)
{
	fflush(stdout);
	FILE *f = fopen(logpath, "r");
	if (!f) return -1;
	static char buf[1 << 16];
	size_t n = fread(buf, 1, sizeof(buf) - 1, f);
	buf[n] = 0;
	fclose(f);

	int count = 0;
	for (const char *p = buf; (p = strstr(p, needle)) != NULL; p += strlen(needle)) count++;
	return count;
}

static int log_has(const char *needle) { return log_count(needle) > 0; }

static void dump_log(void)
{
	fflush(stdout);
	FILE *f = fopen(logpath, "r");
	if (!f) return;
	char line[1024];
	fprintf(stderr, "---- captured stdout ----\n");
	while (fgets(line, sizeof(line), f)) fputs(line, stderr);
	fclose(f);
}

/////////////////////////////////////////////////////////////////////////
// the fake Minimig family table

static mm_configTYPE mmcfg;

static struct
{
	int resets;
	int cfg_saves, cfg_save_num;
	int config_cpu_calls, config_chipset_calls, config_floppy_calls;
	int set_kickstart_calls;
	char extrom[1024];
	int hrtmon, hrtmon_calls;
	int active, requested;
	int df_status[4];
	char df_name[4][1024];
	int inserts, insert_drive;
	char insert_path[1024];
	int ejects;
	int net_polls;
	int config_video_calls, config_audio_calls;
	int autofire_calls, autofire_mask;
	int adjust, adjust_calls;
	int dsnd;
	int cfg_loads, cfg_load_num;
	const char *slot_info[10];
	int net_iface, net_avail;

	// the drives of IDE channel 0
	int present[2];
	uint32_t sectors[2];
	int reads, read_port, read_drv;
	uint32_t read_lba, read_cnt;
	int writes, write_port, write_drv;
	uint32_t write_lba, write_cnt;
	uint8_t written[8192];
} fk;

// the core's side of channel 0 (a3kp_scsi_hps): registers 0-6, the 8 KB
// buffer behind register 15 (Main's register 255, the data port), the step
// register 8, and the request bits
static struct
{
	uint16_t regs[7];
	uint16_t buf[4096];
	int cur;
	int pending;
	int steps;
	uint16_t step[64];
	int other_port;
	uint8_t din[16384];      // what went to the initiator
	uint32_t din_len;
	uint8_t dout[16384];     // what the initiator sends
	uint32_t dout_pos;
	int status, done;
} core;

static void core_reset(void)
{
	memset(&core, 0, sizeof(core));
	core.status = -1;
}

// the next command: a CDB from target tid
static void core_cdb(int seq, int lun, int tid, const uint8_t *cdb, int len)
{
	core.regs[0] = (uint16_t)(0xA000 | (seq << 8) | (lun << 4) | tid);
	for (int i = 1; i < 7; i++) core.regs[i] = 0;
	for (int i = 0; i < len; i++) core.regs[1 + i / 2] |= (uint16_t)(cdb[i] << ((i & 1) * 8));
}

static void f_ide_reg_set(int port, uint16_t reg, uint16_t value)
{
	if (port != 0) { core.other_port++; return; }
	if (reg == 0) core.cur = 0;
	else if (reg == 8)
	{
		if (core.steps < 64) core.step[core.steps] = value;
		core.steps++;
		uint32_t n = value & 0x3FFF;
		switch (value >> 14)
		{
		case 0:   // Data In: the buffer's first n bytes go to the initiator
			for (uint32_t i = 0; i < n && core.din_len < sizeof(core.din); i++)
				core.din[core.din_len++] = (uint8_t)(core.buf[i >> 1] >> ((i & 1) * 8));
			core.pending = 3;
			break;
		case 1:   // Data Out: n bytes from the initiator into the buffer
			memset(core.buf, 0, sizeof(core.buf));
			for (uint32_t i = 0; i < n; i++)
				core.buf[i >> 1] |= (uint16_t)(core.dout[core.dout_pos++] << ((i & 1) * 8));
			core.pending = 2;
			break;
		case 2:   // Status, Command Complete
			core.status = value & 0xFF;
			core.done++;
			break;
		}
	}
}

static void f_ide_recvbuf(int port, uint16_t reg, uint32_t words, uint16_t *data)
{
	if (port != 0) { core.other_port++; return; }
	if (reg == 0) for (uint32_t i = 0; i < words; i++) data[i] = i < 7 ? core.regs[i] : 0;
	else if (reg == 255) for (uint32_t i = 0; i < words; i++) data[i] = core.buf[(core.cur++) & 4095];
}

static void f_ide_sendbuf(int port, uint16_t reg, uint32_t words, const uint16_t *data)
{
	if (port != 0 || reg != 255) { core.other_port++; return; }
	for (uint32_t i = 0; i < words; i++) core.buf[(core.cur++) & 4095] = data[i];
}

static uint16_t f_ide_check(void)
{
	uint16_t r = (uint16_t)core.pending;
	core.pending = 0;
	return r;
}

static uint8_t pattern(int drv, uint32_t lba, uint32_t i) { return (uint8_t)(lba * 7 + i + drv * 13); }

static int f_drive_info(int port, int drv, mnu_mm_drive_t *info)
{
	if (port != 0 || drv < 0 || drv > 1 || info->size < sizeof(*info)) return 0;
	info->present = (uint8_t)fk.present[drv];
	info->cd = 0;
	info->cylinders = 100;
	info->heads = 4;
	info->spt = 32;
	info->total_sectors = fk.sectors[drv];
	return 1;
}

static int f_drive_read(int port, int drv, uint32_t lba, uint8_t *buf, uint32_t cnt)
{
	fk.reads++;
	fk.read_port = port;
	fk.read_drv = drv;
	fk.read_lba = lba;
	fk.read_cnt = cnt;
	for (uint32_t s = 0; s < cnt; s++)
		for (uint32_t i = 0; i < 512; i++) buf[s * 512 + i] = pattern(drv, lba + s, i);
	return 1;
}

static int f_drive_write(int port, int drv, uint32_t lba, const uint8_t *buf, uint32_t cnt)
{
	fk.writes++;
	fk.write_port = port;
	fk.write_drv = drv;
	fk.write_lba = lba;
	fk.write_cnt = cnt;
	memcpy(fk.written, buf, cnt * 512 > sizeof(fk.written) ? sizeof(fk.written) : cnt * 512);
	return 1;
}

static void f_reset(void) { fk.resets++; }
static int  f_cfg_save(int num) { fk.cfg_saves++; fk.cfg_save_num = num; return 1; }
static int  f_cfg_load(int num) { fk.cfg_loads++; fk.cfg_load_num = num; return 1; }
static void f_config_cpu(void) { fk.config_cpu_calls++; }
static void f_config_chipset(void) { fk.config_chipset_calls++; }
static void f_config_floppy(void) { fk.config_floppy_calls++; }
static void f_set_kickstart(const char *path)
{
	fk.set_kickstart_calls++;
	snprintf(mmcfg.kickstart, sizeof(mmcfg.kickstart), "%s", path);
}
static void f_set_extrom(const char *path) { snprintf(fk.extrom, sizeof(fk.extrom), "%s", path); }
static const char *f_get_extrom(void) { return fk.extrom; }
static uint32_t f_get_extcfg(void) { return mmcfg.ext_cfg | ((uint32_t)mmcfg.ext_cfg2 << 16); }
static void f_set_hrtmon_a1200(uint8_t v) { fk.hrtmon = v; fk.hrtmon_calls++; }

static int f_floppy_status(int drive, char *name, int namelen)
{
	if (name && namelen > 0) snprintf(name, namelen, "%s", fk.df_name[drive]);
	return fk.df_status[drive];
}
static void f_floppy_insert(int drive, const char *path)
{
	fk.inserts++;
	fk.insert_drive = drive;
	snprintf(fk.insert_path, sizeof(fk.insert_path), "%s", path);
	snprintf(fk.df_name[drive], sizeof(fk.df_name[drive]), "%s", path);
	fk.df_status[drive] = MNU_MM_DSK_INSERTED | MNU_MM_DSK_WRITABLE;
}
static void f_floppy_eject(int drive)
{
	fk.ejects++;
	fk.df_status[drive] = 0;
	fk.df_name[drive][0] = 0;
}
static int f_floppy_active_count(void) { return fk.active; }
static int f_floppy_requested_count(void) { return fk.requested; }
static int f_floppy_step_drives(int direction)
{
	int n = fk.requested + (direction < 0 ? -1 : 1);
	if (n >= 0 && n <= 4) fk.requested = n;
	fk.config_floppy_calls++;
	return fk.requested;
}
static const char *f_floppy_extensions(void) { return "ADFSCP"; }
static void f_net_poll(void) { fk.net_polls++; }
static void f_config_video(void) { fk.config_video_calls++; }
static void f_config_audio(void) { fk.config_audio_calls++; }
static void f_set_extcfg(uint32_t ext)
{
	mmcfg.ext_cfg = (uint16_t)ext;
	mmcfg.ext_cfg2 = (uint16_t)(ext >> 16);
}
static void f_config_autofire(uint8_t mask) { fk.autofire_calls++; fk.autofire_mask = mask; }
static int  f_get_adjust(void) { return fk.adjust; }
static void f_set_adjust(int on) { fk.adjust = on; fk.adjust_calls++; }
static int  f_dsnd_loaded(void) { return fk.dsnd; }
static const char *f_cfg_info(int num, int) { return (num >= 0 && num < 10) ? fk.slot_info[num] : NULL; }
static const char *net_names[5] = { "OFF", "eth0", "eth1", "macvlan", "tap0" };
static int  f_net_modes(void) { return 5; }
static int  f_net_get_iface(void) { return fk.net_iface; }
static void f_net_set_iface(int m) { fk.net_iface = m; }
static int  f_net_mode_available(int m) { return (fk.net_avail >> m) & 1; }
static const char *f_net_iface_name(int m) { return net_names[m]; }

static mnu_minimig_api_t fake_api =
{
	sizeof(mnu_minimig_api_t),

	&mmcfg,
	f_reset,
	f_cfg_save,
	f_cfg_load,
	f_config_cpu,
	f_config_chipset,
	f_config_floppy,
	f_set_kickstart,
	f_set_extrom,
	f_get_extrom,
	f_get_extcfg,
	f_set_hrtmon_a1200,

	f_floppy_status,
	f_floppy_insert,
	f_floppy_eject,
	f_floppy_active_count,
	f_floppy_requested_count,
	f_floppy_step_drives,
	f_floppy_extensions,

	f_ide_check,
	f_ide_reg_set,
	f_ide_recvbuf,
	f_ide_sendbuf,
	f_drive_info,
	f_drive_read,
	f_drive_write,

	f_net_poll,

	f_config_video,
	f_config_audio,
	f_set_extcfg,
	f_config_autofire,
	f_get_adjust,
	f_set_adjust,
	f_dsnd_loaded,

	f_cfg_info,

	f_net_modes,
	f_net_get_iface,
	f_net_set_iface,
	f_net_mode_available,
	f_net_iface_name,
};

// Minimig's configuration as BootInit() leaves it (minimig_cfg_load's
// defaults), the fake's state clean
static void machine_fresh(void)
{
	memset(&mmcfg, 0, sizeof(mmcfg));
	snprintf(mmcfg.kickstart, sizeof(mmcfg.kickstart), "/media/fat/games/Amiga/KICK.ROM");
	mmcfg.memory = 0x11;
	mmcfg.floppy.drives = 1;
	mmcfg.hardfile[0].cfg = 1;
	mmcfg.hardfile[1].cfg = 1;
	memset(&fk, 0, sizeof(fk));
	fk.active = 1;
	fk.requested = 1;
	fk.slot_info[0] = "AA3000+/P 2M+16M\nKICK3000.ROM";
	fk.slot_info[3] = "";
	fk.net_avail = 0x13;                               // OFF, eth0, tap0
	fk.present[0] = 1;
	fk.sectors[0] = 1000;
	fk.sectors[1] = 2000;
	core_reset();
}

/////////////////////////////////////////////////////////////////////////
// the Maximig module's pages (menu/maximig.cpp): rows are found
// by their text, as the floppy rows and the pages move them about

static int send_ev(mnu_event_t *ev) { ev->size = sizeof(*ev); return mnu_ui(ev); }

static int send(const char *what)
{
	mnu_event_t ev;
	memset(&ev, 0, sizeof(ev));
	if (!strcmp(what, "redraw"))
	{
		// a page draws only its own rows
		ev.redraw = 1;
		memset(stub.rows, 0, sizeof(stub.rows));
		memset(stub.row_invert, 0, sizeof(stub.row_invert));
		memset(stub.row_stipple, 0, sizeof(stub.row_stipple));
	}
	else if (!strcmp(what, "up")) ev.up = 1;
	else if (!strcmp(what, "down")) ev.down = 1;
	else if (!strcmp(what, "left")) ev.left = 1;
	else if (!strcmp(what, "right")) ev.right = 1;
	else if (!strcmp(what, "select")) ev.select = 1;
	else if (!strcmp(what, "back")) ev.back = 1;
	else if (!strcmp(what, "plus")) ev.plus = 1;
	else if (!strcmp(what, "minus")) ev.minus = 1;
	return send_ev(&ev);
}

// the first row drawn that starts with prefix, -1 if none
static int find(const char *prefix)
{
	for (int i = 0; i < 32; i++) if (stub.rows[i][0] && !strncmp(stub.rows[i], prefix, strlen(prefix))) return i;
	return -1;
}

static const char *row(const char *prefix) { int i = find(prefix); return i < 0 ? "<missing>" : stub.rows[i]; }
static int stipple(const char *prefix) { int i = find(prefix); return i < 0 ? -1 : stub.row_stipple[i]; }

// the row the cursor is on, as a fresh redraw shows it
static const char *at(void)
{
	send("redraw");
	int r = -1;
	for (int i = 0; i < 32; i++) if (stub.row_invert[i]) { CHECK(r < 0); r = i; }
	return r < 0 ? "<none>" : stub.rows[r];
}

static int at_is(const char *prefix) { return !strncmp(at(), prefix, strlen(prefix)); }

// move the cursor to a row (down only), checking it can get there
static void go(const char *prefix)
{
	for (int i = 0; i < 40 && !at_is(prefix); i++) send("down");
	checks++;
	if (!at_is(prefix)) { failures++; fprintf(stderr, "FAIL: no row \"%s\" to go to (at \"%s\")\n", prefix, at()); }
}

// a command from target tid, run by the module through the host's request
// dispatch; the module answers it fully before returning
static void command(int tid, const uint8_t *cdb, int len)
{
	core_reset();
	core_cdb(5, 0, tid, cdb, len);
	mnu_ide_request(0, 1);
}

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }

static void write_file(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f) { fprintf(stderr, "cannot create %s\n", path); exit(2); }
	fclose(f);
}

int main(int argc, char **argv)
{
	if (argc < 2)
	{
		fprintf(stderr, "usage: maximig_test <fixture dir>\n");
		return 2;
	}
	const char *fixture = argv[1];

	char aa_rbf[1100], aa_mnu[1100], a4k_rbf[1100], a4k_mnu[1100], cfgfile[1100];
	snprintf(aa_rbf, sizeof(aa_rbf), "%s/_Computer/Maximig_a_aa3000_20261029.rbf", fixture);
	snprintf(aa_mnu, sizeof(aa_mnu), "%s/_Computer/Maximig_a_aa3000.mnu", fixture);
	snprintf(a4k_rbf, sizeof(a4k_rbf), "%s/_Computer/Maximig_20261025.rbf", fixture);
	snprintf(a4k_mnu, sizeof(a4k_mnu), "%s/_Computer/Maximig.mnu", fixture);
	snprintf(cfgfile, sizeof(cfgfile), "%s/config/Maximig.cfg", fixture);

	snprintf(logpath, sizeof(logpath), "%s/stdout_maximig.log", fixture);
	int fd = open(logpath, O_CREAT | O_TRUNC | O_WRONLY, 0644);
	if (fd < 0 || dup2(fd, 1) < 0)
	{
		fprintf(stderr, "cannot redirect stdout to %s\n", logpath);
		return 2;
	}
	close(fd);

	stub_reset();
	stub.root = fixture;
	stub.core_name = "Maximig";
	stub.home = "/media/fat/games/Amiga";
	stub.minimig_api = &fake_api;
	memset(&cfg, 0, sizeof(cfg));
	machine_fresh();

	/////////////////////////////////////////////////////////////////////
	// the probe (the mechanism itself is Main's tests/mnu): the module says
	// the core is a Minimig before anything is set up, init() comes later
	CHECK_INT(mnu_probe(aa_rbf, NULL), MNU_FAMILY_NONE);   // menu_module=0
	cfg.menu_module = 1;

	// the AA3000+: Maximig_a_aa3000_20261029.rbf takes Maximig_a_aa3000.mnu
	stub.minimig = 0;                                  // the host has not asked yet
	CHECK_INT(mnu_probe(aa_rbf, NULL), MNU_FAMILY_MINIMIG);
	CHECK_INT(mnu_family(), MNU_FAMILY_MINIMIG);
	CHECK(!mnu_active());
	CHECK(!log_has("maximig: init"));
	CHECK_INT(log_count("MNU: found"), 1);
	CHECK(log_has("runs the core as family 1"));

	/////////////////////////////////////////////////////////////////////
	// init(): the family table, a new configuration's defaults
	stub.minimig = 1;                                  // user_io's is_minimig() now says yes
	unlink(cfgfile);
	CHECK_INT(mnu_try_load(aa_rbf, NULL), 1);
	CHECK(mnu_active());
	CHECK_STR(mnu_file(), aa_mnu);
	CHECK_INT(log_count("MNU: found"), 1);
	CHECK_INT(log_count("maximig: init"), 1);
	CHECK(log_has("(AA3000+)"));
	CHECK_STR(mmcfg.kickstart, "/media/fat/games/Amiga/KICK3000.ROM");
	CHECK_INT(fk.set_kickstart_calls, 1);
	CHECK_INT(mmcfg.memory, 0x0F);                     // 2 MB chip, 16 MB motherboard RAM
	CHECK_INT(mmcfg.cpu, 0);
	CHECK_INT(mmcfg.chipset, CONFIG_AGA | CONFIG_ECS);
	CHECK_INT(mmcfg.ide_cfg, 1);
	CHECK_INT(fk.hrtmon_calls, 1);
	CHECK_INT(fk.hrtmon, 0);
	CHECK_INT(fk.resets, 1);                           // the boot again, with these
	CHECK_INT(mnu_flags(), MNU_FLAG_KEY_REPEAT);

	/////////////////////////////////////////////////////////////////////
	// the main page
	mnu_osd_opened();
	CHECK_INT(send("redraw"), MNU_ACT_STAY);
	CHECK_STR(stub.title, "AA3000+*");
	CHECK_STR(stub.rows[0], " df0: * no disk *");
	CHECK_STR(stub.rows[1], " KP +/- to add/remove drives");
	CHECK_INT(stub.row_stipple[1], 1);
	CHECK_STR(stub.rows[2], "");
	CHECK_STR(row(" SCSI 0"), " SCSI 0 : * none *");
	CHECK_STR(row(" SCSI 1"), " SCSI 1 : * none *");
	CHECK_STR(row(" ROM"), " ROM      : KICK3000.ROM");
	CHECK_STR(row(" Ext.ROM"), " Ext.ROM  : <none>");
	CHECK_STR(row(" Cartridge"), " Cartridge: Off");
	CHECK_STR(row(" CPU"), " CPU      : 68030 28MHz");
	CHECK_INT(stipple(" CPU"), 1);
	CHECK_STR(row(" Bus"), " Bus      : A3000");
	CHECK_STR(row(" MB RAM"), " MB RAM   : 16M");
	CHECK_STR(row(" Z3 RAM"), " Z3 RAM   : none");
	CHECK_STR(row(" Audio & Video"), " Audio & Video             \x16");
	CHECK_STR(row(" Settings"), " Settings                  \x16");
	CHECK_STR(row(" Load configuration"), " Load configuration        \x16");
	CHECK_STR(row(" Save configuration"), " Save configuration        \x16");
	CHECK_STR(row(" Reset"), " Reset");
	CHECK_STR(row("            exit"), "            exit");
	CHECK_INT(find(" Minimig"), -1);                   // Minimig's menu is not offered
	CHECK_STR(at(), " df0: * no disk *");

	// the cursor skips the gaps, the drive row it cannot use and the fixed CPU
	CHECK_INT(send("down"), MNU_ACT_REDRAW);
	CHECK_STR(at(), " SCSI 0 : * none *");
	CHECK_INT(send("up"), MNU_ACT_REDRAW);
	CHECK_STR(at(), " df0: * no disk *");
	CHECK_INT(send("up"), MNU_ACT_REDRAW);             // wraps
	CHECK_STR(at(), "            exit");
	go(" Cartridge");
	send("down");
	CHECK(at_is(" Bus"));

	CHECK_INT(send("back"), MNU_ACT_CLOSE);
	CHECK_INT(send("right"), MNU_ACT_SYSTEM_MENU);
	CHECK_INT(send("left"), MNU_ACT_MISC_MENU);        // MiSTer's page with Main, not Minimig's menu
	CHECK_STR(stub.title, "AA3000+*");

	// the bus timing goes to the core at once
	CHECK_INT(send("select"), MNU_ACT_REDRAW);
	CHECK_INT(mmcfg.cpu, 0x20);
	CHECK_INT(fk.config_cpu_calls, 1);
	send("redraw");
	CHECK_STR(row(" Bus"), " Bus      : Fast");
	CHECK_STR(row(" Reset"), " Reset");
	send("select");
	CHECK_INT(mmcfg.cpu, 0);

	// the RAM waits for a reset
	go(" MB RAM");
	send("select");
	send("redraw");
	CHECK_STR(row(" MB RAM"), " MB RAM   : none");
	CHECK_INT(mmcfg.memory & 0x0C, 0);
	CHECK_STR(row(" Reset"), " Reset (to apply changes)");
	send("minus");
	send("redraw");
	CHECK_STR(row(" MB RAM"), " MB RAM   : 16M");
	send("plus");
	send("plus");
	send("redraw");
	CHECK_STR(row(" MB RAM"), " MB RAM   : 4M");

	go(" Z3 RAM");
	const char *z3[] = { " Z3 RAM   : 128M", " Z3 RAM   : 256M", " Z3 RAM   : 384M", " Z3 RAM   : none" };
	for (int i = 0; i < 4; i++)
	{
		send("select");
		send("redraw");
		CHECK_STR(row(" Z3 RAM"), z3[i]);
	}
	CHECK_INT(mmcfg.memory & 0xB0, 0);
	send("minus");
	CHECK_INT(mmcfg.memory & 0xB0, 0x90);              // 384 MB: 5, bit 7 and 01 in bits 5-4
	send("plus");

	// the cartridge: Off, HRTmon, the Action Replay (ext_cfg bit 23)
	go(" Cartridge");
	send("select");
	send("redraw");
	CHECK_STR(row(" Cartridge"), " Cartridge: HRTmon");
	CHECK_INT(mmcfg.memory & 0x40, 0x40);
	CHECK_INT(mmcfg.ext_cfg2 & 0x80, 0);
	send("select");
	send("redraw");
	CHECK_STR(row(" Cartridge"), " Cartridge: Action Replay");
	CHECK_INT(mmcfg.ext_cfg2 & 0x80, 0x80);
	CHECK_INT(f_get_extcfg() & MINIMIG_EXTCFG_AR, MINIMIG_EXTCFG_AR);
	send("select");
	send("redraw");
	CHECK_STR(row(" Cartridge"), " Cartridge: Off");
	CHECK_INT(mmcfg.memory & 0x40, 0);
	CHECK_INT(mmcfg.ext_cfg2 & 0x80, 0);

	// the Kickstart and the extension ROM through the file selector
	go(" ROM");
	CHECK_INT(send("select"), MNU_ACT_STAY);
	CHECK_STR(stub.select_ext, "ROM");
	CHECK_STR(stub.select_path, "/media/fat/games/Amiga/KICK3000.ROM");
	CHECK_INT(stub.select_opts, MNU_SCAN_DIR);
	CHECK_INT(mnu_file_selected("/media/fat/games/Amiga/A3000.47.115.rom"), MNU_ACT_REDRAW);
	CHECK_STR(mmcfg.kickstart, "/media/fat/games/Amiga/A3000.47.115.rom");
	send("redraw");
	CHECK_STR(row(" ROM"), " ROM      : A3000.47.115.rom");
	go(" Ext.ROM");
	send("select");
	CHECK_INT(stub.select_opts, MNU_SCAN_DIR | MNU_SCAN_UMOUNT);
	mnu_file_selected("/media/fat/games/Amiga/maximig_ext.rom");
	CHECK_STR(fk.extrom, "/media/fat/games/Amiga/maximig_ext.rom");
	send("minus");
	CHECK_STR(fk.extrom, "");

	// a SCSI disk: the image waits for a reset, as Minimig's disk menu has it
	mmcfg.ide_cfg = 0;
	mmcfg.hardfile[1].cfg = 0;
	send("redraw");
	CHECK_STR(row(" SCSI 1"), " SCSI 1 : * disabled *");
	go(" SCSI 1");
	CHECK_INT(send("select"), MNU_ACT_STAY);
	CHECK_STR(stub.select_ext, "HDFVHDIMGDSK");
	CHECK_INT(stub.select_opts, MNU_SCAN_DIR | MNU_SCAN_UMOUNT);
	mnu_file_selected("/media/fat/games/Amiga/aa3k_1992.hdf");
	CHECK_STR(mmcfg.hardfile[1].filename, "/media/fat/games/Amiga/aa3k_1992.hdf");
	CHECK_INT(mmcfg.hardfile[1].cfg, 1);
	CHECK_INT(mmcfg.ide_cfg & 1, 1);
	send("redraw");
	CHECK_STR(row(" SCSI 1"), " SCSI 1 : aa3k_1992.hdf");
	send("select");
	mnu_file_selected("");                             // cleared
	CHECK_STR(mmcfg.hardfile[1].filename, "");
	CHECK_INT(mmcfg.hardfile[1].cfg, 1);

	// a cancelled selector changes nothing
	go(" ROM");
	send("select");
	mnu_osd_opened();
	CHECK_STR(mmcfg.kickstart, "/media/fat/games/Amiga/A3000.47.115.rom");

	// the floppies
	go(" df0");
	CHECK_INT(send("select"), MNU_ACT_STAY);
	CHECK_STR(stub.select_ext, "ADFSCP");
	mnu_file_selected("/media/fat/games/Amiga/Workbench.adf");
	CHECK_INT(fk.inserts, 1);
	CHECK_INT(fk.insert_drive, 0);
	CHECK_STR(fk.insert_path, "/media/fat/games/Amiga/Workbench.adf");
	send("redraw");
	CHECK_STR(row(" df0"), " df0: Workbench.adf");
	fk.df_status[0] = MNU_MM_DSK_INSERTED;            // write protected
	send("redraw");
	CHECK_STR(row(" df0"), " df0: Workbench.adf \x17");
	send("select");                                    // a disk in: eject
	CHECK_INT(fk.ejects, 1);
	CHECK_INT(fk.inserts, 1);
	send("plus");                                      // a second drive, after reset
	CHECK_INT(fk.requested, 2);
	send("redraw");
	CHECK_STR(stub.rows[1], " df1: * active after reset *");
	CHECK_INT(stub.row_stipple[1], 1);
	CHECK_STR(stub.rows[2], " KP +/- to add/remove drives");
	CHECK_STR(row(" SCSI 0"), " SCSI 0 : * none *");   // the rows below move down
	fk.active = 2;
	f_floppy_insert(1, "/x/b.adf");
	mnu_event_t bs;
	memset(&bs, 0, sizeof(bs));
	bs.key = 14;                                       // KEY_BACKSPACE: eject all
	CHECK_INT(send_ev(&bs), MNU_ACT_REDRAW);
	CHECK_INT(fk.ejects, 3);
	CHECK_INT(fk.df_status[1], 0);
	send("minus");
	CHECK_INT(fk.requested, 1);

	/////////////////////////////////////////////////////////////////////
	// Audio & Video: Minimig's page, on the same core bits
	go(" Audio & Video");
	CHECK_INT(send("select"), MNU_ACT_REDRAW);
	send("redraw");
	CHECK_STR(stub.title, "Audio & Video*");
	CHECK_STR(at(), " TV Standard   : PAL");
	CHECK_STR(row(" Scandoubler FX"), " Scandoubler FX: Off");
	CHECK_STR(row(" Video area by"), " Video area by : Blank");
	CHECK_STR(row(" Aspect Ratio"), " Aspect Ratio  : Original");
	CHECK_STR(row(" Pixel Clock"), " Pixel Clock   : 28MHz");
	CHECK_STR(row(" Scaling"), " Scaling       : Normal");
	CHECK_STR(row(" RTG Upscaling"), " RTG Upscaling : Normal");
	CHECK_STR(row(" Stereo mix"), " Stereo mix    : 0%");
	CHECK_STR(row(" Audio Filter"), " Audio Filter  : Auto(LED)");
	CHECK_STR(row(" Model"), " Model         : A500");
	CHECK_STR(row(" Paula Output"), " Paula Output  : Normal");
	CHECK_INT(find(" Drive Sounds"), -1);              // the AA3000+ has none
	CHECK_STR(row(" Adjust screen"), " Adjust screen position");
	CHECK_STR(row("            back"), "            back");

	send("select");                                    // TV standard
	CHECK_INT(mmcfg.chipset & CONFIG_NTSC, CONFIG_NTSC);
	CHECK_INT(fk.config_chipset_calls, 1);
	go(" Scandoubler FX");
	send("minus");
	CHECK_INT(mmcfg.scanlines & 7, 4);                 // wraps to CRT 75%
	CHECK_INT(fk.config_video_calls, 1);
	go(" Video area by");
	send("select");
	CHECK_INT(mmcfg.scanlines & 0xC0, 0x40);
	go(" Aspect Ratio");
	send("select");
	CHECK_INT((mmcfg.scanlines >> 4) & 3, 1);
	CHECK_INT(stub.ar_next_calls, 1);
	send("redraw");
	CHECK_STR(row(" Aspect Ratio"), " Aspect Ratio  : Full Screen");
	go(" Pixel Clock");
	send("select");
	CHECK_INT(f_get_extcfg() & 0x400, 0x400);
	go(" Scaling");
	send("minus");
	CHECK_INT((f_get_extcfg() >> 11) & 7, 4);          // wraps to HV-Integer
	go(" RTG Upscaling");
	send("select");
	CHECK_INT(f_get_extcfg() & 0x4000, 0x4000);
	go(" Stereo mix");
	send("plus");
	CHECK_INT(mmcfg.audio & 3, 1);
	CHECK_INT(fk.config_audio_calls, 1);
	go(" Audio Filter");
	send("select");                                    // Auto(LED) -> Off, as Minimig's
	CHECK_INT((f_get_extcfg() >> 15) & 3, 2);
	send("select");                                    // -> On
	CHECK_INT((f_get_extcfg() >> 15) & 3, 3);
	send("redraw");
	CHECK_STR(row(" Audio Filter"), " Audio Filter  : On");
	go(" Model");
	send("select");
	CHECK_INT(f_get_extcfg() & 0x20000, 0x20000);
	go(" Paula Output");
	send("select");
	CHECK_INT(f_get_extcfg() & 0x40000, 0x40000);
	CHECK_INT(mmcfg.ext_cfg2 & 0x80, 0);               // the cartridge bit untouched
	go(" Adjust screen");
	CHECK_INT(send("select"), MNU_ACT_CLOSE);
	CHECK_INT(fk.adjust, 1);
	mnu_osd_closed();
	mnu_osd_opened();
	send("redraw");
	CHECK_STR(stub.title, "AA3000+*");                  // the menu opens on its main page again
	fk.adjust = 0;

	// Left leaves a page, back to the row that opened it
	go(" Audio & Video");
	send("select");
	send("redraw");
	CHECK_STR(stub.title, "Audio & Video*");
	CHECK_INT(send("left"), MNU_ACT_REDRAW);
	CHECK_STR(at(), " Audio & Video             \x16");
	CHECK_STR(stub.title, "AA3000+*");

	/////////////////////////////////////////////////////////////////////
	// Settings
	go(" Settings");
	send("select");
	send("redraw");
	CHECK_STR(stub.title, "Settings*");
	CHECK_STR(at(), " Joystick      : Digital");
	CHECK_STR(row(" Joystick Swap"), " Joystick Swap : Off");
	CHECK_STR(row(" Ethernet"), " Ethernet      : OFF");
	CHECK_STR(row(" FDD Turbo"), " FDD Turbo     : Off");
	send("minus");                                     // Digital wraps to CD32
	CHECK_INT((mmcfg.autofire & 6) >> 1, 2);
	CHECK_INT(fk.autofire_mask, 6);
	send("plus");
	CHECK_INT((mmcfg.autofire & 6) >> 1, 0);
	go(" Joystick Swap");
	send("select");
	CHECK_INT(mmcfg.autofire & 8, 8);
	CHECK_INT(fk.autofire_mask, 8);
	go(" Ethernet");
	send("select");
	CHECK_INT(fk.net_iface, 1);                        // eth0
	send("select");
	CHECK_INT(fk.net_iface, 4);                        // eth1 and macvlan not here: tap0
	send("redraw");
	CHECK_STR(row(" Ethernet"), " Ethernet      : tap0");
	send("select");
	CHECK_INT(fk.net_iface, 0);
	send("minus");
	CHECK_INT(fk.net_iface, 4);
	go(" FDD Turbo");
	int fl = fk.config_floppy_calls;
	send("select");
	CHECK_INT(mmcfg.floppy.speed, 1);
	CHECK_INT(fk.config_floppy_calls, fl + 1);
	go("            back");
	CHECK_INT(send("select"), MNU_ACT_REDRAW);
	CHECK_STR(at(), " Settings                  \x16");

	/////////////////////////////////////////////////////////////////////
	// the configuration slots
	go(" Load configuration");
	send("select");
	send("redraw");
	CHECK_STR(stub.title, "Load config*");
	CHECK_STR(stub.rows[0], " Startup config:");
	CHECK_STR(stub.rows[1], "  AA3000+/P 2M+16M");
	CHECK_STR(stub.rows[3], " Other configs:");
	CHECK_STR(stub.rows[4], "  NO INFO");              // slot 3: there, without an info line
	CHECK_STR(stub.rows[5], "");
	CHECK_STR(at(), "  AA3000+/P 2M+16M");
	send("down");
	CHECK_STR(at(), "  NO INFO");
	CHECK_INT(send("select"), MNU_ACT_CLOSE);
	CHECK_INT(fk.cfg_loads, 1);
	CHECK_INT(fk.cfg_load_num, 3);

	mnu_osd_opened();
	go(" Save configuration");
	send("select");
	send("redraw");
	CHECK_STR(stub.title, "Save config*");
	CHECK_STR(row("  < EMPTY >"), "  < EMPTY >");      // every slot can take one
	CHECK_INT(send("select"), MNU_ACT_REDRAW);
	CHECK_INT(fk.cfg_saves, 1);
	CHECK_INT(fk.cfg_save_num, 0);
	CHECK_STR(stub.info_text, "Configuration saved");
	CHECK_STR(mmcfg.info, "AA3000+/N/SCSI 2M+4M\nA3000.47.115.rom");
	send("redraw");
	CHECK_STR(stub.title, "AA3000+*");
	CHECK_STR(at(), " Save configuration        \x16");

	// reset, exit
	go(" Reset");
	int resets = fk.resets;
	CHECK_INT(send("select"), MNU_ACT_CLOSE);
	CHECK_INT(fk.resets, resets + 1);
	send("redraw");
	CHECK_STR(row(" Reset"), " Reset");
	go("            exit");
	CHECK_INT(send("select"), MNU_ACT_CLOSE);

	/////////////////////////////////////////////////////////////////////
	// the AA3000+'s SCSI disks, through the host's request dispatch
	const uint8_t tur[6] = { 0x00, 0, 0, 0, 0, 0 };
	command(0, tur, 6);
	CHECK_INT(core.done, 1);
	CHECK_INT(core.status, 0);
	CHECK_INT(core.steps, 1);
	CHECK_INT(core.step[0], 0x8000);

	const uint8_t inq[6] = { 0x12, 0, 0, 0, 36, 0 };
	command(0, inq, 6);
	CHECK_INT(core.din_len, 36);
	CHECK_INT(core.din[0], 0x00);
	CHECK(!memcmp(core.din + 8, "MiSTer  AA3000+ HDF     ", 24));
	CHECK_INT(core.status, 0);
	command(1, inq, 6);                                // no image on target 1
	CHECK_INT(core.din[0], 0x7F);

	const uint8_t cap[10] = { 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	command(0, cap, 10);
	CHECK_INT(core.din_len, 8);
	CHECK_INT(be32(core.din), 999);
	CHECK_INT(be32(core.din + 4), 512);
	CHECK_INT(core.status, 0);

	// READ(10) of 3 sectors at 2: one Data In, the drive's bytes
	const uint8_t rd[10] = { 0x28, 0, 0, 0, 0, 2, 0, 0, 3, 0 };
	command(0, rd, 10);
	CHECK_INT(fk.reads, 1);
	CHECK_INT(fk.read_port, 0);
	CHECK_INT(fk.read_drv, 0);
	CHECK_INT(fk.read_lba, 2);
	CHECK_INT(fk.read_cnt, 3);
	CHECK_INT(core.din_len, 3 * 512);
	int same = 1;
	for (uint32_t i = 0; i < 3 * 512; i++) if (core.din[i] != pattern(0, 2 + i / 512, i % 512)) same = 0;
	CHECK(same);
	CHECK_INT(core.step[0], 0x0000 | (3 * 512));
	CHECK_INT(core.status, 0);
	CHECK_INT(core.other_port, 0);

	// READ(10) of 20 sectors: the 8 KB buffer twice, 16 sectors and 4
	const uint8_t rd20[10] = { 0x28, 0, 0, 0, 0, 10, 0, 0, 20, 0 };
	command(0, rd20, 10);
	CHECK_INT(fk.reads, 3);
	CHECK_INT(core.steps, 3);
	CHECK_INT(core.step[0], 16 * 512);
	CHECK_INT(core.step[1], 4 * 512);
	CHECK_INT(core.din_len, 20 * 512);
	same = 1;
	for (uint32_t i = 0; i < 20 * 512; i++) if (core.din[i] != pattern(0, 10 + i / 512, i % 512)) same = 0;
	CHECK(same);
	CHECK_INT(core.status, 0);

	// WRITE(10) of 2 sectors at 5 to target 1: one Data Out
	fk.present[1] = 1;
	core_reset();
	for (uint32_t i = 0; i < 1024; i++) core.dout[i] = (uint8_t)(i * 3 + 1);
	const uint8_t wr[10] = { 0x2A, 0, 0, 0, 0, 5, 0, 0, 2, 0 };
	core_cdb(6, 0, 1, wr, 10);
	mnu_ide_request(0, 1);
	CHECK_INT(fk.writes, 1);
	CHECK_INT(fk.write_port, 0);
	CHECK_INT(fk.write_drv, 1);
	CHECK_INT(fk.write_lba, 5);
	CHECK_INT(fk.write_cnt, 2);
	same = 1;
	for (uint32_t i = 0; i < 1024; i++) if (fk.written[i] != (uint8_t)(i * 3 + 1)) same = 0;
	CHECK(same);
	CHECK_INT(core.step[0], 0x4000 | 1024);
	CHECK_INT(core.status, 0);

	// past the end: CHECK CONDITION, then the sense says why
	const uint8_t far[10] = { 0x28, 0, 0, 0, 0x03, 0xE7, 0, 0, 2, 0 };
	command(0, far, 10);
	CHECK_INT(core.status, 2);
	CHECK_INT(fk.reads, 3);
	const uint8_t sense[6] = { 0x03, 0, 0, 0, 18, 0 };
	command(0, sense, 6);
	CHECK_INT(core.din_len, 18);
	CHECK_INT(core.din[2], 0x05);                     // ILLEGAL REQUEST

	// requests that are not a new command, and the other channel: nothing
	core_reset();
	core_cdb(1, 0, 0, tur, 6);
	mnu_ide_request(0, 2);
	mnu_ide_request(0, 3);
	mnu_ide_request(1, 1);
	CHECK_INT(core.steps, 0);
	CHECK_INT(core.done, 0);

	// a module unloaded: requests go nowhere, the family stays
	mnu_unload(MNU_UNLOAD_COMMAND);
	CHECK(!mnu_active());
	CHECK_INT(mnu_family(), MNU_FAMILY_MINIMIG);
	command(0, tur, 6);
	CHECK_INT(core.done, 0);

	/////////////////////////////////////////////////////////////////////
	// with a configuration of its own: no defaults, and no second boot
	// unless HRTmon needs telling there is no Gayle IDE
	write_file(cfgfile);
	machine_fresh();
	CHECK_INT(mnu_load(aa_mnu), 1);
	CHECK_STR(mmcfg.kickstart, "/media/fat/games/Amiga/KICK.ROM");
	CHECK_INT(mmcfg.memory, 0x11);
	CHECK_INT(fk.resets, 0);
	CHECK_INT(fk.hrtmon, 0);
	mnu_unload(MNU_UNLOAD_COMMAND);

	machine_fresh();
	mmcfg.memory |= 0x40;                              // HRTmon
	CHECK_INT(mnu_load(aa_mnu), 1);
	CHECK_INT(fk.resets, 1);
	mnu_unload(MNU_UNLOAD_COMMAND);

	machine_fresh();
	mmcfg.memory |= 0x40;
	mmcfg.ext_cfg2 |= MINIMIG_EXTCFG_AR >> 16;         // the Action Replay
	CHECK_INT(mnu_load(aa_mnu), 1);
	CHECK_INT(fk.resets, 0);
	mnu_unload(MNU_UNLOAD_COMMAND);

	/////////////////////////////////////////////////////////////////////
	// the A4000 builds: the CPU card and its clock, IDE disks, no SCSI
	unlink(cfgfile);
	machine_fresh();
	CHECK_INT(mnu_try_load(a4k_rbf, NULL), 1);          // Maximig_20261025.rbf takes Maximig.mnu
	CHECK_STR(mnu_file(), a4k_mnu);
	CHECK(log_has("(A4000)"));
	CHECK_STR(mmcfg.kickstart, "/media/fat/games/Amiga/KICK4000.ROM");
	mnu_osd_opened();
	send("redraw");
	CHECK_STR(stub.title, "Maximig*");
	CHECK_STR(row(" IDE  0"), " IDE  0 : * none *");
	CHECK_STR(row(" CPU"), " CPU      : A3640 25MHz");
	CHECK_INT(stipple(" CPU"), 0);
	CHECK_STR(row(" Bus"), " Bus      : A4000");
	go(" CPU");
	const char *cpu[] = { " CPU      : A3640 33MHz", " CPU      : A3640 50MHz", " CPU      : A3640 56MHz",
	                      " CPU      : BFG9060 25MHz", " CPU      : BFG9060 37.5MHz", " CPU      : BFG9060 50MHz",
	                      " CPU      : A3640 25MHz" };
	for (int i = 0; i < 7; i++)
	{
		send("select");
		send("redraw");
		CHECK_STR(row(" CPU"), cpu[i]);
		if (i == 3) CHECK_INT(mmcfg.ext_cfg2 & 0x100, 0x100);   // the BFG9060: ext_cfg bit 24
	}
	CHECK_INT(mmcfg.ext_cfg2 & 0x100, 0);
	CHECK_INT(fk.config_cpu_calls, 7);
	send("minus");
	send("redraw");
	CHECK_STR(row(" CPU"), cpu[5]);
	go(" Z3 RAM");                                     // the BFG9060: none or 256 MB
	send("select");
	send("redraw");
	CHECK_STR(row(" Z3 RAM"), " Z3 RAM   : 256M");
	send("select");
	send("redraw");
	CHECK_STR(row(" Z3 RAM"), " Z3 RAM   : none");

	// the drive sounds: the A4000 builds have them
	go(" Audio & Video");
	send("select");
	send("redraw");
	CHECK_STR(row(" Drive Sounds"), " Drive Sounds  : No file");
	fk.dsnd = 1;
	go(" Drive Sounds");
	send("select");
	send("redraw");
	CHECK_STR(row(" Drive Sounds"), " Drive Sounds  : Quiet");
	CHECK_INT((f_get_extcfg() >> 19) & 3, 1);
	send("left");

	command(0, tur, 6);                                // no SCSI on the A4000
	CHECK_INT(core.done, 0);
	CHECK_INT(core.steps, 0);
	mnu_unload(MNU_UNLOAD_CORE_EXIT);

	/////////////////////////////////////////////////////////////////////
	// no family table (a host that does not run the core as a Minimig)
	stub.minimig = 0;
	machine_fresh();
	CHECK_INT(mnu_load(aa_mnu), 0);
	CHECK(!mnu_active());
	CHECK(log_has("init() returned 3"));

	fprintf(stderr, "maximig_test: %d checks, %d failures\n", checks, failures);
	if (failures) dump_log();
	return failures ? 1 : 0;
}
