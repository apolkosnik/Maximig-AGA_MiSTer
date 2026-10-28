/* CA arithmetic, moves and flags (4.3), run in Processor mode from 0 */
	r1 = (ushort24) 0x1000         // the results
	r2 = (short) 5
	r3 = (short) -3
	r4 = r2 + r3
	*r1++ = r4                     //! expect 0x1000 0x00000002
	r5 = r2 - r3
	*r1++ = r5                     //! expect 0x1004 0x00000008
	r6 = r2 <<| 0x1234
	*r1++ = r6                     //! expect 0x1008 0x12340005
	r7 = (ushort24) 0xABCDEF
	*r1++ = r7                     //! expect 0x100C 0x00ABCDEF
	r8 = r7
	r8 = r8 >> 4
	*r1++ = r8                     //! expect 0x1010 0x000ABCDE
	r9 = r3 / 2
	*r1++ = r9                     //! expect 0x1014 0xFFFFFFFE
	r9 = r3 & r7
	*r1++ = r9                     //! expect 0x1018 0x00ABCDED
	r9 = r2 | r7
	*r1++ = r9                     //! expect 0x101C 0x00ABCDEF
	r9 = r2 ^ r3
	*r1++ = r9                     //! expect 0x1020 0xFFFFFFF8
	r9 = r2 << r2
	*r1++ = r9                     //! expect 0x1024 0x000000A0
	// conditionals: r2 - r3 > 0
	r2 - r3
	if (gt) r10 = r2 + r2
	if (le) r10 = r3
	*r1++ = r10                    //! expect 0x1028 0x0000000A
	// (short) arithmetic: 0x7FFF + 1 = 0xFFFF8000 (sign-extended), v set
	r14 = (short) 1
	r15 = (short) 2
	r11 = (short) 0x7FFF
	r11 = (short) r11 + 1
	*r1++ = r11                    //! expect 0x102C 0xFFFF8000
	if (vs) r12 = r14              // (executed: it sets the flags itself)
	*r1++ = r12                    //! expect 0x1030 0x00000001
	// loads and stores of each size
	r13 = (ushort24) 0x2000
	r14 = (ushort24) 0x80A1B2
	r14 = r14 <<| 0xC3D4
	*r13 = r14                     // 0xC3D4A1B2
	nop
	r15 = (byte) *r13              // the byte at 0x2000
	r16 = (char) *r13
	r17 = (ushort) *r13
	r18 = (short) *r13
	*r1++ = r15                    //! expect 0x1034 0x000000C3
	*r1++ = r16                    //! expect 0x1038 0xFFFFFFC3
	*r1++ = r17                    //! expect 0x103C 0x0000C3D4
	*r1++ = r18                    //! expect 0x1040 0xFFFFC3D4
	r19 = (short) 0x1234
	*r13++ = (byte) r19
	*r13++ = (byte) r19
	*r13++ = (short) r19
	nop
	r13 = (ushort24) 0x2000
	r20 = *r13
	nop
	*r1++ = r20                    //! expect 0x1044 0x34341234
	r19 = (short) 0x5678
	r13 = (ushort24) 0x2004
	*r13 = (hbyte) r19
	nop
	r20 = (byte) *r13
	nop
	*r1++ = r20                    //! expect 0x1048 0x00000056
	// done
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L:	pcgoto L
	nop
