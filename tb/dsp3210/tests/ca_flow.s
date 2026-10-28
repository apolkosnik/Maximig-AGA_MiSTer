/* branches (one latent instruction), the loop counter, call/return, do loops */
	r1 = (ushort24) 0x1000
	r2 = (short) 0
	pcgoto L1
	r2 = r2 + 1                    // latent: executes
	r2 = r2 + 10                   // skipped
L1:	*r1++ = r2                     //! expect 0x1000 0x00000001
	// if (rM-- >= 0): tested before the decrement; 4 .. 0 taken, the body 6 times
	r3 = (short) 4
	r4 = (short) 0
L2:	r4 = r4 + 1
	if (r3-- >= 0) pcgoto L2
	nop
	*r1++ = r4                     //! expect 0x1004 0x00000006
	*r1++ = r3                     //! expect 0x1008 0xFFFFFFFE (tested before the decrement, decremented always)
	// call: the link is the instruction after the latent one
	r6 = (short) 0
	pccall SUB (r5)
	r6 = r6 + 1                    // latent: executes before the subroutine
	r6 = r6 + 100                  // the return comes here
	*r1++ = r6                     //! expect 0x100C 0x0000006F
	// do: the next K+1 instructions L+1 times
	r7 = (short) 0
	do 0, 9
	r7 = r7 + 1
	*r1++ = r7                     //! expect 0x1010 0x0000000A
	r8 = (short) 0
	r9 = (short) 0
	do 2, 3
	r8 = r8 + 1
	r9 = r9 + 2
	nop
	*r1++ = r8                     //! expect 0x1014 0x00000004
	*r1++ = r9                     //! expect 0x1018 0x00000008
	// do with a register count (its low 11 bits)
	r10 = (short) 0
	r11 = (short) 4
	do 0, r11
	r10 = r10 + 3
	*r1++ = r10                    //! expect 0x101C 0x0000000F
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop
SUB:	r6 = r6 + 10
	return (r5)
	nop
