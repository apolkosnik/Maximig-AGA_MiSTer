; t_dsp: the AA3000+'s DSP3210 on the motherboard (a3kp_dsp3210 through
; a3kp_lbarb; docs/AA3000.md), booted as dsp3210.resource boots it: out of
; reset by U124 ($DD0080), its boot ROM's pcw[13] = 0 routine (BIO4 low)
; waits for INT1 in Processor mode, takes its start from location 0 and
; clears it.  The program (t_dsp.dsp.s) runs from chip RAM:
;   1     U124 releases the DSP: the status shows it running ($BF)
;   2     the boot handshake: location 0 cleared by the DSP
;   3     INT1 acknowledged by the DSP (IACK1): no longer pending
;   4     the DSP's CA store to chip RAM
;   5     its DA product of the host's floats: 12.0
;   6     its load of the host's long, plus one
;   7     its long read of VPOSR (a 16-bit port): a bus error, its handler
;   8     INT0 from U124: its handler; IACK0 drops the request
;   9-10  BIO7 low: the status's CPU INT2 bit, the CPU's level 2 interrupt
;   98    an unexpected exception

	include	"hw.i"

DMAC	equ	$00DD0000
PROG	equ	$00010000
RES	equ	$00020000

	ROMHEADER start
	org	$F80400

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA             ; OVL off
	lea	$8000,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	move.l	#h_lev2,$68.w
	moveq	#0,d0
	movec	d0,vbr
	movec	d0,cacr
	lea	CUSTOM,a6
	move.w	#$7FFF,$9A(a6)
	move.w	#$7FFF,$9C(a6)
	lea	DMAC,a5
	moveq	#0,d7                   ; level 2 interrupts seen

	; the program to chip RAM, the host's data, the results cleared
	lea	dspprog(pc),a0
	lea	PROG,a1
	move.w	#(dspprog_end-dspprog)/4-1,d0
.cp:	move.l	(a0)+,(a1)+
	dbra	d0,.cp
	lea	RES,a1
	moveq	#7,d0
.cl:	clr.l	(a1)+
	dbra	d0,.cl
	move.l	#$40000081,RES+$100     ; 3.0
	move.l	#$00000082,RES+$104     ; 4.0
	move.l	#41,RES+$108
	clr.l	$0.w

	; 1 out of reset, host interrupts enabled, no DSP interrupts
	move.b	#$B3,$80(a5)
	move.l	$5C(a5),d0
	TCHECK	d0,$FFFF00BF,1

	; 2-3 the boot: the start at location 0, INT1 (U124 D1 low) -- after
	; the boot ROM has reached its waiti (64 CKI)
	move.w	#200,d0
.w0:	tst.b	CIAA_PRA
	dbra	d0,.w0
	move.l	#PROG,$0.w
	move.b	#$B1,$80(a5)
	move.l	#200000,d1
.w1:	tst.l	$0.w
	beq.s	.booted
	subq.l	#1,d1
	bne.s	.w1
	move.l	$0.w,d0
	TFAIL	2
.booted:
	move.l	$5C(a5),d0
	and.l	#$00000002,d0           ; DSP INT1: 1, not pending
	TCHECK	d0,$00000002,3
	move.b	#$B3,$80(a5)            ; (D1 back high: no new INT1)

	; 4-7 the results, once the DSP waits for INT0 ($5A)
	move.l	#200000,d1
.w2:	cmp.l	#$5A,RES+$14
	beq.s	.ready
	subq.l	#1,d1
	bne.s	.w2
	move.l	RES+$14,d0
	TFAIL	4
.ready:
	move.l	RES,d0
	TCHECK	d0,$00123456,4
	move.l	RES+4,d0
	TCHECK	d0,$40000083,5
	move.l	RES+8,d0
	TCHECK	d0,42,6
	move.l	RES+$C,d0
	TCHECK	d0,$000000BE,7

	; 8 INT0 (D0 low), acknowledged: the status shows none pending
	move.w	#$C008,$9A(a6)          ; INTEN | PORTS: the DSP's INT2 next
	move	#$2000,sr
	move.b	#$B2,$80(a5)
	move.l	#200000,d1
.w3:	cmp.l	#$10,RES+$10
	beq.s	.int0
	subq.l	#1,d1
	bne.s	.w3
	move.l	RES+$10,d0
	TFAIL	8
.int0:
	move.l	$5C(a5),d0
	and.l	#$00000001,d0
	TCHECK	d0,$00000001,8

	; 9-10 BIO7 low: CPU INT2 (status bit 2 low), the level 2 interrupt
	move.l	#200000,d1
.w4:	tst.l	d7
	bne.s	.lev2
	subq.l	#1,d1
	bne.s	.w4
	move.l	$5C(a5),d0
	TFAIL	10
.lev2:	move	#$2700,sr
	move.l	$5C(a5),d0
	and.l	#$00000004,d0
	TCHECK	d0,$00000000,9
	cmp.l	#1,d7
	bhs.s	.l2ok
	TFAIL	10
.l2ok:
	; the DSP back in reset: its INT2 gone
	move.b	#$33,$80(a5)
	TPASS	0

; the level-2 handler: a count, INT2 masked at U124 (the DSP keeps BIO7 low)
h_lev2:
	addq.l	#1,d7
	move.b	#$A3,DMAC+$80           ; INT2 inhibited
	move.w	#$0008,$9C(a6)
	rte

unexpected:
	move.l	2(sp),d0                ; the stacked PC
	PUTHEX	d0
	move.w	6(sp),d0                ; format/vector
	PUTHEX	d0
	TFAIL	98

	cnop	0,4
dspprog:
	incbin	"build/t_dsp.dsp.bin"
dspprog_end:
