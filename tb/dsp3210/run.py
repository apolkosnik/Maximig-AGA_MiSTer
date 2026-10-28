#!/usr/bin/env python3
"""run.py [TEST...]: the DSP3210 regression.  Each tests/*.s is assembled
(asm3210.py), run on the real core (obj/Vtb_dsp) and its memory checked
against the test's '//! expect ADDR VALUE' lines; '//! args ...' adds bench
options (--waits, --irq0 ...); '//! halt' expects the double-error halt
instead of the done mark.  $DSPARGS adds options to every run (e.g. --waits 3)."""
import os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm3210
here = os.path.dirname(os.path.abspath(__file__))
os.chdir(here)
tests = sys.argv[1:] or sorted(f[:-2] for f in os.listdir('tests') if f.endswith('.s'))
fail = 0
for t in tests:
    src = open(f'tests/{t}.s').read()
    exp = [(int(a, 0), int(v, 0)) for a, v in re.findall(r'//!\s*expect\s+(\S+)\s+(\S+)', src)]
    args = ' '.join(re.findall(r'//!\s*args\s+(.*)', src))
    try:
        out = asm3210.Asm().assemble(src)
    except asm3210.AsmError as e:
        print(f'{t}: ASM ERROR {e}'); fail += 1; continue
    os.makedirs('obj', exist_ok=True)
    open(f'obj/{t}.bin', 'wb').write(asm3210.image(out, 0))
    cmd = ['./obj/Vtb_dsp', f'obj/{t}.bin'] + args.split() + os.environ.get('DSPARGS', '').split()
    for a, _ in exp:
        cmd += ['--dump', hex(a), '4']
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    got = dict((int(a, 16), int(v, 16)) for a, v in re.findall(r'^([0-9A-F]{8}) ([0-9A-F]{8})$', r.stdout, re.M))
    bad = [(a, v, got.get(a)) for a, v in exp if got.get(a) != v]
    halt = re.search(r'//!\s*halt\b', src) is not None
    done = ('halted (double error)' in r.stdout) if halt else (', done' in r.stdout)
    if bad or not done:
        fail += 1
        print(f'{t}: FAIL' + ('' if done else ' (no halt)' if halt else ' (no done mark)'))
        print('   ' + r.stdout.strip().split('\n')[0])
        for a, v, g in bad:
            print(f'   {a:08X}: {g if g is None else f"{g:08X}"} want {v:08X}')
    else:
        print(f'{t}: PASS ({len(exp)} checks)')
print('ALL PASSED' if not fail else f'{fail} FAILED')
sys.exit(1 if fail else 0)
