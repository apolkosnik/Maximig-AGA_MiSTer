#!/usr/bin/env python3
"""Differential check of the blitter: random blits on the real machine
(tb/asm/t_blitter.s on the full-system simulation) against a model of the
blitter ported from WinUAE's blitter.cpp (the immediate-blit paths:
blitter_dofast, blitter_dofast_desc, actually_do_blit's line loop).

  blitter_check.py [--sim BIN] [--seed N] [--area N] [--line N] [--keep]

The generator writes the blit table (tb/asm/build/blit_tab.bin) that the ROM
executes in order; the ROM fills chip RAM with an xorshift32 stream first,
and after every blit stores DMACONR (BZERO) in a table.  The run ends with a
dump of chip RAM, which is compared with the model's memory blit by blit:

* every blit has a private 1 KB area for channels C and D, so a difference
  belongs to the blit that wrote it (sources A and B read a shared area no
  blit writes)
* BZERO after every blit
"""
import os
import random
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASM = os.path.join(HERE, '..', 'asm')

SRC = 0x20000           # A and B sources: 32 KB nobody writes
SRC_LEN = 0x8000
PRIV = 0x28000          # blit n: C and D in PRIV + n * 1 KB
PRIV_LEN = 0x400
ZTAB = 0x10000          # DMACONR after blit n at ZTAB + 2n
LTAB = 0x14000          # the last word D wrote, read as BBUSY clears
SEED0 = 0x2545F491      # the xorshift32 fill's seed (t_blitter.s)
ENTRY = 48              # bytes per table entry (t_blitter.s)
CHIP_MASK = 0x1FFFFE    # 2 MB of chip RAM

BLTCHA, BLTCHB, BLTCHC, BLTCHD = 0x800, 0x400, 0x200, 0x100
BLTDESC, BLTFC, BLTIFE, BLTEFE, BLTLINE = 0x02, 0x04, 0x08, 0x10, 0x01
BLTSIGN, BLTOVF, BLTSUD, BLTSUL, BLTAUL, BLTSING = 0x40, 0x20, 0x10, 0x08, 0x04, 0x02


# ----------------------------------------------------------------------------
# the blitter model (WinUAE blitter.cpp)
# ----------------------------------------------------------------------------

def blit_func(a, b, c, mt):
    r = 0
    for i in range(8):
        if mt & (1 << i):
            t = (a if i & 4 else ~a) & (b if i & 2 else ~b) & (c if i & 1 else ~c)
            r |= t
    return r & 0xFFFF


def fill_word(d, fc, ife):
    """build_blitfilltable: the word through the fill, LSB first"""
    out = 0
    for bit in range(8):
        m = 1 << bit
        v = d & m
        if fc:
            if ife:
                v = m
            else:
                v ^= m
        out |= v
        if d & m:
            fc = not fc
    return out, fc


class Mem:
    def __init__(self, image):
        self.m = bytearray(image)

    def rw(self, a):
        a &= CHIP_MASK
        return (self.m[a] << 8) | self.m[a + 1]

    def ww(self, a, v):
        a &= CHIP_MASK
        self.m[a] = (v >> 8) & 0xFF
        self.m[a + 1] = v & 0xFF


class Blitter:
    """blt_info and the module's statics that live from one blit to the next"""
    def __init__(self, mem):
        self.mem = mem
        self.bltcon0 = self.bltcon1 = 0
        self.afwm = self.alwm = 0
        self.apt = self.bpt = self.cpt = self.dpt = 0
        self.amod = self.bmod = self.cmod = self.dmod = 0
        self.adat = self.bdat = self.cdat = 0
        self.aold = self.bold = 0
        self.bhold = 0
        self.ddat = 0
        self.zero = 1

    # register writes, in the ROM's order
    def w_bdat(self, v):
        # blitter_loadbdat: B shifts when written, with the BSH and DESC of now
        shift = self.bltcon1 >> 12
        if os.environ.get('BOLD0'):
            self.bold = 0
        if self.bltcon1 & BLTDESC:
            self.bhold = (((v << 16) | self.bold) >> (16 - shift)) & 0xFFFF
        else:
            self.bhold = (((self.bold << 16) | v) >> shift) & 0xFFFF
        self.bold = v
        self.bdat = v

    def start(self, h, v):
        # blitter_start_init
        self.aold = 0
        self.bold = 0
        self.zero = 1
        if self.bltcon1 & BLTLINE:
            self.line(v)
        elif self.bltcon1 & BLTDESC:
            self.area(h, v, -1)
        else:
            self.area(h, v, 1)

    def area(self, hs, vs, dirn):
        mem = self.mem
        c0 = self.bltcon0
        mt = c0 & 0xFF
        ash = c0 >> 12
        bsh = self.bltcon1 >> 12
        fill = (self.bltcon1 & (BLTIFE | BLTEFE)) != 0
        ife = (self.bltcon1 & (BLTIFE | BLTEFE)) == BLTIFE
        mask = [0xFFFF] * hs
        mask[0] = self.afwm
        mask[hs - 1] &= self.alwm
        ap = self.apt if c0 & BLTCHA else None
        bp = self.bpt if c0 & BLTCHB else None
        cp = self.cpt if c0 & BLTCHC else None
        dp = self.dpt if c0 & BLTCHD else None
        step = 2 * dirn
        # the pointers' final values
        if ap is not None:
            self.apt += dirn * (hs * 2 + self.amod) * vs
        if bp is not None:
            self.bpt += dirn * (hs * 2 + self.bmod) * vs
        if cp is not None:
            self.cpt += dirn * (hs * 2 + self.cmod) * vs
        if dp is not None:
            self.dpt += dirn * (hs * 2 + self.dmod) * vs
        bhold = self.bhold
        dstp, dodst = 0, False
        for j in range(vs):
            fc = (self.bltcon1 & BLTFC) != 0
            for i in range(hs):
                if ap is not None:
                    self.adat = mem.rw(ap)
                    ap += step
                a = self.adat & mask[i]
                if dirn > 0:
                    ahold = ((self.aold << 16) | a) >> ash
                else:
                    ahold = ((a << 16) | self.aold) >> (16 - ash)
                ahold &= 0xFFFF
                self.aold = a
                if bp is not None:
                    b = mem.rw(bp)
                    bp += step
                    if dirn > 0:
                        bhold = ((self.bold << 16) | b) >> bsh
                    else:
                        bhold = ((b << 16) | self.bold) >> (16 - bsh)
                    bhold &= 0xFFFF
                    self.bold = b
                    self.bdat = b
                if cp is not None:
                    self.cdat = mem.rw(cp)
                    if dirn < 0:
                        self.bdat = self.cdat     # (as blitter_dofast_desc)
                    cp += step
                if dodst:
                    mem.ww(dstp, self.ddat)
                d = blit_func(ahold, bhold, self.cdat, mt)
                if fill:
                    lo, fc = fill_word(d & 0xFF, fc, ife)
                    hi, fc = fill_word(d >> 8, fc, ife)
                    d = lo | (hi << 8)
                self.ddat = d
                if d:
                    self.zero = 0
                if dp is not None:
                    dodst = True
                    dstp = dp
                    dp += step
            if ap is not None:
                ap += dirn * self.amod
            if bp is not None:
                bp += dirn * self.bmod
            if cp is not None:
                cp += dirn * self.cmod
            if dp is not None:
                dp += dirn * self.dmod
        if dodst:
            mem.ww(dstp, self.ddat)
        self.bhold = bhold

    def line(self, vs):
        """actually_do_blit, line mode, BLTSIZE width 2"""
        mem = self.mem
        s = {'onedot': 0, 'pixel': 0, 'loop': 1, 'ovf': 1 if self.bltcon1 & BLTOVF else 0}
        bsh = self.bltcon1 >> 12
        blineb = [((self.bdat >> bsh) | (self.bdat << (16 - bsh))) & 0xFFFFFFFF]
        holds = [0, 0, 0]

        def con1(bit):
            return (self.bltcon1 & bit) != 0

        def minterm(last):
            m = self.afwm
            if last:
                m &= self.alwm
            ash = self.bltcon0 >> 12
            ahold = ((self.adat & m) >> ash) & 0xFFFF
            if self.bltcon0 & BLTCHB:
                b = self.bltcon1 >> 12
                blineb[0] = ((self.bold << 16) | self.bdat) >> b
            self.bhold = 0xFFFF if blineb[0] & 1 else 0
            holds[:] = [ahold, self.bhold, self.cdat]

        def doblit_last():
            d = blit_func(holds[0], holds[1], holds[2], self.bltcon0 & 0xFF)
            if d:
                self.zero = 0
            self.ddat = d

        def incx():
            if (self.bltcon0 >> 12) == 15:
                self.cpt += 2
            s['ovf'] = 1

        def decx():
            if (self.bltcon0 >> 12) == 0:
                self.cpt -= 2
            s['ovf'] = -1

        def decy():
            if self.bltcon0 & BLTCHC:
                self.cpt -= self.cmod
                s['onedot'] = 0

        def incy():
            if self.bltcon0 & BLTCHC:
                self.cpt += self.cmod
                s['onedot'] = 0

        def cpt_y():
            sign = con1(BLTSIGN)
            if not sign and con1(BLTSUD):
                decy() if con1(BLTSUL) else incy()
            if not con1(BLTSUD):
                decy() if con1(BLTAUL) else incy()

        def cpt_x():
            sign = con1(BLTSIGN)
            if not sign and not con1(BLTSUD):
                decx() if con1(BLTSUL) else incx()
            if con1(BLTSUD):
                decx() if con1(BLTAUL) else incx()

        while True:
            # proc_status
            s['pixel'] = 1 if (not con1(BLTSING) or not s['onedot']) else 0
            s['onedot'] = 1
            # proc_apt
            if self.bltcon0 & BLTCHA:
                m = self.bmod if con1(BLTSIGN) else self.amod
                self.apt = (self.apt + m) & 0xFFFFFFFF
            # width > 1
            if self.bltcon0 & BLTCHB:
                self.bdat = mem.rw(self.bpt)
                self.bpt += self.bmod
            if self.bltcon0 & BLTCHC:
                self.cdat = mem.rw(self.cpt)
            minterm(False)
            doblit_last()
            cpt_x()
            # adat (bltaold: no effect on the output)
            # ovf
            ash = ((self.bltcon0 >> 12) + s['ovf']) & 15
            self.bltcon0 = (self.bltcon0 & 0x0FFF) | (ash << 12)
            s['ovf'] = 0
            if s['loop']:
                cpt_y()
                s['loop'] = 0
            # sign
            if (self.apt & 0x8000):
                self.bltcon1 |= BLTSIGN
            else:
                self.bltcon1 &= ~BLTSIGN
            # nxline
            b = ((self.bltcon1 >> 12) - 1) & 15
            blineb[0] = ((self.bdat >> b) | (self.bdat << (16 - b))) & 0xFFFFFFFF
            self.bltcon1 = (self.bltcon1 & 0x0FFF) | (b << 12)
            if s['pixel']:
                if self.bltcon0 & BLTCHC:
                    mem.ww(self.dpt, self.ddat)
                s['pixel'] = 0
            self.dpt = self.cpt
            minterm(True)
            doblit_last()
            s['loop'] = 1
            vs -= 1
            if vs == 0:
                break


# ----------------------------------------------------------------------------
# the blits
# ----------------------------------------------------------------------------

def touched(p, w, h, mod, dirn):
    """the lowest and highest byte offset from p a channel touches"""
    lo = hi = 0
    for j in range(h):
        row = dirn * j * (2 * w + mod)
        for o in (row, row + dirn * 2 * (w - 1)):
            lo, hi = min(lo, o), max(hi, o + 1)
    return lo, hi


def place(rng, base, length, lo, hi):
    """a word address p for a channel touching [p+lo, p+hi) inside the area"""
    span = hi - lo
    if span > length:
        return None
    off = rng.randrange(0, (length - span) // 2 + 1) * 2
    return base - lo + off


def gen_area(rng, n):
    """one area (normal mode) blit; None if the draw does not fit"""
    e = {}
    big = rng.random() < 0.06
    if big:
        w = 64 if rng.random() < 0.5 else rng.choice([33, 47, 100])
        h = rng.randint(1, 3)
    else:
        w = rng.choice([1, 1, 2, 3]) if rng.random() < 0.3 else rng.randint(1, 12)
        h = rng.randint(1, 10)
    desc = rng.random() < 0.35
    dirn = -1 if desc else 1
    use = rng.randrange(16)
    if rng.random() < 0.85:
        use |= 1
    lf = rng.choice([0xF0, 0xCC, 0xAA, 0xCA, 0xE2, 0x0A, 0x5A, 0xFF, 0x00, 0xC0]) \
        if rng.random() < 0.3 else rng.randrange(256)
    ash, bsh = rng.randrange(16), rng.randrange(16)
    con1 = (bsh << 12) | (BLTDESC if desc else 0)
    if rng.random() < 0.3:
        con1 |= rng.choice([BLTIFE, BLTEFE, BLTIFE | BLTEFE])
        if rng.random() < 0.5:
            con1 |= BLTFC
    e['con0'] = (ash << 12) | (use << 8) | lf
    e['con1'] = con1
    e['afwm'] = 0xFFFF if rng.random() < 0.4 else rng.randrange(0x10000)
    e['alwm'] = 0xFFFF if rng.random() < 0.4 else rng.randrange(0x10000)
    for ch in 'ab':
        mod = rng.randrange(-24, 40, 2) if not big else rng.randrange(-8, 16, 2)
        lo, hi = touched(0, w, h, mod, dirn)
        p = place(rng, SRC, SRC_LEN, lo, hi)
        if p is None:
            return None
        e[ch + 'mod'], e[ch + 'pt'] = mod, p
    base = PRIV + n * PRIV_LEN
    if rng.random() < 0.5:
        # cookie cut: C and D the same words
        mod = rng.randrange(-8, 26, 2)
        if w * 2 + mod <= 0 and h > 1 and rng.random() < 0.7:
            mod = 0
        lo, hi = touched(0, w, h, mod, dirn)
        p = place(rng, base, PRIV_LEN, lo, hi)
        if p is None:
            return None
        e['cmod'] = e['dmod'] = mod
        e['cpt'] = e['dpt'] = p
    else:
        for ch in 'cd':
            mod = rng.randrange(-8, 26, 2)
            lo, hi = touched(0, w, h, mod, dirn)
            p = place(rng, base, PRIV_LEN, lo, hi)
            if p is None:
                return None
            e[ch + 'mod'], e[ch + 'pt'] = mod, p
    e['adat'], e['bdat'], e['cdat'] = (rng.randrange(0x10000) for _ in range(3))
    if w <= 64 and h <= 1024 and rng.random() < 0.8:
        e['size'] = ((h & 1023) << 6) | (w & 63)
        e['sizv'] = e['sizh'] = 0
    else:
        e['size'] = 0
        e['sizv'], e['sizh'] = h, w
    e['w'], e['h'] = w, h
    e['lastd'] = 0
    if use & 1:
        e['lastd'] = e['dpt'] + dirn * ((h - 1) * (2 * w + e['dmod']) + 2 * (w - 1))
    return e


def gen_line(rng, n):
    """one line blit, set up as the Hardware Reference Manual draws a line,
    in the blit's private area as a 256 x 32 screen (32 bytes a row)"""
    e = {}
    base = PRIV + n * PRIV_LEN
    while True:
        x1, y1 = rng.randrange(256), rng.randrange(32)
        if rng.random() < 0.6:
            x2, y2 = rng.randrange(256), rng.randrange(32)
        else:
            x2 = min(255, max(0, x1 + rng.randint(-31, 31)))
            y2 = min(31, max(0, y1 + rng.randint(-31, 31)))
        dx, dy = x2 - x1, y2 - y1
        dmax, dmin = max(abs(dx), abs(dy)), min(abs(dx), abs(dy))
        use = 0xB if rng.random() < 0.7 else rng.randrange(16)
        # not B: a line blit with USEB is outside this check.  WinUAE's two
        # paths disagree (the immediate one reads B once a pixel, the
        # cycle-exact one in both words of a pixel), the RTL fetches no B in
        # line mode, and no known program draws lines with B enabled
        use &= ~4
        if not use & 8 or use & 4:
            # without A the accumulator stays (WinUAE: BLTAPT moves only with
            # USEA), with B BLTBPT walks by BLTBMOD: short lines that stay in
            # the screen whatever the steps
            if dmax > 7 or not 16 <= x1 < 240 or not 8 <= y1 < 24:
                continue
        break
    xmaj = abs(dx) >= abs(dy)
    acc = 4 * dmin - 2 * dmax
    con1 = BLTLINE
    if xmaj:
        con1 |= BLTSUD | (BLTAUL if dx < 0 else 0) | (BLTSUL if dy < 0 else 0)
    else:
        con1 |= (BLTAUL if dy < 0 else 0) | (BLTSUL if dx < 0 else 0)
    if acc < 0:
        con1 |= BLTSIGN
    if rng.random() < 0.3:
        con1 |= BLTSING
    con1 |= rng.randrange(16) << 12
    r = rng.random()
    lf = 0xCA if r < 0.4 else 0x4A if r < 0.6 else rng.randrange(256)
    e['con0'] = ((x1 & 15) << 12) | (use << 8) | lf
    e['con1'] = con1
    e['afwm'] = 0xFFFF if rng.random() < 0.9 else rng.randrange(0x10000)
    e['alwm'] = 0xFFFF if rng.random() < 0.7 else rng.randrange(0x10000)
    e['apt'] = acc & 0xFFFF
    e['amod'] = 4 * (dmin - dmax)
    e['bmod'] = 4 * dmin
    e['bpt'] = SRC + rng.randrange(0, 0x400, 2)
    p = base + y1 * 32 + (x1 >> 4) * 2
    e['cpt'] = e['dpt'] = p
    e['cmod'] = e['dmod'] = 32
    e['adat'] = 0x8000 if rng.random() < 0.9 else rng.randrange(0x10000)
    e['bdat'] = 0xFFFF if rng.random() < 0.5 else rng.randrange(0x10000)
    e['cdat'] = rng.randrange(0x10000)
    e['size'] = ((dmax + 1) << 6) | 2
    e['sizv'] = e['sizh'] = 0
    e['w'], e['h'] = 2, dmax + 1
    e['lastd'] = 0
    return e


def pack(e):
    return struct.pack('>HHHHIIIIhhhhHHHHHHI',
                       e['con0'], e['con1'], e['afwm'], e['alwm'],
                       e['apt'], e['bpt'], e['cpt'], e['dpt'],
                       e['amod'], e['bmod'], e['cmod'], e['dmod'],
                       e['adat'], e['bdat'], e['cdat'],
                       e['size'], e['sizv'], e['sizh'], e['lastd'])


def xorshift_fill(mem, start, end):
    x = SEED0
    for a in range(start, end, 4):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        mem[a:a + 4] = struct.pack('>I', x)


def describe(e):
    c0, c1 = e['con0'], e['con1']
    use = ''.join(ch for ch, b in zip('ABCD', (BLTCHA, BLTCHB, BLTCHC, BLTCHD)) if c0 & b)
    if c1 & BLTLINE:
        return ('line ASH %d USE %s LF %02X BSH %d SUD %d SUL %d AUL %d SING %d SIGN %d len %d '
                'APT %04X AMOD %d BMOD %d CPT %06X AFWM %04X ALWM %04X ADAT %04X BDAT %04X' %
                (c0 >> 12, use, c0 & 0xFF, c1 >> 12, (c1 >> 4) & 1, (c1 >> 3) & 1, (c1 >> 2) & 1,
                 (c1 >> 1) & 1, (c1 >> 6) & 1, e['h'], e['apt'], e['amod'], e['bmod'], e['cpt'],
                 e['afwm'], e['alwm'], e['adat'], e['bdat']))
    fill = {0: '', BLTIFE: ' IFE', BLTEFE: ' EFE', BLTIFE | BLTEFE: ' IFE+EFE'}[c1 & (BLTIFE | BLTEFE)]
    return ('%s %dx%d ASH %d BSH %d USE %s LF %02X%s%s AFWM %04X ALWM %04X '
            'PT %06X %06X %06X %06X MOD %d %d %d %d DAT %04X %04X %04X%s' %
            ('desc' if c1 & BLTDESC else 'asc', e['w'], e['h'], c0 >> 12, c1 >> 12, use, c0 & 0xFF,
             fill, ' FCI' if c1 & BLTFC else '', e['afwm'], e['alwm'],
             e['apt'], e['bpt'], e['cpt'], e['dpt'], e['amod'], e['bmod'], e['cmod'], e['dmod'],
             e['adat'], e['bdat'], e['cdat'], ' (BLTSIZV/H)' if e['size'] == 0 else ''))


def main():
    args = sys.argv[1:]
    sim, seed, n_area, n_line, keep = os.path.join(HERE, 'obj_tests', 'Vtb_top'), 1, 400, 250, False
    show = 12
    while args:
        a = args.pop(0)
        if a == '--sim': sim = args.pop(0)
        elif a == '--seed': seed = int(args.pop(0))
        elif a == '--area': n_area = int(args.pop(0))
        elif a == '--line': n_line = int(args.pop(0))
        elif a == '--show': show = int(args.pop(0))
        elif a == '--keep': keep = True
        else:
            print(__doc__)
            return 2
    rng = random.Random(seed)
    kinds = ['a'] * n_area + ['l'] * n_line
    rng.shuffle(kinds)
    blits = []
    for k in kinds:
        n = len(blits)
        while True:
            e = gen_area(rng, n) if k == 'a' else gen_line(rng, n)
            if e is not None:
                break
        blits.append(e)
    n = len(blits)
    fill_end = PRIV + n * PRIV_LEN
    assert fill_end <= 0x200000
    build = os.path.join(ASM, 'build')
    os.makedirs(build, exist_ok=True)
    with open(os.path.join(build, 'blit_tab.bin'), 'wb') as f:
        f.write(struct.pack('>II', n, fill_end))
        for e in blits:
            f.write(pack(e))
    subprocess.run([os.path.join(ASM, 'build.sh'), 't_blitter'], check=True, stdout=subprocess.DEVNULL)

    dump = os.path.join(build, 't_blitter_chip.bin')
    out = subprocess.run([sim, '--rom', os.path.join(build, 't_blitter.rom'), '--ms', '2000', '--quiet',
                          '--dumpchip', 'end', dump], capture_output=True, text=True).stdout
    if '[mailbox]' not in out or 'result 600D' not in out:
        print(out)
        print('t_blitter: the ROM did not finish')
        return 1
    real = open(dump, 'rb').read()

    image = bytearray(0x200000)
    xorshift_fill(image, SRC, fill_end)
    mem = Mem(image)
    bl = Blitter(mem)
    bad = 0
    for i, e in enumerate(blits):
        bl.bltcon0, bl.bltcon1 = e['con0'], e['con1']
        bl.afwm, bl.alwm = e['afwm'], e['alwm']
        bl.cpt, bl.bpt, bl.apt, bl.dpt = e['cpt'], e['bpt'], e['apt'], e['dpt']
        bl.cmod, bl.bmod, bl.amod, bl.dmod = e['cmod'], e['bmod'], e['amod'], e['dmod']
        bl.cdat = e['cdat']
        bl.w_bdat(e['bdat'])
        bl.adat = e['adat']
        bl.start(e['w'], e['h'])
        base = PRIV + i * PRIV_LEN
        diffs = [(a, mem.rw(a), (real[a] << 8) | real[a + 1]) for a in range(base, base + PRIV_LEN, 2)
                 if mem.m[a:a + 2] != real[a:a + 2]]
        zr = ((real[ZTAB + 2 * i] << 8) | real[ZTAB + 2 * i + 1]) >> 13 & 1
        early = None
        if e['lastd']:
            got = (real[LTAB + 2 * i] << 8) | real[LTAB + 2 * i + 1]
            if got != mem.rw(e['lastd']):
                early = (got, mem.rw(e['lastd']))
        if diffs or zr != bl.zero or early:
            bad += 1
            if bad <= show:
                print('blit %d: %s' % (i, describe(e)))
                if zr != bl.zero:
                    print('    BZERO %d, WinUAE %d' % (zr, bl.zero))
                if early:
                    print('    %06X read as BBUSY cleared: %04X, written %04X' % (e['lastd'], early[0], early[1]))
                for a, want, got in diffs[:8]:
                    print('    %06X: %04X, WinUAE %04X' % (a, got, want))
                if len(diffs) > 8:
                    print('    ... %d words differ' % len(diffs))
        # the sources stay as they were (and the model carries on from the
        # machine's area so one difference does not spread)
        mem.m[base:base + PRIV_LEN] = real[base:base + PRIV_LEN]
    if mem.m[SRC:SRC + SRC_LEN] != real[SRC:SRC + SRC_LEN]:
        print('the source area changed')
        bad += 1
    if not keep:
        os.remove(dump)
    print('t_blitter: %d blits, %d differ from WinUAE' % (n, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
