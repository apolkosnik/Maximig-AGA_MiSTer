/* DA multiply/accumulate (4.2.1), exact small values */
	r1 = (ushort24) DATA
	r2 = (ushort24) 0x1000
	a0 = *r1++                     // 2.0
	a1 = *r1++                     // 3.0
	nop
	nop
	*r2++ = a2 = a0 * a1           //! expect 0x1000 0x40000082
	*r2++ = a3 = a2 + a0 * a1      // a2 (6, the instruction before: an adder input) + 6 = 12
	nop
	nop
	nop
	nop
	r3 = (ushort24) 0x1004
	a0 = *r3                       // the 12.0 written above (four instructions later)
	nop
	nop
	nop
	*r2++ = a1 = -a0 + *r1 * *r1   // -12 + 4*4 = 4 (*r1 = 4.0)
	*r2++ = a2 = *r1 - a0           // 4 - 12 = -8
	nop
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop
	.align 4
DATA:	.float 2.0, 3.0, 4.0
//! expect 0x1004 0x40000083
//! expect 0x1008 0x00000082
//! expect 0x100C 0x80000082
