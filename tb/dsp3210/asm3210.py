#!/usr/bin/env python3
"""asm3210.py: an assembler for the AT&T DSP3210, for the core's tests.

The syntax is the DSP3210 Information Manual's (chapter 4), the encodings
its chapter 10 (Tables 10-1 to 10-3).  One instruction or directive a line;
labels end with ':'; comments start with '/*' (to '*/') or '//' or ';'.

  DA   [*rP{++,--,++rI} =] aN = [-]aM {+,-} Y * X        (FMULT-ACC-STORE)
       aN = [-]aM {+,-} (Z = Y) * X                      (FMULT-ACC-TAP)
       [Z =] aN = [-]Y {+,-} aM * X                      (FMULT-ADD-STORE)
       [Z =] aN = [-]Y * X                               (FMULT-STORE)
       aN = [-](Z = Y) * X                               (FMULT-TAP)
       [Z =] aN = [-]Y {+,-} X                           (FADD-STORE)
       [Z =] aN = [-]Y                                   (FLOAD-STORE)
       aN = [-](Z = Y) {+,-} X                           (FADD-TAP)
       [Z =] aN = ic|oc|float16|int16|round|ifalt|ifaeq|ifagt|float32|int32|ieee|dsp|seed (Y)
       X, Y: aN, *rP, *rP++, *rP--, *rP++rI; Z: *rP... (memory only)
  CA   rD = [(short)|(long)] rS3 + N | rS1 OP rS2 | rD OP N | N - rD | rS | -rS | rS*2 | rS/2 ...
       rD = rS <<| N;  rD = (short) N;  rD = (ushort24) M
       rD = [(size)] *rP[++|--|++rI] | *L | ior;  *rP.. = [(size)] rS;  *L = rS;  ior = rS
       ior = [(size)] *rP..;  *rP.. = [(size)] ior
       if (cond) <ca-arith>;  rD - N;  rD & N (compare / bit test, no store)
       [if (cond)] goto N|rB|rB+N|label;  pcgoto label;  goto M (24 bits) | rB+M
       if (rM-- >= 0) goto ...;  call ... (rM);  return (rM);  do K, L|rM;  dolock, doblock
       nop, ireturn, waiti, bkpt, sftrst
  .org ADDR   .long V   .float F (DSP32 format)   .ieee F   .align N

Output: a big-endian binary image from the lowest address used (or -base).
"""
import math
import re
import struct
import sys

REG = {f'r{i}': i for i in range(15)}
REG.update({'pc': 15, 'r15': 17, 'r16': 18, 'r17': 19, 'r18': 20, 'r19': 21,
            'r20': 24, 'r21': 25, 'sp': 25, 'r22': 26, 'evtp': 26, 'pcsh': 30})
IOR = {'ps': 0, 'emr': 8, 'spc': 10, 'pcw': 12, 'dauc': 14, 'ctr': 15}
for k, v in list(IOR.items()):
    IOR[f'ior{v}'] = v
# the I/O registers' sizes (a move must use the register's size): ps, emr,
# pcw 16 bits; dauc, ctr 8; spc (the pseudo-instructions' target) as given
IOR_SIZE = {0: 'short', 8: 'short', 12: 'short', 14: 'byte', 15: 'byte', 10: 'long'}
COND = {'false': 0, 'true': 1, 'pl': 2, 'mi': 3, 'ne': 4, 'eq': 5, 'vc': 6, 'vs': 7,
        'cc': 8, 'cs': 9, 'ge': 10, 'lt': 11, 'gt': 12, 'le': 13, 'hi': 14, 'ls': 15,
        'auc': 16, 'aus': 17, 'age': 18, 'alt': 19, 'ane': 20, 'aeq': 21, 'avc': 22, 'avs': 23,
        'agt': 24, 'ale': 25, 'ibe': 32, 'ibf': 33, 'obf': 34, 'obe': 35,
        'syc': 40, 'sys': 41, 'fbc': 42, 'fbs': 43, 'ir0c': 44, 'ir0s': 45, 'ir1c': 46, 'ir1s': 47}
# W field: loads (sign/zero extension) and stores (the register's bits)
W_LOAD = {'byte': 0, 'char': 1, 'ushort': 2, 'short': 3, 'hbyte': 4, 'long': 7}
W_STORE = {'byte': 0, 'short': 3, 'hbyte': 4, 'long': 7}
SPECIAL = {'ic': 0, 'oc': 1, 'float16': 2, 'int16': 3, 'round': 4, 'ifalt': 5, 'ifaeq': 6,
           'ifagt': 7, 'float32': 8, 'int32': 9, 'ieee': 12, 'dsp': 13, 'seed': 14}
ALU = {'+': 0, '<<': 1, 'rsub': 2, '#': 3, '-': 4, '&~': 6, 'cmp': 7, '^': 8, '>>>1': 9,
       '|': 10, '<<<1': 11, '>>': 12, '$>>': 13, '&': 14, 'btst': 15}


class AsmError(Exception):
    pass


def dsp32(x):
    """A Python float as a DSP32 32-bit floating-point word: a 24-bit
    normalized 2's complement mantissa (s, 23 fraction bits) and an
    exponent biased by 128: N = M * 2^(e-128), 1 <= M < 2 or -2 <= M < -1."""
    if x == 0:
        return 0
    e = math.floor(math.log2(abs(x)))
    if x > 0:
        m = x / 2.0 ** e
        while m >= 2.0:
            m /= 2; e += 1
        while m < 1.0:
            m *= 2; e -= 1
        f = round((m - 1.0) * (1 << 23))
        if f == 1 << 23:
            f = 0; e += 1
        s = 0
    else:
        # -2 <= M < -1
        m = x / 2.0 ** e
        while m < -2.0:
            m /= 2; e += 1
        while m >= -1.0:
            m *= 2; e -= 1
        f = round((m + 2.0) * (1 << 23))
        if f == 1 << 23:
            # rounded up to -1.0: that is -2 * 2^(e-1)
            f = 0; e -= 1
        s = 1
    ex = e + 128
    if not 1 <= ex <= 255:
        raise AsmError(f'{x}: out of the DSP32 range')
    return (s << 31) | (f << 8) | ex


def dsp32_value(w):
    """The value of a DSP32 word (for the tests' expectations)."""
    e = w & 0xFF
    if e == 0:
        return 0.0
    s = w >> 31
    f = (w >> 8) & 0x7FFFFF
    m = (-2.0 if s else 1.0) + f / (1 << 23)
    return m * 2.0 ** (e - 128)


class Asm:
    def __init__(self):
        self.labels = {}
        self.out = {}          # address -> 32-bit word
        self.pc = 0

    # ---------------------------------------------------------------- values
    def num(self, s, bits=None, signed=True):
        s = s.strip()
        try:
            v = eval(s, {'__builtins__': {}}, dict(self.labels))
        except NameError:
            if self.pass_ == 1:
                v = 0
            else:
                raise AsmError(f'undefined: {s}')
        except SyntaxError:
            raise AsmError(f'bad number: {s}')
        v = int(v)
        if bits and self.pass_ == 2:
            lo = -(1 << (bits - 1)) if signed else 0
            hi = (1 << bits) - 1
            if not lo <= v <= hi:
                raise AsmError(f'{s} = {v}: does not fit {bits} bits')
        return v & ((1 << bits) - 1) if bits else v

    def reg(self, s):
        s = s.strip()
        if s not in REG:
            raise AsmError(f'not a CAU register: {s}')
        return REG[s]

    # ------------------------------------------------------------- operands
    def xyz(self, s, mem_only=False):
        """A DA operand field (7 bits): p (the pointer) and i (the increment)."""
        s = s.strip()
        m = re.fullmatch(r'a([0-3])', s)
        if m:
            if mem_only:
                raise AsmError(f'Z must be memory: {s}')
            return int(m.group(1))
        m = re.fullmatch(r'\*\s*(r\d+)\s*(\+\+|--)?\s*(r\d+)?', s)
        if not m:
            raise AsmError(f'bad operand: {s}')
        p = self.reg(m.group(1))
        if not 1 <= p <= 14:
            raise AsmError(f'pointer must be r1-r14: {s}')
        if m.group(3):
            ri = self.reg(m.group(3))
            if not 17 <= ri <= 21:
                raise AsmError(f'increment must be r15-r19: {s}')
            i = ri - 16
        elif m.group(2) == '++':
            i = 7
        elif m.group(2) == '--':
            i = 6
        else:
            i = 0
        return (p << 3) | i

    def memref(self, s):
        """A CA memory operand *rP[++|--|++rI]: (rP, rI code)."""
        m = re.fullmatch(r'\*\s*(\w+)\s*(\+\+|--)?\s*(\w+)?', s.strip())
        if not m or m.group(1) not in REG:
            return None
        p = self.reg(m.group(1))
        if m.group(3):
            i = self.reg(m.group(3))
        elif m.group(2) == '++':
            i = 23
        elif m.group(2) == '--':
            i = 22
        else:
            i = 0
        return p, i

    # ---------------------------------------------------------- instructions
    def da(self, z, lhs, rhs):
        """A DA instruction: Z (or None), aN, the right-hand side."""
        n = int(lhs[1])
        zc = self.xyz(z, True) if z else 7   # 0000111: no write
        rhs = rhs.replace(' ', '')
        # special functions
        m = re.fullmatch(r'(\w+)\((.+)\)', rhs)
        if m and m.group(1) in SPECIAL:
            if z is None:
                zc = 7
            return (0b01111 << 27) | (SPECIAL[m.group(1)] << 23) | (n << 21) | (self.xyz(m.group(2)) << 7) | zc
        neg = rhs.startswith('-')
        if neg:
            rhs = rhs[1:]
        f = 1 if neg else 0
        # aN = [-](Z=Y) * X  /  aN = [-](Z=Y) {+,-} X  /  aN = [-]aM {+,-} (Z=Y) * X
        m = re.fullmatch(r'\((\*[^=]+)=([^)]+)\)\*(.+)', rhs)
        if m:                                              # FMULT-TAP
            return self.da_word(2, 4, 0, f, n, m.group(3), m.group(2), m.group(1))
        m = re.fullmatch(r'\((\*[^=]+)=([^)]+)\)([+-])(.+)', rhs)
        if m:                                              # FADD-TAP
            return self.da_word(1, 6, f, 1 if m.group(3) == '-' else 0, n, m.group(4), m.group(2), m.group(1))
        m = re.fullmatch(r'(a[0-3])([+-])\((\*[^=]+)=([^)]+)\)\*(.+)', rhs)
        if m:                                              # FMULT-ACC-TAP
            return self.da_word(2, int(m.group(1)[1]), f, 1 if m.group(2) == '-' else 0, n,
                                m.group(5), m.group(4), m.group(3))
        OP = r'(a[0-3]|\*r\d+(?:\+\+r\d+|\+\+|--)?)'
        # [Z=] aN = [-]aM {+,-} Y * X
        m = re.fullmatch(r'(a[0-3])([+-])' + OP + r'\*' + OP, rhs)
        if m:
            return self.da_word(3, int(m.group(1)[1]), f, 1 if m.group(2) == '-' else 0, n,
                                m.group(4), m.group(3), z)
        # [Z=] aN = [-]Y {+,-} aM * X
        m = re.fullmatch(OP + r'([+-])(a[0-3])\*' + OP, rhs)
        if m:
            return self.da_word(1, int(m.group(3)[1]), f, 1 if m.group(2) == '-' else 0, n,
                                m.group(4), m.group(1), z)
        # [Z=] aN = [-]Y * X
        m = re.fullmatch(OP + r'\*' + OP, rhs)
        if m:
            return self.da_word(3, 4, 0, f, n, m.group(2), m.group(1), z)
        # [Z=] aN = [-]Y {+,-} X
        m = re.fullmatch(OP + r'([+-])' + OP, rhs)
        if m:
            return self.da_word(1, 5, f, 1 if m.group(2) == '-' else 0, n, m.group(3), m.group(1), z)
        if not re.fullmatch(OP, rhs):
            raise AsmError(f'cannot parse the DA operation: {rhs}')
        # [Z=] aN = [-]Y
        return self.da_word(1, 4, f, 0, n, 'a0', rhs, z)

    def da_word(self, cls, mf, f, s, n, x, y, z):
        zc = self.xyz(z, True) if z else 7
        return (cls << 29) | (mf << 26) | (f << 24) | (s << 23) | (n << 21) | \
               (self.xyz(x) << 14) | (self.xyz(y) << 7) | zc

    def target(self, s, here, allow24=False):
        """A branch target: N, rB, rB+N, label (pc relative when rB is pc)."""
        s = s.strip()
        m = re.fullmatch(r'(\w+)\s*([+-]\s*.+)?', s)
        if m and m.group(1) in REG:
            rb = REG[m.group(1)]
            n = self.num(m.group(2).replace(' ', '')) if m.group(2) else 0
            return rb, n
        return 0, self.num(s)

    def ca(self, line, here):
        L = line.strip()
        # pseudo instructions
        if L == 'nop':
            return 0x80000000
        if L == 'ireturn':
            return 0x803E0000
        if L == 'waiti':
            return self.ca('spc = (long) r0', here)
        if L == 'bkpt':
            return self.ca('spc = (short) r0', here)
        if L == 'sftrst':
            return self.ca('spc = (byte) r0', here)
        m = re.fullmatch(r'return\s*\(\s*(\w+)\s*\)', L)
        if m:
            return (0b10000 << 27) | (1 << 21) | (self.reg(m.group(1)) << 16)
        # do loops
        m = re.fullmatch(r'(do|dolock|doblock)\s+(?:(.+?)\s*,\s*)?(.+)', L)
        if m:
            k = self.num(m.group(2), 7, False) if m.group(2) else 0
            b = 1 if m.group(1) == 'dolock' else 0
            mm = 1 if m.group(1) == 'doblock' else 0
            cnt = m.group(3).strip()
            if cnt in REG:
                return (0b1000111 << 25) | (b << 24) | (mm << 23) | (k << 11) | REG[cnt]
            return (0b1000110 << 25) | (b << 24) | (mm << 23) | (k << 11) | self.num(cnt, 11, False)
        # branches
        m = re.fullmatch(r'(?:if\s*\(\s*(\w+)\s*\)\s*)?(pc)?goto\s+(.+)', L)
        if m:
            c = COND[m.group(1)] if m.group(1) else 1
            if m.group(2):
                n = self.num(m.group(3)) - (here + 8)
                return (0b10000 << 27) | (c << 21) | (15 << 16) | (n & 0xFFFF)
            rb, n = self.target(m.group(3), here)
            if m.group(1) is None and not -32768 <= n <= 32767:
                # goto M / rB+M: 24 bits
                return (0b101 << 29) | (((n >> 16) & 0xFF) << 21) | (rb << 16) | (n & 0xFFFF)
            return (0b10000 << 27) | (c << 21) | (rb << 16) | (n & 0xFFFF)
        m = re.fullmatch(r'if\s*\(\s*(\w+)\s*--\s*>=\s*0\s*\)\s*(pc)?goto\s+(.+)', L)
        if m:
            rm = self.reg(m.group(1))
            if m.group(2):
                n = self.num(m.group(3)) - (here + 8)
                return (0b000011 << 26) | (rm << 21) | (15 << 16) | (n & 0xFFFF)
            rb, n = self.target(m.group(3), here)
            return (0b000011 << 26) | (rm << 21) | (rb << 16) | (n & 0xFFFF)
        m = re.fullmatch(r'(pc)?call\s+(.+?)\s*\(\s*(\w+)\s*\)', L)
        if m:
            rm = self.reg(m.group(3))
            if m.group(1):
                n = self.num(m.group(2)) - (here + 8)
                return (0b000100 << 26) | (rm << 21) | (15 << 16) | (n & 0xFFFF)
            rb, n = self.target(m.group(2), here)
            if rb == 0 and not -32768 <= n <= 32767:
                return (0b111 << 29) | (((n >> 16) & 0xFF) << 21) | (rm << 16) | (n & 0xFFFF)
            return (0b000100 << 26) | (rm << 21) | (rb << 16) | (n & 0xFFFF)
        # conditional register forms
        cond = 1
        m = re.fullmatch(r'if\s*\(\s*(\w+)\s*\)\s*(.+)', L)
        if m:
            cond = COND[m.group(1)]
            L = m.group(2).strip()
        # compare / bit test (no store): rD - N, rS1 - rS2, rD & N, rS1 & rS2
        m = re.fullmatch(r'(?:\((short|long)\)\s*)?(\w+)\s*([-&])\s*(\w+)', L)
        if m and m.group(2) in REG:
            e = 0 if m.group(1) == 'short' else 1
            fn = ALU['cmp'] if m.group(3) == '-' else ALU['btst']
            return self.alu(e, fn, 0, REG[m.group(2)], m.group(4), cond)
        # assignments
        m = re.fullmatch(r'(.+?)\s*=\s*(.+)', L)
        if not m:
            raise AsmError(f'cannot parse: {line}')
        lhs, rhs = m.group(1).strip(), m.group(2).strip()
        size = None
        ms = re.fullmatch(r'\((\w+)\)\s*(.+)', rhs)
        if ms:
            size, rhs = ms.group(1), ms.group(2).strip()
        # stores and I/O moves
        if lhs in IOR:
            mr = self.memref(rhs)
            w = W_STORE.get(size or IOR_SIZE[IOR[lhs]])
            if mr:                                           # ior = *rP
                return (0b1001111 << 25) | (0 << 24) | (w << 21) | (IOR[lhs] << 16) | (mr[0] << 11) | mr[1]
            return (0b1001110 << 25) | (1 << 24) | (w << 21) | (self.reg(rhs) << 16) | (1 << 10) | IOR[lhs]
        if lhs.startswith('*'):
            mr = self.memref(lhs)
            w = W_STORE[size or 'long']
            if mr:
                if rhs in IOR:                               # *rP = ior
                    w = W_STORE[size or IOR_SIZE[IOR[rhs]]]
                    return (0b1001111 << 25) | (1 << 24) | (w << 21) | (IOR[rhs] << 16) | (mr[0] << 11) | mr[1]
                return (0b1001110 << 25) | (1 << 24) | (w << 21) | (self.reg(rhs) << 16) | (mr[0] << 11) | mr[1]
            # *L = rS
            return (0b0001110 << 25) | (1 << 24) | (w << 21) | (self.reg(rhs) << 16) | self.num(lhs[1:], 16, False)
        rd = self.reg(lhs)
        e = 0 if size == 'short' else 1
        # loads
        if rhs.startswith('*'):
            w = W_LOAD[size or 'long']
            mr = self.memref(rhs)
            if mr:
                return (0b1001110 << 25) | (0 << 24) | (w << 21) | (rd << 16) | (mr[0] << 11) | mr[1]
            return (0b0001110 << 25) | (0 << 24) | (w << 21) | (rd << 16) | self.num(rhs[1:], 16, False)
        if rhs in IOR:
            w = W_LOAD[size or IOR_SIZE[IOR[rhs]]]
            return (0b1001110 << 25) | (0 << 24) | (w << 21) | (rd << 16) | (1 << 10) | IOR[rhs]
        if size == 'ushort24':
            n = self.num(rhs, 24, False)
            return (0b110 << 29) | (((n >> 16) & 0xFF) << 21) | (rd << 16) | (n & 0xFFFF)
        # rD = rS <<| N
        mo = re.fullmatch(r'(\w+)\s*<<\|\s*(.+)', rhs)
        if mo:
            return (0b100100 << 26) | (rd << 21) | (self.reg(mo.group(1)) << 16) | self.num(mo.group(2), 16, False)
        # unary forms
        if re.fullmatch(r'-\s*\w+', rhs) and rhs[1:].strip() in REG:      # rD = -rS
            return self.alu(e, ALU['-'], rd, 0, rhs[1:].strip(), cond)
        mu = re.fullmatch(r'(\w+)\s*(\*\s*2|/\s*2|>>>\s*1|<<<\s*1|>>\s*1|<<\s*1|\+\s*1|-\s*1)', rhs)
        if mu and mu.group(1) in REG:
            op = mu.group(2).replace(' ', '')
            rs = mu.group(1)
            if op == '*2':
                return self.alu(e, ALU['+'], rd, REG[rs], rs, cond)
            if op == '/2':
                return self.alu(e, ALU['$>>'], rd, REG[rs], 23, cond)
            if op == '>>>1':
                return self.alu(e, ALU['>>>1'], rd, REG[rs], 23, cond)
            if op == '<<<1':
                return self.alu(e, ALU['<<<1'], rd, REG[rs], 23, cond)
            if op == '>>1':
                return self.alu(e, ALU['>>'], rd, REG[rs], 23, cond)
            if op == '<<1':
                return self.alu(e, ALU['<<'], rd, REG[rs], 23, cond)
            if op in ('+1', '-1') and rd != REG[rs] and cond == 1 and False:
                pass
            if op in ('+1', '-1'):
                return self.alu(e, ALU['+'] if op == '+1' else ALU['-'], rd, REG[rs], 23, cond)
        if rhs in REG:                                       # rD = rS
            return self.alu(e, ALU['+'], rd, REG[rhs], 'r0', cond)
        # binary forms
        mb = re.fullmatch(r'(\S+?)\s*(\$>>|>>|<<|&~|[-+&|^#])\s*(.+)', rhs)
        if mb:
            a, op, b = mb.group(1).strip(), mb.group(2), mb.group(3).strip()
            if a in REG and b in REG:
                return self.alu(e, ALU[op], rd, REG[a], b, cond)
            if a in REG and op == '+' and cond == 1:
                # three-operand add with an immediate (format 5a/b)
                return ((e << 31) | (0b00101 << 26) | (rd << 21) | (REG[a] << 16) | self.num(b, 16))
            if a in REG and REG[a] == rd:
                return self.alu(e, ALU[op], rd, rd, b, cond, imm=True)
            if b in REG and REG[b] == rd and op == '-':
                return self.alu(e, ALU['rsub'], rd, rd, a, cond, imm=True)
            raise AsmError(f'unsupported form: {line}')
        # rD = (short) N
        if cond != 1:
            raise AsmError('only the register ALU forms can be conditional')
        return (0 << 31) | (0b00101 << 26) | (rd << 21) | (0 << 16) | self.num(rhs, 16)

    def alu(self, e, fn, rd, rs1, rs2, cond, imm=False):
        if imm:
            if cond != 1:
                raise AsmError('an immediate operation cannot be conditional')
            return (e << 31) | (0b001101 << 25) | (fn << 21) | (rd << 16) | self.num(rs2, 16)
        r2 = rs2 if isinstance(rs2, int) else (self.reg(rs2) if rs2 in REG else None)
        if r2 is None:
            # rD OP N on the register itself
            if rs1 != rd and fn not in (ALU['cmp'], ALU['btst']):
                raise AsmError('an immediate operation works on rD')
            if cond != 1:
                raise AsmError('an immediate operation cannot be conditional')
            return (e << 31) | (0b001101 << 25) | (fn << 21) | (rs1 << 16) | self.num(rs2, 16)
        return (e << 31) | (0b001100 << 25) | (fn << 21) | (rd << 16) | (rs1 << 11) | (cond << 5) | r2

    # ---------------------------------------------------------- restrictions
    REGTOK = re.compile(r'\b(r\d+|sp|evtp|pcsh|ps|emr|pcw|dauc|ctr|ior\d+)\b')

    def meta(self, L, words):
        """What the restrictions (4.4.1) need of an instruction: its kind, the
        registers it references, a post-modified Z pointer (DA), a memory /
        I/O Y operand (DA), the register a load writes (CA)."""
        m = re.fullmatch(r'(?:(\*[^=]+?)\s*=\s*)?(a[0-3])\s*=\s*(.+)', L)
        if m:
            w = words[0]
            z = m.group(1) or ''
            zm = re.fullmatch(r'\*\s*(r\d+)\s*(\+\+|--)\s*(r\d+)?|\*\s*(r\d+)\s*\+\+\s*(r\d+)', z.strip())
            zp = zm.group(1) if zm else None
            return {'kind': 'da', 'refs': set(self.REGTOK.findall(m.group(3))), 'zpost': zp,
                    'ymem': ((w >> 10) & 0xF) != 0}
        refs = set(self.REGTOK.findall(L))
        cond = re.match(r'if\s*\(\s*(\w+)\s*\)', L)
        ccond = bool(cond) and cond.group(1) in COND and COND[cond.group(1)] < 16
        a = re.fullmatch(r'(\*?[^=]+?)\s*=\s*(?:\(\s*\w+\s*\)\s*)?(\S.*)', L)
        kind, dst = 'ca', None
        if a and not cond:
            lhs, rhs = a.group(1).strip(), a.group(2).strip()
            mem_rhs = rhs.startswith('*')
            if lhs.startswith('*') and (rhs in REG or rhs in IOR):
                kind = 'store'
            elif lhs in IOR and rhs in REG:
                kind = 'store'
            elif lhs in REG and (mem_rhs or rhs in IOR):
                kind, dst = 'load', lhs
            elif lhs in IOR and mem_rhs:
                kind, dst = 'load', lhs
        return {'kind': kind, 'refs': refs, 'ccond': ccond, 'dst': dst}

    def restrict(self, prev, cur):
        if not prev:
            return
        if prev['kind'] == 'da' and prev['zpost'] and prev['zpost'] in cur['refs']:
            raise AsmError(f"restriction 1: uses {prev['zpost']}, the preceding DA instruction's "
                           f"post-modified Z pointer")
        if prev['kind'] == 'da' and prev['ymem'] and cur['kind'] == 'store':
            raise AsmError('restriction 2: a CAU / I/O register store after a DA instruction with a memory Y')
        if prev['kind'] == 'load':
            if prev['dst'] in cur['refs']:
                raise AsmError(f"restriction 3: references {prev['dst']}, loaded by the preceding instruction")
            if cur['kind'] != 'da' and cur.get('ccond'):
                raise AsmError('restriction 3: tests the flags of the preceding load')
            if prev['dst'] == 'dauc' and cur['kind'] == 'da':
                raise AsmError('restriction 3: a dauc load from memory must be followed by a CA instruction')

    # ---------------------------------------------------------------- driver
    def line(self, raw, here):
        L = raw.strip()
        if not L:
            return []
        if L.startswith('.'):
            parts = L.split(None, 1)
            d, arg = parts[0], parts[1] if len(parts) > 1 else ''
            if d == '.long':
                return [self.num(a) & 0xFFFFFFFF for a in arg.split(',')]
            if d == '.float':
                return [dsp32(float(eval(a, {'__builtins__': {}}))) for a in arg.split(',')]
            if d == '.ieee':
                return [struct.unpack('>I', struct.pack('>f', float(eval(a, {'__builtins__': {}}))))[0]
                        for a in arg.split(',')]
            raise AsmError(f'unknown directive {d}')
        # DA: [Z =] aN = ...
        m = re.fullmatch(r'(?:(\*[^=]+?)\s*=\s*)?(a[0-3])\s*=\s*(.+)', L)
        if m:
            return [self.da(m.group(1), m.group(2), m.group(3))]
        return [self.ca(L, here)]

    def assemble(self, text):
        lines = []
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        for raw in text.split('\n'):
            raw = re.sub(r'(//|;).*', '', raw)
            lines.append(raw)
        for self.pass_ in (1, 2):
            self.pc = 0
            self.out = {}
            prev = None
            for n, raw in enumerate(lines, 1):
                L = raw.strip()
                while True:
                    m = re.match(r'([A-Za-z_]\w*):\s*(.*)', L)
                    if not m:
                        break
                    self.labels[m.group(1)] = self.pc
                    L = m.group(2)
                if not L:
                    continue
                if L.startswith('.org'):
                    self.pc = self.num(L.split(None, 1)[1])
                    continue
                if L.startswith('.align'):
                    a = self.num(L.split(None, 1)[1])
                    self.pc = (self.pc + a - 1) // a * a
                    continue
                m = re.fullmatch(r'(\w+)\s+equ\s+(.+)', L)
                if m:
                    self.labels[m.group(1)] = self.num(m.group(2))
                    continue
                try:
                    words = self.line(L, self.pc)
                    cur = None if L.startswith('.') else self.meta(L, words)
                    if self.pass_ == 2:
                        self.restrict(prev, cur)
                    prev = cur
                except (AsmError, KeyError) as ex:
                    raise AsmError(f'line {n}: {raw.strip()}: {ex}')
                for w in words:
                    self.out[self.pc] = w & 0xFFFFFFFF
                    self.pc += 4
        return self.out


def image(out, base=None):
    if not out:
        return b''
    lo = min(out) if base is None else base
    hi = max(out) + 4
    b = bytearray(hi - lo)
    for a, w in out.items():
        b[a - lo:a - lo + 4] = struct.pack('>I', w)
    return bytes(b)


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('-o', required=True)
    ap.add_argument('-base', type=lambda s: int(s, 0))
    ap.add_argument('-l', action='store_true', help='print a listing')
    a = ap.parse_args()
    asm = Asm()
    try:
        out = asm.assemble(open(a.src).read())
    except AsmError as ex:
        sys.exit(f'{a.src}: {ex}')
    open(a.o, 'wb').write(image(out, a.base))
    if a.l:
        for adr in sorted(out):
            print(f'{adr:08X}  {out[adr]:08X}')
