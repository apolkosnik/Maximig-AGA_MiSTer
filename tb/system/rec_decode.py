#!/usr/bin/env python3
# Decode a recording of the PC sampler's rings (a MAXIMIG_PCSAMPLE build):
# the 8 KB at DDR3 0x27FF6000, from the bench's --ddrdump or the board's
# memdump (each long word byte-reversed, as all Amiga data in DDR3 is).
#
#   rec_decode.py DUMP [N]          print the header, the last N (48) retired
#                                   uops and bus beats, the front-end events
#   rec_decode.py DUMP --check-rtr  t_rtr's verdict: exit 0 when the ring froze
#                                   at $100 and holds what the test expects
import struct, sys

NAMES = {1: "BE-redirect", 2: "DEC-redirect", 3: "BTB", 4: "exc-flush", 5: "handler-fetch"}
FLAGS = (("x", 0x80), ("F", 0x40), ("L", 0x20), ("K", 0x10), ("R", 0x08), ("P", 0x04))

class Rec:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        hdr = self.w(0x10C)
        self.frozen = (hdr >> 8) & 0xff == 0x5A
        self.wp = hdr & 0xff

    def w(self, off):
        return struct.unpack('>I', self.d[off:off+4])[0]

    def events(self):
        out = []
        for i in range(32):
            a, t = self.w(0x200 + i * 8), self.w(0x204 + i * 8)
            if (a >> 24) == 0xE5:
                out.append((a & 0xff, (a >> 16) & 7, t))
        return out

    def uops(self):
        """(slot, pc, info) oldest first"""
        out = []
        for i in range(256):
            s = (self.wp + i) & 0xff
            out.append((s, self.w(0x400 + s * 4), self.w(0x800 + s * 4) & 0xffff))
        return out

    def beats(self):
        """(addr, data, flags) oldest first"""
        return [(self.w(0x1000 + s * 16), self.w(0x1004 + s * 16), self.w(0x1008 + s * 16)) for s in range(256)]

def flags(inf):
    return "".join(c if inf & b else "." for c, b in FLAGS)

def show(r, n):
    print("header %s wp=%d" % ("FROZEN" if r.frozen else "live", r.wp))
    print("samples %d, ack/nmi %08x, live pc %08x" % (r.w(0x100), r.w(0x104), r.w(0x108)))
    print("last exception: vector %d ($%02x) stacked pc %08x" % (r.w(0x110), r.w(0x110) * 4, r.w(0x114)))
    f3 = r.w(0x120)
    print("handler fetch: data %08x A %08x src=%d job=%d pc %08x" % (r.w(0x118), r.w(0x11C), (f3 >> 30) & 3, (f3 >> 24) & 0x3f, r.w(0x124)))
    sn = r.w(0x100) & 63
    print("live samples (oldest first):")
    print("  " + " ".join("%08x" % r.w(((sn + i) & 63) * 4) for i in range(64)))
    print("front-end events (oldest first; slot numbers mod 256):")
    for slot, t, tgt in r.events():
        print("  slot %3d %-14s %08x" % (slot, NAMES.get(t, "?"), tgt))
    print("retired uops, newest last (slot: pc  exc  exr first last kill eredir excpend):")
    for s, pc, inf in r.uops()[-n:]:
        print("  %3d: %08x  exc=%02x %s" % (s, pc, inf >> 8, flags(inf)))
    print("bus beats, newest last (addr data tgt flags):")
    for i, (a, d, f) in enumerate(r.beats()):
        if i < 256 - n:
            continue
        fl = "%s%s be=%x tt=%d tm=%d%s beat=%d" % ("BERR " if f & (1 << 26) else "", "W" if f & (1 << 25) else "R",
                                                   (f >> 21) & 15, (f >> 19) & 3, (f >> 16) & 7, " line" if f & (1 << 15) else "", (f >> 13) & 3)
        print("  %3d: %08x %08x tgt=%2d %s" % (i, a, d, f >> 27, fl))

def check_rtr(r):
    """t_rtr: the ring froze at the landing at $100 after a loop under
    level-2 interrupts"""
    bad = []
    if not r.frozen:
        bad.append("the ring did not freeze")
        return bad
    u = r.uops()
    s, pc, inf = u[-1]
    if pc != 0x100 or inf & 0x60 != 0x60:
        bad.append("the newest entry is %08x %s, not $100 with first and last" % (pc, flags(inf)))
    # an interrupt: a uop with the kill bit, then the routine's retire (exr) at PC 0
    irq = [i for i in range(1, 256) if u[i][1] == 0 and u[i][2] & 0x80 and u[i-1][2] & 0x10]
    if not irq:
        bad.append("no interrupt entry (a killed uop, then the routine's retire at PC 0)")
    if r.w(0x110) != 26:
        bad.append("the last exception's vector is %d, not 26 (level 2)" % r.w(0x110))
    if not any(t == 5 and tgt == r.w(0x118) for _, t, tgt in r.events()):
        bad.append("no handler-fetch event with the handler fetch's data")
    if not any(a == 0x68 and not f & (1 << 25) for a, d, f in r.beats()):
        bad.append("no read of the level-2 vector at $68 in the bus ring")
    if any(inf >> 8 for _, _, inf in u):
        bad.append("an entry with an exception code")
    return bad

def main():
    args = sys.argv[1:]
    check = "--check-rtr" in args
    args = [a for a in args if a != "--check-rtr"]
    r = Rec(args[0])
    if check:
        bad = check_rtr(r)
        for b in bad:
            print("rec_decode: " + b)
        print("t_rtr %s" % ("PASS" if not bad else "FAIL"))
        sys.exit(1 if bad else 0)
    show(r, int(args[1]) if len(args) > 1 else 48)

main()
