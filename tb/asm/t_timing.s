; t_timing: Copperline's accelprobe rows (timing-test/accelprobe.asm), the
; same loops and the same CIA-A timer A measurement in E-clock ticks, run on
; the real machine (tb/system --z3 1: 16 MB motherboard RAM, a 128 MB Zorro
; III RAM board).  The values compare directly with the real A4000 + A3640
; (68040 at 25 MHz) columns recorded in accelprobe.asm:
;
;   row  6 move.w d2,d0 + dbra x4096          real $01DA
;   row  7 dbra x4096                         real $01D8
;   row  8 mulu #$5555,d5 + dbra x4096        real $065E
;   row  9 trap #0 + rte x1024, SSP in chip   real $1844
;   row 10 trap #0 + rte x1024, SSP in fast1  real $09AD
;   row 11 bsr/rts, near x4096                real $3077
;   row 12 move.l (a2),a0 + jsr (a0) x4096    real $5730
;   row 13 jsr/rts, target in fast1 x4096     real $3075
;   row 14 movem 11 regs push+pop x1024, fast1 real $0DA8
;   row 15 cpushl dc,(a0) stride 16 x4096     real $06D9
;   row 16 chip read move.l stride 16 x4096   real $26C3
;   row 17 chip write move.l stride 16 x4096  real $09B7
;   row 19 fast1 (motherboard) read           real $0ECD
;   row 20 fast1 (motherboard) write          real $042B
;   row 22 fast2 (Zorro III) read             real $1832 (a ZZ9000)
;   row 23 fast2 (Zorro III) write            real $05EF (a ZZ9000)
;
; Each row is reported as a long word $RRxxxxxx: the row number in the top
; byte, the ticks below.  The comparison is tb/system/timing_check.py.

	include	"hw.i"

ITER4K	equ	4096
ITER1K	equ	1024
CHIPW	equ	$60000
FAST1W	equ	$07E10000           ; motherboard RAM (Ramsey)
FAST2W	equ	$40010000           ; the Zorro III RAM board, configured at $40000000

	ROMHEADER start

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA
	lea	$2000.w,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	move.l	#trap0,$80.w
	TPRINT	msg_start

	; the chain: the 128 MB Zorro III RAM board first, then the RTG board,
	; the A2065 and the Toccata
	move.w	#$4000,$E80044          ; Z3 RAM at $40000000
	move.w	#$4800,$E80044          ; RTG at $48000000
	move.b	#$E9,$E80048            ; A2065
	move.b	#$EA,$E80048            ; Toccata

	; the cache state accelprobe sets on a 68040
	cpusha	bc
	moveq	#0,d0
	movec	d0,tc
	movec	d0,itt0
	movec	d0,itt1
	movec	d0,dtt0
	movec	d0,dtt1
	move.l	#$80008000,d0           ; CACR: EDC | EIC
	movec	d0,cacr

	move.w	#$7FFF,CUSTOM+$9A       ; no interrupts
	moveq	#1,d2
	moveq	#3,d5

	; --- rows 6-8: CPU anchors ------------------------------------------
	cnop	0,4
	bsr	tstart
	move.w	#ITER4K-1,d6
.t6:	move.w	d2,d0
	dbra	d6,.t6
	bsr	tread
	moveq	#6,d7
	bsr	report

	cnop	0,4
	bsr	tstart
	move.w	#ITER4K-1,d6
.t7:	dbra	d6,.t7
	bsr	tread
	moveq	#7,d7
	bsr	report

	cnop	0,4
	bsr	tstart
	move.w	#ITER4K-1,d6
.t8:	mulu	#$5555,d5
	dbra	d6,.t8
	bsr	tread
	moveq	#8,d7
	bsr	report

	; --- rows 9/10: trap round trip, chip vs fast SSP --------------------
	cnop	0,4
	bsr	tstart
	move.w	#ITER1K-1,d6
.t9:	trap	#0
	dbra	d6,.t9
	bsr	tread
	moveq	#9,d7
	bsr	report

	move.l	sp,a6
	lea	FAST1W+$18000,sp
	cnop	0,4
	bsr	tstart
	move.w	#ITER1K-1,d6
.t10:	trap	#0
	dbra	d6,.t10
	bsr	tread
	move.l	a6,sp
	moveq	#10,d7
	bsr	report

	; --- rows 11-13: calls ---------------------------------------------
	cnop	0,4
	bsr	tstart
	move.w	#ITER4K-1,d6
.t11:	bsr	nearrts
	dbra	d6,.t11
	bsr	tread
	moveq	#11,d7
	bsr	report

	lea	vecblk(pc),a2
	cnop	0,4
	bsr	tstart
	move.w	#ITER4K-1,d6
.t12:	movea.l	(a2),a0
	jsr	(a0)
	dbra	d6,.t12
	bsr	tread
	moveq	#12,d7
	bsr	report

	lea	FAST1W+$1C000,a0
	move.w	#$4E75,(a0)             ; rts
	cpusha	bc
	cnop	0,4
	bsr	tstart
	move.w	#ITER4K-1,d6
.t13:	jsr	(a0)
	dbra	d6,.t13
	bsr	tread
	moveq	#13,d7
	bsr	report

	; --- row 14: movem push+pop, SP in fast1 ---------------------------
	move.l	sp,a6
	lea	FAST1W+$18000,sp
	cnop	0,4
	bsr	tstart
	move.w	#ITER1K-1,d6
.mm:	movem.l	d0-d5/a0-a4,-(sp)
	movem.l	(sp)+,d0-d5/a0-a4
	dbra	d6,.mm
	bsr	tread
	move.l	a6,sp
	moveq	#14,d7
	bsr	report

	; --- row 15: cpushl line walk over fast1 ---------------------------
	lea	FAST1W,a0
	cnop	0,4
	bsr	tstart
	move.w	#ITER4K-1,d6
.t15:	cpushl	dc,(a0)
	lea	16(a0),a0
	dbra	d6,.t15
	bsr	tread
	moveq	#15,d7
	bsr	report

	; --- rows 16/17: chip window ---------------------------------------
	movea.l	#CHIPW,a0
	bsr	regread
	moveq	#16,d7
	bsr	report
	movea.l	#CHIPW,a0
	bsr	regwrite
	moveq	#17,d7
	bsr	report

	; --- rows 19/20: motherboard RAM ------------------------------------
	movea.l	#FAST1W,a0
	bsr	regread
	moveq	#19,d7
	bsr	report
	movea.l	#FAST1W,a0
	bsr	regwrite
	moveq	#20,d7
	bsr	report

	; --- rows 22/23: Zorro III RAM ---------------------------------------
	movea.l	#FAST2W,a0
	bsr	regread
	moveq	#22,d7
	bsr	report
	movea.l	#FAST2W,a0
	bsr	regwrite
	moveq	#23,d7
	bsr	report

	TPRINT	msg_done
	TPASS	0

;------------------------------------------------------------------------------
	cnop	0,4
regread:
	bsr	tstart
	move.w	#ITER4K-1,d6
.rr:	move.l	(a0),d0
	lea	16(a0),a0
	dbra	d6,.rr
	bsr	tread
	rts
	cnop	0,4
regwrite:
	bsr	tstart
	move.w	#ITER4K-1,d6
.rw:	move.l	d1,(a0)
	lea	16(a0),a0
	dbra	d6,.rw
	bsr	tread
	rts

tstart:
	move.b	#$ff,$bfe401
	move.b	#$ff,$bfe501
	move.b	#$19,$bfee01
	rts

tread:
	move.b	#$08,$bfee01
	moveq	#0,d0
	move.b	$bfe501,d0
	lsl.w	#8,d0
	move.b	$bfe401,d0
	not.w	d0
	rts

; the row in d7, the ticks in d0
report:
	ror.l	#8,d7
	and.l	#$FFFF,d0
	or.l	d7,d0
	PUTHEX	d0
	rts

nearrts:
	rts

	cnop	0,4
vecblk:	dc.l	nearrts

trap0:	rte

print_str:
	moveq	#0,d0
.p:	move.b	(a0)+,d0
	beq.s	.e
	PUTC	d0
	bra.s	.p
.e:	rts

unexpected:
	move.l	2(sp),d0
	PUTHEX	d0
	move.w	6(sp),d0
	PUTHEX	d0
	TFAIL	255

msg_start:	dc.b	"t_timing: accelprobe rows (E-clock ticks)",10,0
msg_done:	dc.b	"t_timing: done",10,0
	even
