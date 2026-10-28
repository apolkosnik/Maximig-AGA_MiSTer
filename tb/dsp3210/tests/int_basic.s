/* Interrupts (7.5.1): the vector table at evtp, waiti, the shadowed
   accumulators and dauc, ireturn resuming the interrupted loop, the quick
   interrupt (an entry's two words as the routine) and the timer */
//! args --irq1 100 --irq0 400
	evtp = (ushort24) TABLE
	r2 = (ushort24) 0x1000
	r12 = (short) 0
	r13 = (short) 0
	r14 = (short) 0
	r8 = (short) 0
	r1 = (ushort24) ONE
	a0 = *r1                       // 1.0 (shadowed by the interrupts)
	r5 = (short) 0
	dauc = r5
	r6 = (ushort24) 0x8300         // EXT1, TIMER, EXT0
	emr = r6
	// waiti: the instruction after it runs before the interrupt routine
	waiti
	r13 = (short) 5
	nop
	*r2++ = r12                    // the quick routine's r13 + 1    //! expect 0x1000 0x00000006
	// a loop interrupted by EXT0 (at cycle 400): it still runs its count
	r7 = (short) 0
	r9 = (short) 199
L1:	r7 = r7 + 1
	if (r9-- >= 0) pcgoto L1
	nop
	*r2++ = r7                     // 200 taken: the body 201 times  //! expect 0x1004 0x000000C9
	*r2++ = r9                     //! expect 0x1008 0xFFFFFFFE
	*r2++ = r8                     // the routine ran once           //! expect 0x100C 0x00000001
	*r2++ = a0 = a0                // the routine's a0 = 2.0 undone  //! expect 0x1010 0x00000080
	r5 = dauc
	nop                            // (restriction 3)
	*r2++ = r5                     // the routine's dauc undone      //! expect 0x1014 0x00000000
	// the timer, one shot: 50 counts of CKI/2, then one interrupt; the
	// count stops at zero (the bench's instruction cycles are longer than
	// four CKI: the checks use the timer itself, not instruction counts)
	r4 = (ushort24) 0x0414
	r4 = r4 <<| 0x5003             // 0x50030414: timer
	r3 = r4 - 1                    // 0x50030413: tcon
	r5 = (short) 50
	*r4 = r5
	r5 = (short) 1                 // enabled, one shot, CKI/2
	*r3 = (byte) r5
	nop
	r10 = *r4                      // counting down: 0 < count < 50
	nop
	r10 - 0
	if (le) pcgoto FAIL
	r10 - 50
	if (ge) pcgoto FAIL
	nop
L2:	r14 - 0
	if (eq) pcgoto L2
	nop
	*r2++ = r14                    //! expect 0x1018 0x00000001
	r9 = (short) 100
L3:	if (r9-- >= 0) pcgoto L3
	nop
	*r2++ = r14                    // no second interrupt     //! expect 0x101C 0x00000001
	r10 = *r4
	nop
	*r2++ = r10                    // stopped at zero         //! expect 0x1020 0x00000000
	// reloading: a period of 100 counts, interrupts while the loop runs
	r14 = (short) 0
	r5 = (short) 99
	*r4 = r5
	r5 = (short) 3                 // enabled, reload, CKI/2
	*r3 = (byte) r5
	r9 = (short) 400
L4:	if (r9-- >= 0) pcgoto L4
	nop
	r5 = (short) 0
	*r3 = (byte) r5                // held
	nop
	r10 = *r4                      // a count within the period
	nop
	r10 - 99
	if (gt) pcgoto FAIL
	r14 - 10                       // 401 x 2 instructions: many periods
	if (lt) pcgoto FAIL
	nop
	r11 = (short) 0x77
	*r2++ = r11                    //! expect 0x1024 0x00000077
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop
FAIL:	*r2++ = r10
	pcgoto L9
	nop

ISR0:	r8 = r8 + 1
	r1 = (ushort24) TWO
	a0 = *r1                       // 2.0
	r5 = (short) 0x30
	dauc = r5
	nop
	nop
	ireturn

TISR:	r14 = r14 + 1
	ireturn

	.align 8
TABLE:	.long 0, 0                     // 0 reset
	.long 0, 0, 0, 0, 0, 0, 0, 0   // 1-4
	.long 0, 0, 0, 0, 0, 0         // 5-7
	pcgoto ISR0                    // 8 EXT0
	nop
	pcgoto TISR                    // 9 timer
	nop
	.long 0, 0, 0, 0, 0, 0, 0, 0   // 10-13
	.long 0, 0                     // 14
	r12 = r13 + 1                  // 15 EXT1: a quick routine
	ireturn
ONE:	.float 1.0
TWO:	.float 2.0
