/* t_dsp's DSP3210 program (tb/dsp3210/asm3210.py): booted by the host
   through the boot ROM's pcw[13] = 0 routine (its vector at location 0,
   INT1), it runs from chip RAM at $10000 in Processor mode and leaves its
   results at $20000:
     $20000  a CA store: $00123456
     $20004  a DA product of the host's 3.0 and 4.0 (at $20100): 12.0
     $20008  the host's long at $20108 plus one
     $2000C  $BE: its bus error handler (a long read of VPOSR, a 16-bit port)
     $20010  $10: its INT0 handler (the host's U124 D0)
     $20014  $5A: about to wait for INT0
   then BIO7 low: the CPU's INT2 (U124 D4 enables it); then it waits (waiti,
   no interrupts enabled) */
	.org 0x10000
START:	evtp = (ushort24) VECT
	r1 = (ushort24) 0x20000
	r2 = (ushort24) 0x123456
	*r1++ = r2
	r3 = (ushort24) 0x20100
	r4 = (ushort24) 0x20104
	nop
	*r1++ = a0 = *r3 * *r4         // 3.0 * 4.0
	r5 = (ushort24) 0x20108
	nop
	r6 = *r5
	nop
	r6 = r6 + 1
	*r1++ = r6
	// a long read of VPOSR ($DFF004): an 8/16-bit port, a bus error
	r7 = (ushort24) 0xDFF004
	nop
	r8 = *r7
	nop
	nop
B1:	r9 = (short) 0x5A
	r10 = (ushort24) 0x20014
	nop
	*r10 = r9
	r11 = (short) 0x0100           // EXT0
	emr = r11
	waiti
	nop
	// BIO7 low: the CPU's INT2
	r12 = (short) 0x80
	r13 = (ushort24) 0x041B
	r13 = r13 <<| 0x5003
	*r13 = (byte) r12              // bioc: BIO7 an output
	r12 = (ushort24) 0x4000        // BF7 01: clear
	r13 = r13 + 3                  // 0x5003041E: bio
	nop
	*r13 = (short) r12
	// done: wait with every interrupt masked (a loop in host memory would
	// keep the bus from the CPU: U123 holds it while the DSP asks)
	r11 = (short) 0
	emr = r11
L9:	waiti
	nop
	pcgoto L9
	nop

EB:	r9 = (short) 0xBE
	r10 = (ushort24) 0x2000C
	nop
	*r10 = r9
	sftrst
	pcgoto B1
	nop
EI0:	r9 = (short) 0x10
	r10 = (ushort24) 0x20010
	nop
	*r10 = r9
	ireturn

	.align 8
VECT:	.long 0, 0                     // 0 reset
	pcgoto EB                      // 1 bus error
	nop
	.long 0, 0, 0, 0, 0, 0         // 2-4
	.long 0, 0, 0, 0, 0, 0         // 5-7
	pcgoto EI0                     // 8 EXT0
	nop
