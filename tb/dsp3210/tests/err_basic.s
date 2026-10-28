/* Error exceptions (7.5.2, 7.5.3): illegal opcode, address error (masked
   and enabled), bus error, DAU overflow (masked: saturated; enabled), NaN;
   a maskable error at a maskable error's level ignored, a non-maskable one
   taken; sftrst back to the base level.  r12 collects the handlers' marks. */
	evtp = (ushort24) TABLE
	r2 = (ushort24) 0x1000
	r12 = (short) 0
	r13 = (short) 0
	r6 = (short) 0
	emr = r6
	r9 = (short) 0
	// illegal opcode (bits 31-26 0): the instructions after it aborted
	.long 0x00000000
	r13 = (short) 1
	r13 = (short) 2
N1:	*r2++ = r12                    //! expect 0x1000 0x00000002
	*r2++ = r13                    //! expect 0x1004 0x00000000
	// an address error, masked: no exception
	r1 = (ushort24) 0x1102
	r5 = *r1
	nop
	*r2++ = r12                    //! expect 0x1008 0x00000002
	// ...enabled (emr[4])
	r6 = (short) 0x10
	emr = r6
	nop
	r5 = *r1
	r13 = (short) 3
N2:	*r2++ = r12                    //! expect 0x100C 0x00000012
	*r2++ = r13                    //! expect 0x1010 0x00000000
	// a bus error (the bench's memory above 0x40000000)
	r1 = (ushort24) 0
	r1 = r1 <<| 0x4000
	r5 = *r1
	r13 = (short) 4
N3:	*r2++ = r12                    //! expect 0x1014 0x00000112
	*r2++ = r13                    //! expect 0x1018 0x00000000
	// DAU overflow, masked: saturated, V set
	r1 = (ushort24) BIG
	a0 = *r1 * *r1                 // 2^100 * 2^100
	nop
	nop
	nop
	if (avs) pcgoto VOK            // the multiply's V (four back)
	nop
	r13 = (short) 5
VOK:	*r2++ = a1 = a0                //! expect 0x101C 0x7FFFFFFF
	nop                            // (restriction 1)
	*r2++ = r13                    //! expect 0x1020 0x00000000
	// ...enabled (emr[5])
	r6 = (short) 0x20
	emr = r6
	nop
	a0 = *r1 * *r1
	nop
	nop
	nop
	r13 = (short) 6
N4:	*r2++ = r12                    //! expect 0x1024 0x00001112
	*r2++ = r13                    //! expect 0x1028 0x00000000
	// NaN (emr[6]) on an IEEE-to-DSP conversion
	r6 = (short) 0x40
	emr = r6
	r1 = (ushort24) NAN
	nop
	a0 = dsp(*r1)
	nop
	nop
	nop
	r13 = (short) 7
N5:	*r2++ = r12                    //! expect 0x102C 0x00003112
	*r2++ = r13                    //! expect 0x1030 0x00000000
	// at a maskable error's level: an address error ignored, a bus error taken
	r6 = (short) 0x30
	emr = r6
	r12 = (short) 0
	r9 = (short) 1                 // the handlers' second stage
	r1 = (ushort24) BIG
	a0 = *r1 * *r1                 // the overflow: to EO2
	nop
	nop
	nop
	nop
N6:	*r2++ = r12                    //! expect 0x1034 0x00000A01
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop

EI:	r12 = r12 + 2
	sftrst
	pcgoto N1
	nop
EA:	r12 = r12 + 0x10
	sftrst
	pcgoto N2
	nop
EB:	r9 - 0
	if (ne) pcgoto EB2
	nop
	r12 = r12 + 0x100
	sftrst
	pcgoto N3
	nop
EO:	r9 - 0
	if (ne) pcgoto EO2
	nop
	r12 = r12 + 0x1000
	sftrst
	pcgoto N4
	nop
EN:	r12 = r12 + 0x2000
	sftrst
	pcgoto N5
	nop
	// the second stage: the overflow handler makes an address error (ignored)
	// then a bus error (taken: EB2)
EO2:	r12 = r12 + 1
	r1 = (ushort24) 0x1102
	r5 = *r1                       // ignored
	r12 = r12 + 0x200
	r1 = (ushort24) 0
	r1 = r1 <<| 0x4000
	r5 = *r1                       // taken
	r12 = r12 + 0x4000             // aborted
EB2:	r12 = r12 + 0x800
	sftrst
	pcgoto N6
	nop

	.align 8
TABLE:	.long 0, 0                     // 0 reset
EVB:	pcgoto EB                      // 1 bus error
	nop
	pcgoto EI                      // 2 illegal opcode
	nop
	.long 0, 0                     // 3
	pcgoto EA                      // 4 address error
	nop
EVO:	pcgoto EO                      // 5 overflow/underflow
	nop
	pcgoto EN                      // 6 NaN
	nop
BIG:	.float 1.2676506e30            // 2^100
NAN:	.long 0x7FC00000
