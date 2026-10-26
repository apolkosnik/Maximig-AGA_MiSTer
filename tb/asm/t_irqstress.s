; t_irqstress: interrupts into a busy user-mode program, on the real machine
; (tb/system).  cputest on the Amiga (4_AE FPP, MMU.lib building its page
; tables) went from a level-3 interrupt's entry to $14 -- the old SR it had
; just stacked -- instead of the handler the vector fetch returned.  This
; runs a user-mode loop that keeps the data unit busy (MOVEM, copies and
; compares in motherboard RAM, its stacks there) and mispredicts returns
; (a subroutine that rewrites its return address every other call), while
; CIA-A timer A interrupts at level 2 every ~21 us and the VBL at level 3.
; Caches on; chip RAM and the I/O space cache-inhibited (DTT0), as the OS
; has them.
;
;  1      an exception other than the two interrupts (bench: its frame)
;  2      the copy did not compare
;  3      a mispredicted return went the wrong way
;  4      the loop's registers were not restored
;  passes after 6000 iterations with more than 500 level-2 and some
;  level-3 interrupts

	include	"hw.i"

CIAA	equ	$BFE001
SSPTOP	equ	$07F00000
USPTOP	equ	$07E00000
BUF1	equ	$07D00000
BUF2	equ	$07D01000
CNT2	equ	$07C00000
CNT3	equ	$07C00004
LOOPS	equ	$07C00008

	ROMHEADER start

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA             ; OVL off
	lea	SSPTOP,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	move.l	#h_lev2,$68.w
	move.l	#h_lev3,$6C.w
	moveq	#0,d0
	movec	d0,vbr
	clr.l	CNT2
	clr.l	CNT3
	clr.l	LOOPS
	; the copy's source
	lea	BUF1,a0
	move.l	#$12345678,d1
	move.w	#15,d0
.fill:	move.l	d1,(a0)+
	rol.l	#5,d1
	addq.l	#1,d1
	dbra	d0,.fill
	; caches: chip RAM and $00xxxxxx I/O inhibited, the rest copyback
	move.l	#$0000C040,d0
	movec	d0,dtt0
	moveq	#0,d0
	movec	d0,dtt1
	movec	d0,itt0
	movec	d0,itt1
	cpusha	bc
	move.l	#$80008000,d0
	movec	d0,cacr
	; CIA-A timer A: continuous, 15 E ticks, interrupt
	lea	CUSTOM,a1
	move.w	#$7FFF,$9A(a1)
	move.w	#$7FFF,$9C(a1)
	move.b	#$7F,CIAA+$D00          ; ICR: all off
	tst.b	CIAA+$D00
	move.b	#15,CIAA+$400           ; TALO
	move.b	#0,CIAA+$500            ; TAHI
	move.b	#$11,CIAA+$E00          ; CRA: start, continuous, load
	move.b	#$81,CIAA+$D00          ; ICR: TA on
	move.w	#$C028,$9A(a1)          ; INTEN, PORTS, VERTB
	; user mode
	lea	USPTOP,a0
	move.l	a0,usp
	move.w	#$0000,sr

	moveq	#0,d6                   ; iteration
main:
	move.l	#$A5A5A5A5,d7
	move.l	d6,d5
	bsr.w	work
back:
	; a rewritten return comes back to alt, never here
	btst	#0,d6
	beq.s	.even
	move.l	#3,MBOX
.hang1:	bra.s	.hang1
.even:
alt:
	cmpi.l	#$A5A5A5A5,d7
	bne.s	bad_regs
	cmp.l	d6,d5
	bne.s	bad_regs
	addq.l	#1,d6
	move.l	d6,LOOPS
	cmpi.l	#6000,d6
	bcs.s	main
	; enough: the interrupts too?
	cmpi.l	#500,CNT2
	bls.s	main
	tst.l	CNT3
	beq.s	main
	move.l	#$600D0000,MBOX
.done:	bra.s	.done

bad_regs:
	move.l	#$BAD00004,MBOX
.h4:	bra.s	.h4

; copy 64 bytes BUF1 -> BUF2 and compare; every odd iteration return to alt
work:
	movem.l	d0-d4/d6/a0-a3,-(sp)
	lea	BUF1,a0
	lea	BUF2,a1
	movem.l	(a0)+,d0-d4/a2-a3
	movem.l	d0-d4/a2-a3,(a1)
	lea	-28(a0),a0
	moveq	#6,d0
.cmp:	cmpm.l	(a0)+,(a1)+
	bne.s	.bad
	dbra	d0,.cmp
	movem.l	(sp)+,d0-d4/d6/a0-a3
	btst	#0,d6
	beq.s	.ret
	move.l	#alt,(sp)
.ret:
	tst.l	d0
	rts
.bad:
	move.l	#$BAD00002,MBOX
.h2:	bra.s	.h2

h_lev2:
	tst.b	CIAA+$D00               ; ICR: read clears
	move.w	#$0008,CUSTOM+$9C
	move.w	#$0008,CUSTOM+$9C
	addq.l	#1,CNT2
	rte

h_lev3:
	move.w	#$0020,CUSTOM+$9C
	move.w	#$0020,CUSTOM+$9C
	addq.l	#1,CNT3
	rte

unexpected:
	move.l	(sp),MBOX+8             ; SR and the PC's high word
	move.l	4(sp),MBOX+8            ; the PC's low word, format/vector
	move.l	#$BAD00001,MBOX
.h:	bra.s	.h
