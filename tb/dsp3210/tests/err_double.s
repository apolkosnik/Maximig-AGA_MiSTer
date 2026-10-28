/* The double error (7.5.2.1): a non-maskable error in a non-maskable error's
   handler halts the processor (IACK0 and IACK1 both asserted); a maskable
   error's handler takes a non-maskable one (no halt), and that one's
   handler a second non-maskable one: the halt */
//! halt
	evtp = (ushort24) TABLE
	r2 = (ushort24) 0x1000
	r12 = (short) 0
	r6 = (short) 0x20              // overflow enabled
	emr = r6
	r1 = (ushort24) BIG
	a0 = *r1 * *r1                 // the overflow: to EO
	nop
	nop
	nop
	nop
	r12 = r12 + 0x40               // (aborted)
L9:	pcgoto L9
	nop

EO:	r12 = r12 + 1
	*r2++ = r12                    //! expect 0x1000 0x00000001
	r1 = (ushort24) 0
	r1 = r1 <<| 0x4000
	r5 = *r1                       // a bus error at the maskable error's level: to EB
	r12 = r12 + 0x80               // (aborted)
	pcgoto L9
	nop
EB:	r12 = r12 + 0x10
	*r2++ = r12                    //! expect 0x1004 0x00000011
	r5 = *r1                       // a second non-maskable error: the halt
	r12 = r12 + 0x100              // (aborted)
	*r2++ = r12                    //! expect 0x1008 0x00000000
	pcgoto L9
	nop

	.align 8
TABLE:	.long 0, 0                     // 0 reset
	pcgoto EB                      // 1 bus error
	nop
	.long 0, 0, 0, 0, 0, 0         // 2-4
	pcgoto EO                      // 5 overflow/underflow
	nop
BIG:	.float 1.2676506e30            // 2^100
