// maximig_scsi_target.h: the AA3000+'s SCSI hard disks, the HPS side
//
// The core's a3kp_scsi_hps runs the SCSI bus phases (selection, Identify,
// the CDB, Status, Command Complete) and moves the data; this runs the
// commands: it reads the CDB, fills or empties the core's 8 KB buffer and has
// the core move it, and gives the status.  Targets 0 and 1 are the drives of
// Main's IDE channel 0.  The same file is Main's (support/minimig, through
// ide.cpp) and the Maximig system bench's (tb/system/sim_main.cpp): only the
// transport (scsi_io) and the image (scsi_disk) differ.
//
// The core's registers (Main's IDE channel 0 management port):
//   0  read {4'hA, seq, 0, LUN, 0, target}; write {.., seq}: the buffer
//      cursor to its start, and the command a step is for
//   1-6  read: the CDB, two bytes a register, the first low
//   8  write: the step -- {00, n} Data In of n buffer bytes, {01, n} Data
//      Out of n bytes into it, {10, status}: Status, Command Complete
//   15 the buffer: a word an access, its first byte low
// Requests (the channel's three bits): 1 a CDB is in, 2 a Data Out filled
// the buffer, 3 a Data In sent it.
//
// Commands (SCSI-2, direct access): TEST UNIT READY, REZERO UNIT, REQUEST
// SENSE, FORMAT UNIT, READ(6), WRITE(6), SEEK(6), INQUIRY, MODE SELECT(6),
// RESERVE, RELEASE, MODE SENSE(6) (the block descriptor, pages 3 and 4 from
// the drive's geometry), START STOP UNIT, SEND DIAGNOSTIC, PREVENT ALLOW
// MEDIUM REMOVAL, READ CAPACITY, READ(10), WRITE(10), SEEK(10), VERIFY,
// SYNCHRONIZE CACHE, READ DEFECT DATA (an empty list), MODE SELECT(10), MODE
// SENSE(10).  Anything else: CHECK CONDITION, ILLEGAL REQUEST / INVALID
// COMMAND OPERATION CODE.  LUNs other than 0 answer INQUIRY with peripheral
// qualifier 3 and anything else with LOGICAL UNIT NOT SUPPORTED.

#ifndef MAXIMIG_SCSI_TARGET_H
#define MAXIMIG_SCSI_TARGET_H

#include <stdint.h>
#include <string.h>

struct scsi_io
{
	void *ctx;
	void     (*wr)(void *ctx, int reg, uint16_t v);
	void     (*rdregs)(void *ctx, uint16_t *v, int n);          // registers 0 .. n-1
	void     (*wrbuf)(void *ctx, const uint16_t *w, int n);     // n words to register 15
	void     (*rdbuf)(void *ctx, uint16_t *w, int n);           // n words from register 15
	int      (*wait)(void *ctx);                                // the next request (0: none came)
};

struct scsi_disk
{
	void *ctx;
	int      present;
	uint32_t sectors;
	uint16_t cylinders, heads, spt;
	// cnt sectors (at most 16) at lba to / from buf; nonzero on success
	int (*read)(void *ctx, uint32_t lba, uint8_t *buf, uint32_t cnt);
	int (*write)(void *ctx, uint32_t lba, const uint8_t *buf, uint32_t cnt);
};

enum { SCSI_RQ_CMD = 1, SCSI_RQ_DOUT = 2, SCSI_RQ_DIN = 3 };
static const uint32_t SCSI_BUF = 8192;      // the core's buffer

struct scsi_target
{
	uint8_t skey[2], sasc[2];
};

static inline void scsi_sense(scsi_target *t, int tid, uint8_t key, uint8_t asc)
{
	t->skey[tid] = key;
	t->sasc[tid] = asc;
}

// a Data In of n bytes (at most SCSI_BUF); 0 if the command went away
static inline int scsi_din(scsi_io *io, int seq, const uint8_t *b, uint32_t n)
{
	uint16_t w[SCSI_BUF / 2];
	memset(w, 0, sizeof(w));
	for (uint32_t i = 0; i < n; i++) w[i >> 1] |= (uint16_t)(b[i] << ((i & 1) * 8));
	io->wr(io->ctx, 0, (uint16_t)seq);
	io->wrbuf(io->ctx, w, (int)((n + 1) / 2));
	io->wr(io->ctx, 8, (uint16_t)(0x0000 | n));
	return io->wait(io->ctx) == SCSI_RQ_DIN;
}

// a Data Out of n bytes; 0 if the command went away
static inline int scsi_dout(scsi_io *io, int seq, uint8_t *b, uint32_t n)
{
	uint16_t w[SCSI_BUF / 2];
	io->wr(io->ctx, 0, (uint16_t)seq);
	io->wr(io->ctx, 8, (uint16_t)(0x4000 | n));
	if (io->wait(io->ctx) != SCSI_RQ_DOUT) return 0;
	io->wr(io->ctx, 0, (uint16_t)seq);
	io->rdbuf(io->ctx, w, (int)((n + 1) / 2));
	for (uint32_t i = 0; i < n; i++) b[i] = (uint8_t)(w[i >> 1] >> ((i & 1) * 8));
	return 1;
}

static inline void scsi_status(scsi_io *io, int seq, uint8_t status)
{
	io->wr(io->ctx, 0, (uint16_t)seq);
	io->wr(io->ctx, 8, (uint16_t)(0x8000 | status));
}

static inline void scsi_put32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

// MODE SENSE pages: 3 (format device), 4 (rigid disk geometry), 24 bytes each
static inline void scsi_page(uint8_t *p, int pg, const scsi_disk *d)
{
	memset(p, 0, 24);
	p[0] = (uint8_t)pg;
	p[1] = 0x16;
	if (pg == 3) {
		p[3]  = (uint8_t)d->heads;        // tracks per zone
		p[11] = (uint8_t)d->spt;          // sectors per track
		p[12] = 0x02;                     // 512 bytes per sector
		p[15] = 0x01;                     // interleave 1
		p[20] = 0x40;                     // hard sectored
	}
	else {
		p[3]  = (uint8_t)(d->cylinders >> 8);
		p[4]  = (uint8_t)d->cylinders;
		p[5]  = (uint8_t)d->heads;
		p[20] = 0x1C;                     // 7200 rpm
		p[21] = 0x20;
	}
}

// one command (request 1): run it to its status
static inline void scsi_command(scsi_target *t, scsi_io *io, scsi_disk *disks)
{
	uint16_t r[7];
	uint8_t  cdb[12], b[SCSI_BUF];
	io->rdregs(io->ctx, r, 7);
	if ((r[0] >> 12) != 0xA) return;
	int seq = (r[0] >> 8) & 15, lun = (r[0] >> 4) & 7, tid = r[0] & 1;
	for (int i = 0; i < 12; i++) cdb[i] = (uint8_t)(r[1 + i / 2] >> ((i & 1) * 8));
	scsi_disk *d = &disks[tid];
	uint8_t op = cdb[0];
	uint32_t alloc6 = cdb[4], len10 = ((uint32_t)cdb[7] << 8) | cdb[8];
	uint32_t n = 0;

	if (op == 0x12) {
		// INQUIRY (any LUN)
		memset(b, 0, 36);
		b[0] = (lun == 0 && d->present) ? 0x00 : 0x7F;
		b[2] = 0x02;                      // SCSI-2
		b[3] = 0x02;                      // response format
		b[4] = 31;
		memcpy(b + 8, "MiSTer  AA3000+ HDF     ", 24);
		memcpy(b + 32, "1.0 ", 4);
		n = alloc6 < 36 ? alloc6 : 36;
		if (n && !scsi_din(io, seq, b, n)) return;
		scsi_status(io, seq, 0x00);
		return;
	}
	if (op == 0x03) {
		// REQUEST SENSE (any LUN): the sense is then cleared
		memset(b, 0, 18);
		b[0]  = 0x70;
		b[2]  = (lun != 0) ? 0x05 : t->skey[tid];
		b[7]  = 10;
		b[12] = (lun != 0) ? 0x25 : t->sasc[tid];
		n = cdb[4] ? cdb[4] : 4;
		if (n > 18) n = 18;
		if (!scsi_din(io, seq, b, n)) return;
		if (lun == 0) scsi_sense(t, tid, 0, 0);
		scsi_status(io, seq, 0x00);
		return;
	}
	if (lun != 0) { scsi_status(io, seq, 0x02); return; }

	scsi_sense(t, tid, 0, 0);
	switch (op) {
	case 0x00: case 0x01: case 0x04: case 0x0B: case 0x16: case 0x17: case 0x1B:
	case 0x1D: case 0x1E: case 0x2B: case 0x2F: case 0x35:
		scsi_status(io, seq, 0x00);       // nothing to move
		return;

	case 0x15: case 0x55: {
		// MODE SELECT: the parameter list is taken and ignored
		uint32_t left = (op == 0x15) ? alloc6 : len10;
		while (left) {
			uint32_t c = left > SCSI_BUF ? SCSI_BUF : left;
			if (!scsi_dout(io, seq, b, c)) return;
			left -= c;
		}
		scsi_status(io, seq, 0x00);
		return;
	}

	case 0x1A: case 0x5A: {
		// MODE SENSE: header (4 or 8 bytes), block descriptor (8 unless DBD),
		// pages 3, 4 or all ($3F)
		uint32_t hl = (op == 0x1A) ? 4 : 8, bdl = (cdb[1] & 0x08) ? 0 : 8, pl;
		int pg = cdb[2] & 0x3F;
		pl = (pg == 0x3F) ? 48 : (pg == 3 || pg == 4) ? 24 : 0;
		memset(b, 0, 64);
		uint32_t len = hl + bdl + pl;
		if (op == 0x1A) { b[0] = (uint8_t)(len - 1); b[3] = (uint8_t)bdl; }
		else            { b[1] = (uint8_t)(len - 2); b[7] = (uint8_t)bdl; }
		// (the descriptor: density 0, the number of blocks in 24 bits -- the
		// most it holds for a larger disk -- 512-byte blocks)
		if (bdl) { scsi_put32(b + hl, d->sectors > 0xFFFFFF ? 0xFFFFFF : d->sectors); b[hl] = 0; b[hl + 6] = 0x02; }
		if (pg == 0x3F) { scsi_page(b + hl + bdl, 3, d); scsi_page(b + hl + bdl + 24, 4, d); }
		else if (pl)    scsi_page(b + hl + bdl, pg, d);
		uint32_t lim = (op == 0x1A) ? alloc6 : len10;
		n = len < lim ? len : lim;
		if (n && !scsi_din(io, seq, b, n)) return;
		scsi_status(io, seq, 0x00);
		return;
	}

	case 0x25:
		// READ CAPACITY: the last block, 512-byte blocks
		memset(b, 0, 8);
		scsi_put32(b, d->sectors - 1);
		b[6] = 0x02;
		if (!scsi_din(io, seq, b, 8)) return;
		scsi_status(io, seq, 0x00);
		return;

	case 0x37:
		// READ DEFECT DATA: an empty list in the requested format
		memset(b, 0, 4);
		b[1] = cdb[2] & 0x1F;
		n = len10 < 4 ? len10 : 4;
		if (n && !scsi_din(io, seq, b, n)) return;
		scsi_status(io, seq, 0x00);
		return;

	case 0x08: case 0x0A: case 0x28: case 0x2A: {
		uint32_t lba, cnt;
		if (op & 0x20) { lba = ((uint32_t)cdb[2] << 24) | ((uint32_t)cdb[3] << 16) | ((uint32_t)cdb[4] << 8) | cdb[5]; cnt = len10; }
		else           { lba = ((uint32_t)(cdb[1] & 0x1F) << 16) | ((uint32_t)cdb[2] << 8) | cdb[3]; cnt = cdb[4] ? cdb[4] : 256; }
		int wr = (op & 0x02) != 0;
		if ((uint64_t)lba + cnt > d->sectors) {
			scsi_sense(t, tid, 0x05, 0x21);   // LBA out of range
			scsi_status(io, seq, 0x02);
			return;
		}
		while (cnt) {
			uint32_t c = cnt > SCSI_BUF / 512 ? SCSI_BUF / 512 : cnt;
			if (wr) {
				if (!scsi_dout(io, seq, b, c * 512)) return;
				if (!d->write(d->ctx, lba, b, c)) {
					scsi_sense(t, tid, 0x03, 0x0C);   // write error
					scsi_status(io, seq, 0x02);
					return;
				}
			}
			else {
				if (!d->read(d->ctx, lba, b, c)) {
					scsi_sense(t, tid, 0x03, 0x11);   // unrecovered read error
					scsi_status(io, seq, 0x02);
					return;
				}
				if (!scsi_din(io, seq, b, c * 512)) return;
			}
			lba += c;
			cnt -= c;
		}
		scsi_status(io, seq, 0x00);
		return;
	}

	default:
		scsi_sense(t, tid, 0x05, 0x20);       // invalid command operation code
		scsi_status(io, seq, 0x02);
		return;
	}
}

#endif
