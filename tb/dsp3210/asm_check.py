import sys
sys.path.insert(0, '.')
from asm3210 import Asm, dsp32, dsp32_value
cases = [
 # the DSP3210's boot ROM (WinUAE's image of the silicon) and AT&T-built example1
 ('pcgoto L\n.org 0x88\nL: nop', {0: 0x802F0080}),
 ('r1 = (short) pcw', {0: 0x9C61040C}),
 ('pcsh = (long) *r0', {0: 0x9CFE0000}),
 ('emr = (short) r0', {0: 0x9D600408}),
 ('ireturn', {0: 0x803E0000}),
 ('r2 = r0 <<| 0x6000', {0: 0x90406000}),
 ('(short) r1 & 0x2000', {0: 0x1BE12000}),
 ('r3 = (ushort24) 0xE000', {0: 0xC003E000}),
 ('r4 = *r2++', {0: 0x9CE41017}),
 ('*r3++ = (byte) r4', {0: 0x9D041817}),
 ('r5 = *0xE004', {0: 0x1CE5E004}),
 ('r3 = r1', {0: 0x98030820}),
 ('goto r1 + 0', {0: 0x80210000}),
 ('r22 = r0 <<| 0x5003', {0: 0x93405003}),
 ('r2 = (ushort24) 0x8000', {0: 0xC0028000}),
 ('emr = (short) r2', {0: 0x9D620408}),
 ('waiti', {0: 0x9DE0040A}),
 ('pcw = r1', {0: 0x9D61040C}),
 ('*r0 = r0', {0: 0x9D000000 | (7 << 21)}),
 ('bkpt', {0: 0x9D60040A}),
 ('do 0, r4', {0: 0x8E000004}),
 ('do 0, 2047', {0: 0x8C0007FF}),
 ('a0 = (*r2++ = *r1++) * a0', {0: 0x50000797}),
 ('r4 = r4 >> 11', {0: 0x9B84000B}),
 ('if (eq) goto r18', {0: 0x80B40000}),
 ('L: if (r4-- >= 0) pcgoto L', {0: 0x0C8FFFF8}),
 ('goto r18', {0: 0x80340000}),
 ('*0x041B = (byte) r1', {0: 0x1D01041B}),
 ('if (mi) r10 = -r5', {0: 0x988A0065}),
 ('r11 = (short) r1 + 32', {0: 0x15610020}),
 ('call pc + 0x0111 (r20)', {0: 0x130F0111}),
 ('(long) r1 - 15', {0: 0x9AE1000F}),
 ('do 4, r20', {0: 0x8E002018}),
]
bad = 0
for src, want in cases:
    got = Asm().assemble(src)
    for a, w in want.items():
        if got.get(a) != w:
            print(f'FAIL {src!r}: {got.get(a, 0):08X} want {w:08X}'); bad += 1
for x in (1.0, -1.0, 0.5, -2.0, 3.0, -0.75, 1e-30):
    w = dsp32(x)
    if abs(dsp32_value(w) - x) > abs(x) * 1e-6:
        print(f'FAIL dsp32({x}) = {w:08X} -> {dsp32_value(w)}'); bad += 1
# the manual's restriction examples (4.4.1): fatal errors; and allowed forms
from asm3210 import AsmError
for src, ok in (('*r1++ = a2 = a2 + *r3 * a1\nr1 = r1 + 12', False),
                ('*r1++ = a2 = a2 + *r3 * a1\na2 = a2 + *r1 * a1', False),
                ('*r1++ = a2 = a2 + *r3 * a1\n*r1++ = a2 = a2 + *r3 * a1', True),
                ('a2 = a2 + *r2 * a3\n*r4 = r5', False),
                ('a0 = ic(*r2)\n*r4 = r5', False),
                ('a2 = a2 + a3 * a1\n*r4 = r5', True),
                ('r3 = *r2\nr4 = r3 + r7', False),
                ('r3 = *r2\n*r3++ = a0 = a1', True),
                ('r3 = *r2\nif (eq) r4 = r4 + 1', False),
                ('dauc = *r2\na0 = a1', False),
                ('r5 = dauc\n*r2 = r5', False)):
    try:
        Asm().assemble(src)
        err = None
    except AsmError as ex:
        err = ex
    if (err is None) != ok:
        print(f'FAIL restriction {src!r}: {err or "accepted"}'); bad += 1
print('asm check:', 'PASS' if bad == 0 else f'{bad} FAIL')
