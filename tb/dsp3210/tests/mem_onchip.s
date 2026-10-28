/* The on-chip RAM (3.4, Processor mode: RAM1 at 0x5003E000, RAM0 at
   0x5003F000): word, half-word and byte lanes (big endian), the two banks
   apart, DA operands and a Z write there, code run from it */
	r1 = (ushort24) 0xE000
	r1 = r1 <<| 0x5003             // RAM1
	r2 = (ushort24) 0xF000
	r2 = r2 <<| 0x5003             // RAM0
	r3 = (ushort24) 0x1000         // results (external)
	r4 = (ushort24) 0x112233
	r4 = r4 <<| 0x4400             // 0x44112233
	*r1 = r4
	r5 = (ushort24) 0x5566
	*r2 = r5                       // RAM0 word 0: 0x00005566
	r6 = (short) 0xAB
	r7 = r1 + 1
	*r7 = (byte) r6                // byte 1: 0x44AB2233
	r6 = (ushort24) 0xCDEF
	r7 = r1 + 2
	*r7 = (short) r6               // half 1: 0x44ABCDEF
	nop
	r8 = *r1
	nop
	*r3++ = r8                     //! expect 0x1000 0x44ABCDEF
	r8 = *r2
	nop
	*r3++ = r8                     // RAM0 kept apart          //! expect 0x1004 0x00005566
	r7 = r1 + 2
	r8 = (short) *r7
	nop
	*r3++ = r8                     // a half, sign extended   //! expect 0x1008 0xFFFFCDEF
	r7 = r1 + 1
	r8 = (byte) *r7
	nop
	*r3++ = r8                     // a byte, zero extended   //! expect 0x100C 0x000000AB
	// DA: X and Y from RAM0 and RAM1, Z to RAM0
	r9 = (ushort24) F2
	r10 = r2 + 8
	r11 = r1 + 8
	r12 = *r9++
	nop
	*r10 = r12                     // 2.0 in RAM0
	r12 = *r9
	nop
	*r11 = r12                     // 3.0 in RAM1
	r10 = r2 + 8
	r11 = r1 + 8
	r13 = r2 + 12
	nop
	*r13 = a0 = *r10 * *r11        // 6.0 to RAM0 + 12
	nop
	nop
	nop
	nop
	r8 = *r13
	nop
	*r3++ = r8                     //! expect 0x1010 0x40000082
	// code in RAM1: copy the routine, call it
	r9 = (ushort24) SUB
	r10 = r1 + 0x100
	r12 = *r9++
	nop
	*r10++ = r12
	r12 = *r9++
	nop
	*r10++ = r12
	r12 = *r9++
	nop
	*r10++ = r12
	r10 = r1 + 0x100
	r14 = (short) 0
	call r10 (r18)
	nop
	*r3++ = r14                    // the routine ran there   //! expect 0x1014 0x00000077
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop
SUB:	r14 = (short) 0x77
	return (r18)
	nop
F2:	.float 2.0, 3.0
