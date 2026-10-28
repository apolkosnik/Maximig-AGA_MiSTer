/* The bit I/O (9.4: bioc, bio's write pairs and its {register, pin} read
   pairs), tcon read back, pcw[13:10] from BIO4-7 at reset (the bench's
   pins: BIO6 high, the rest low) */
	r2 = (ushort24) 0x1000
	r1 = (ushort24) 0x041E
	r1 = r1 <<| 0x5003             // bio
	r3 = (ushort24) 0x041B
	r3 = r3 <<| 0x5003             // bioc
	r4 = (ushort24) 0x0413
	r4 = r4 <<| 0x5003             // tcon
	r5 = (short) 0x0F              // BIO3-0 outputs
	*r3 = (byte) r5
	r5 = (short) 0x3A              // BF0 set, BF1 set, BF2 toggle, BF3 keep
	*r1 = (short) r5
	nop
	r6 = (ushort) *r1
	nop
	*r2++ = r6                     // {1,1} {1,1} {1,1}, BIO6's pin 1   //! expect 0x1000 0x0000103F
	r5 = (short) 0x31              // BF0 clear, BF2 toggle
	*r1 = (short) r5
	nop
	r6 = (ushort) *r1
	nop
	*r2++ = r6                     //! expect 0x1004 0x0000100C
	r5 = (ushort24) 0xA000         // the inputs' register bits set: BIO6 {1,1}, BIO7 {1,0}
	*r1 = (short) r5
	nop
	r6 = (ushort) *r1
	nop
	*r2++ = r6                     //! expect 0x1008 0x0000B00C
	r6 = (byte) *r3
	nop
	*r2++ = r6                     //! expect 0x100C 0x0000000F
	r5 = (short) 0x12              // held, reload, pulse high-active off ...
	*r4 = (byte) r5
	nop
	r6 = (byte) *r4
	nop
	*r2++ = r6                     //! expect 0x1010 0x00000012
	r6 = pcw
	nop
	r7 = (ushort24) 0x3C00
	r6 = r6 & r7
	*r2++ = r6                     // pcw[10] BIO7, [11] BIO6 (Table 10-8) //! expect 0x1014 0x00000800
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop
