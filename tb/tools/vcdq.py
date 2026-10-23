#!/usr/bin/env python3
"""Print the value changes of selected signals in an FST/VCD waveform.

  vcdq.py WAVE.fst PATTERN... [--from NS] [--to NS] [--list]

A PATTERN is matched against the full hierarchical name (a dotted path):
an exact last component ("ovl"), or a regular expression ("chipset\\.ovl$").
--list prints the matching names only.  Times are printed in ns.
"""
import re
import subprocess
import sys


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    wave = args.pop(0)
    t_from, t_to, list_only = 0, None, False
    pats = []
    while args:
        a = args.pop(0)
        if a == '--from':
            t_from = float(args.pop(0))
        elif a == '--to':
            t_to = float(args.pop(0))
        elif a == '--list':
            list_only = True
        else:
            pats.append(re.compile(a))

    if wave.endswith('.fst'):
        src = subprocess.Popen(['fst2vcd', '-f', wave], stdout=subprocess.PIPE, text=True).stdout
    else:
        src = open(wave)

    scope = []
    names = {}           # id -> [names]
    wanted = {}          # id -> name
    timescale_ps = 1
    t = 0
    header = True
    vals = {}
    for line in src:
        line = line.strip()
        if header:
            if line.startswith('$scope'):
                scope.append(line.split()[2])
            elif line.startswith('$upscope'):
                scope.pop()
            elif line.startswith('$var'):
                p = line.split()
                ident, name = p[3], p[4]
                full = '.'.join(scope + [name])
                for pat in pats:
                    if pat.search(full) or full.split('.')[-1] == pat.pattern:
                        wanted.setdefault(ident, full)
                        break
            elif line.startswith('$timescale'):
                m = re.search(r'(\d+)\s*(s|ms|us|ns|ps|fs)', line)
                if m:
                    mult = {'s': 1e12, 'ms': 1e9, 'us': 1e6, 'ns': 1e3, 'ps': 1, 'fs': 1e-3}[m.group(2)]
                    timescale_ps = int(m.group(1)) * mult
            elif line.startswith('$enddefinitions'):
                header = False
                if list_only:
                    for n in sorted(set(wanted.values())):
                        print(n)
                    return 0
            continue
        if not line:
            continue
        if line[0] == '#':
            t = int(line[1:]) * timescale_ps / 1000.0
            continue
        if line[0] in 'bBrR':
            v, ident = line[1:].split()
        else:
            v, ident = line[0], line[1:]
        if ident in wanted and t >= t_from and (t_to is None or t <= t_to):
            if vals.get(ident) != v:
                vals[ident] = v
                if len(v) > 4 and all(c in '01' for c in v):
                    v = '%X' % int(v, 2)
                print('%14.3f  %-60s %s' % (t, wanted[ident], v))
    return 0


if __name__ == '__main__':
    sys.exit(main())
