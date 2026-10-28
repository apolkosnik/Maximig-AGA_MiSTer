/* The latency effects (4.4.2), the manual's four examples */
	r1 = (ushort24) DATA
	r2 = (ushort24) 0x1000
	r3 = (ushort24) 0x1100
	a0 = *r1++                     // 1.0
	a1 = *r1++                     // 2.0
	a3 = *r1++                     // 2.0
	nop
	nop
	nop
	// Latency 1: a DA memory write is read four instructions later, not three
	*r3 = a0 = a0                  // 1.0 to 0x1100
	*r3 = a3 = a3                  // 2.0 to 0x1100
	nop
	nop
	a2 = *r3                       // the value written two instructions back: 1.0
	nop
	nop
	nop
	*r2++ = a2 = a2                //! expect 0x1000 0x00000080
	r1 = (ushort24) DATA2
	a0 = *r1++                     // 1.0
	a1 = *r1++                     // 2.0
	r4 = (ushort24) DATA2 + 8      // *r4 = 2.0, *r5 = 3.0
	r5 = (ushort24) DATA2 + 12
	nop
	nop
	// Latency 2: an accumulator into the multiplier is the one of three
	// instructions back; into the adder, the one of the instruction before
	*r2++ = a0 = a0 + *r4 * *r5    // 1 + 2 * 3 = 7          //! expect 0x1004 0x60000082
	*r2++ = a0 = a0 + a1           // 7 + 2 = 9 (a1 as X: 1.0 * a1)  //! expect 0x1008 0x10000083
	nop
	*r2++ = a2 = a0 * a0           // a0 of the first: 7 * 7 = 49     //! expect 0x100C 0x44000085
	*r2++ = a1 = a2 + a0           // 49 (the instruction before) + 9 = 58  //! expect 0x1010 0x68000085
	// ...and an accumulator written one, two instructions back is not seen
	a3 = *r4                       // 2.0
	nop
	nop
	nop
	a3 = *r5                       // 3.0
	*r2++ = a2 = a3 * a3           // the old a3: 2 * 2 = 4  //! expect 0x1014 0x00000082
	*r2++ = a2 = a3 * a3           // still 2 * 2 = 4        //! expect 0x1018 0x00000082
	*r2++ = a2 = a3 * a3           // 3 * 3 = 9              //! expect 0x101C 0x10000083
	// Latency 4: the DAU condition tested is the one of four instructions back
	r6 = (short) 0
	r9 = (ushort24) DATA2 + 16     // -1.0
	a0 = *r4                       // 2.0 (positive)
	a2 = *r9                       // -1.0
	a1 = *r4                       // 2.0
	nop
	nop
	nop
	a0 = a0 + a1                   // 2 + 2 = 4: agt
	a2 = a0 * a2                   // (the old a0) 2 * -1 = -2: alt
	nop
	nop
	if (agt) pcgoto T1             // the first's condition: taken
	nop
	r6 = r6 + 1                    // (not taken: counted)
T1:	nop
	a0 = a0 * a2                   // 4 * -2 = -8: alt
	a1 = a1 + a1                   // agt
	nop
	nop
	if (alt) pcgoto T2             // the first's condition: taken
	nop
	r6 = r6 + 2
T2:	nop
	a1 = a1 + a1                   // agt
	nop
	nop
	a3 = *r9                       // (an alt, three instructions before the test)
	if (agt) pcgoto T3             // the agt four back: taken
	nop
	r6 = r6 + 4
T3:	*r2++ = r6                     //! expect 0x1020 0x00000000
	// Latency 3: successive branches -- I1, I2, A, B and on from B
	r7 = (short) 0
	pcgoto BA
	pcgoto BB
	r7 = r7 + 100                  // never
BA:	r7 = r7 + 1                    // A: executes once
	r7 = r7 + 10                   // never
BB:	r7 = r7 + 2                    // B
	*r2++ = r7                     //! expect 0x1024 0x00000003
	// ...and A a goto C: I1, I2, A, B, C and on from C
	r8 = (short) 0
	pcgoto CA
	pcgoto CB
	r8 = r8 + 100
CA:	pcgoto CC
	r8 = r8 + 10                   // never
CB:	r8 = r8 + 1                    // B: executes (A's latent instruction)
	r8 = r8 + 1000                 // never
CC:	r8 = r8 + 2                    // C
	*r2++ = r8                     //! expect 0x1028 0x00000003
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop
	.align 4
DATA:	.float 1.0, 2.0, 2.0
DATA2:	.float 1.0, 2.0, 2.0, 3.0, -1.0
//! expect 0x1100 0x00000081
