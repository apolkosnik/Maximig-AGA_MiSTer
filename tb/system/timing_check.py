#!/usr/bin/env python3
"""Compare t_timing (Copperline's accelprobe rows) on the simulated machine
with the real A4000 + A3640 (68040 at 25 MHz) values from accelprobe.asm.

  timing_check.py [--sim BIN] [--rom ROM] [--tol PCT] [--strict] [--fast]

The simulation runs with --z3 1 (16 MB motherboard RAM, a 128 MB Zorro III
RAM board) and --lbtrace.  Two kinds of result come out:

* The rows themselves, in E-clock ticks, against the real machine.  A row
  is the CPU's loop around its accesses as well as the bus: the CPU rows
  (6-15) are the AP68040's own timing, the bus rows (16-23) are the bus and
  the CPU's per-access overhead together.
* The board's part of the read rows, from the local-bus beats: the time of
  one line fill (four beats) against the real row's time per line.  This is
  what Gary, Ramsey, Budgie and Buster decide, and what this check gates.

Every row outside the tolerance is printed as DEVIATES.  Without --strict
only the board's line-fill times decide the exit status; --strict makes
every row count.  --fast runs the machine in Fast bus timing (deliberately
quicker than the A3640): the rows are reported, nothing is gated.
"""
import re
import subprocess
import sys

ECLK_HZ = 709379.0          # PAL E clock

# row: (what, real ticks)
REAL = {
    6:  ('move.w d2,d0 + dbra x4096', 0x01DA),
    7:  ('dbra x4096', 0x01D8),
    8:  ('mulu #$5555,d5 + dbra x4096', 0x065E),
    9:  ('trap #0 + rte x1024, SSP in chip', 0x1844),
    10: ('trap #0 + rte x1024, SSP in fast1', 0x09AD),
    11: ('bsr/rts near x4096', 0x3077),
    12: ('move.l (a2),a0 + jsr (a0) x4096', 0x5730),
    13: ('jsr/rts, target in fast1 x4096', 0x3075),
    14: ('movem 11 regs push+pop x1024', 0x0DA8),
    15: ('cpushl dc,(a0) stride 16 x4096', 0x06D9),
    16: ('chip read move.l stride 16 x4096', 0x26C3),
    17: ('chip write move.l stride 16 x4096', 0x09B7),
    19: ('fast1 (motherboard) read', 0x0ECD),
    20: ('fast1 (motherboard) write', 0x042B),
    22: ('fast2 (Zorro III) read', 0x1832),
    23: ('fast2 (Zorro III) write', 0x05EF),
}

# the read rows' windows (t_timing.s: CHIPW, FAST1W, FAST2W)
LINES = {
    16: ('chip RAM', 0x00060000, 0x00070000),
    19: ('motherboard RAM', 0x07E10000, 0x07E20000),
    22: ('Zorro III RAM', 0x40010000, 0x40020000),
}


def main():
    args = sys.argv[1:]
    sim, rom, tol, strict, fast = './obj_tests/Vtb_top', '../asm/build/t_timing.rom', 10.0, False, False
    while args:
        a = args.pop(0)
        if a == '--sim':
            sim = args.pop(0)
        elif a == '--rom':
            rom = args.pop(0)
        elif a == '--tol':
            tol = float(args.pop(0))
        elif a == '--strict':
            strict = True
        elif a == '--fast':
            fast = True
        else:
            print(__doc__)
            return 2

    p = subprocess.run([sim, '--rom', rom, '--ms', '400', '--z3', '1', '--quiet', '--lbtrace'] + (['--fast'] if fast else []),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=3600)
    # (the ROM's text comes a character at a time between the beat lines;
    # each row is a whole line, $RRxxxxxx)
    rows, beats, result = {}, [], None
    for line in p.stdout.splitlines():
        m = re.match(r'\s*([\d.]+) ms\s+([RW]) ([0-9A-F]{8}) ([0-9A-F]{8})$', line)
        if m:
            beats.append((float(m.group(1)) * 1000.0, m.group(2), int(m.group(3), 16)))
            continue
        if re.match(r'^[0-9A-F]{8}$', line) and (int(line, 16) >> 24) in REAL:
            v = int(line, 16)
            rows[v >> 24] = v & 0xFFFF
        elif line.startswith('[mailbox]'):
            result = line
    if result is None or 'result 600D' not in result:
        print('FAIL: t_timing did not complete (%s)' % (result or 'no result'))
        return 1

    fails, deviations = [], []
    print('row  %-36s %8s %8s %7s' % ('test', 'core', 'real', 'ratio'))
    for r, (what, real) in sorted(REAL.items()):
        if r not in rows:
            print('%3d  %-36s %8s %8d     -- MISSING' % (r, what, '-', real))
            fails.append(r)
            continue
        ratio = rows[r] / real
        ok = abs(ratio - 1.0) * 100.0 <= tol
        print('%3d  %-36s %8d %8d %7.2f%s' % (r, what, rows[r], real, ratio, '' if ok else '  DEVIATES'))
        if not ok:
            deviations.append(r)

    print()
    print('board line fill (4 beats) against the real row time per line:')
    for r, (name, lo, hi) in sorted(LINES.items()):
        sel = [(t, a) for (t, rw, a) in beats if rw == 'R' and lo <= a < hi]
        if len(sel) < 400:
            print('  row %d %-16s only %d beats in the window' % (r, name, len(sel)))
            fails.append(r)
            continue
        sel = sel[100:len(sel) - 100]
        intra = [sel[i + 1][0] - sel[i][0] for i in range(len(sel) - 1) if (sel[i][1] & 0xC) != 0xC]
        inter = [sel[i + 1][0] - sel[i][0] for i in range(len(sel) - 1) if (sel[i][1] & 0xC) == 0xC]
        beat = sum(intra) / len(intra)
        turn = sum(inter) / len(inter) - beat
        real_line = REAL[r][1] / ECLK_HZ / 4096 * 1e6
        ratio = 4 * beat / real_line
        ok = abs(ratio - 1.0) * 100.0 <= tol
        print('  row %d %-16s beat %.3f us, line %.3f us, real %.3f us/line, ratio %.2f%s;'
              ' CPU turnaround between lines %.3f us'
              % (r, name, beat, 4 * beat, real_line, ratio, '' if ok else '  DEVIATES', turn))
        if not ok:
            fails.append(r)

    print()
    if fast:
        print('Fast timing: reported only')
        return 0
    if deviations:
        print('rows outside %.0f%%: %s' % (tol, ' '.join(str(r) for r in deviations)))
    if strict:
        fails += deviations
    if fails:
        print('FAIL: %s' % ' '.join(str(r) for r in sorted(set(fails))))
        return 1
    print('PASS: the board line fills are within %.0f%% of the real A3640%s'
          % (tol, '' if not deviations else ' (the rows listed above are not gated without --strict)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
