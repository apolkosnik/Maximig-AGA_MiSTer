; t_rtr: the PC sampler's recorder (a MAXIMIG_PCSAMPLE build: tb/system
; built with -DMAXIMIG_PCSAMPLE=1 -DMAXIMIG_RTR_ARM_BITS=8, or the board's
; recorder build with t_rtr_board.rom as the Kickstart ROM).  A loop of
; subroutine calls under CIA-A timer interrupts at level 2 fills the
; retired-PC ring (t_rtr_board: 800000 iterations, past the board's arming
; count; the bench's 600 past its own), then a jump to $100
; -- a PC in $2-$3FF -- freezes it; the code there waits for the rings to
; reach DDR3 and reports.  The bench writes DDR3 0x27FF6000-0x27FF7FFF out
; with --ddrdump (on the board: memdump 0x27FF6000 0x2000), and rec.py
; decodes it: the ring must end with the loop, the jump and the landing at
; $100, each entry's info word its first/last bits, an interrupt's entry the
; kill bit on the uop before it and the routine's retire (exr) at PC 0, the
; handler fetch of $68 in the events and on the bus.
;
;  PASS 0 after the wait at $100; 1 an exception other than the level-2
;  interrupt (its format/vector word and PC in hex)
;  On the board the screen is COLOR00: yellow running, green at $100, red
;  after an unexpected exception.

	include	"hw.i"

CIAA	equ	$BFE001
	ifd	BOARD
LOOPS	equ	800000                  ; the board's ring arms after 2^22 retires
	else
LOOPS	equ	600                     ; the bench's (MAXIMIG_RTR_ARM_BITS=8) after 256
	endif

	ROMHEADER start
	org	$F80400                 ; (a PC in $F800xx freezes the ring)

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA             ; OVL off
	lea	$20000,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	move.l	#h_lev2,$68.w
	moveq	#0,d0
	movec	d0,vbr
	; the landing code to $100
	lea	land,a0
	lea	$100.w,a1
	moveq	#15,d0
.cp:	move.l	(a0)+,(a1)+
	dbra	d0,.cp
	; caches on; chip RAM and the $00xxxxxx I/O (the CIA, the mailbox)
	; cache-inhibited for data, instructions cacheable everywhere
	move.l	#$0000C040,d0
	movec	d0,dtt0
	moveq	#0,d0
	movec	d0,dtt1
	movec	d0,itt0
	movec	d0,itt1
	cinva	bc
	move.l	#$80008000,d0
	movec	d0,cacr
	; CIA-A timer A: continuous, 15 E ticks, interrupt
	lea	CUSTOM,a1
	move.w	#$7FFF,$9A(a1)
	move.w	#$7FFF,$9C(a1)
	move.w	#$7FFF,$96(a1)          ; no DMA: the screen is COLOR00
	move.w	#$0FF0,$180(a1)         ; yellow: running
	move.b	#$7F,CIAA+$D00          ; ICR: all off
	tst.b	CIAA+$D00
	move.b	#15,CIAA+$400           ; TALO
	move.b	#0,CIAA+$500            ; TAHI
	move.b	#$11,CIAA+$E00          ; CRA: start, continuous, load
	move.b	#$81,CIAA+$D00          ; ICR: TA on
	move.w	#$C008,$9A(a1)          ; INTEN, PORTS
	move.w	#$2000,sr               ; interrupts on
	moveq	#0,d6
	moveq	#0,d7
loop:
	bsr.w	sub
	addq.l	#1,d6
	cmpi.l	#LOOPS,d6
	bcs.s	loop
	jmp	$100.w

sub:
	tst.l	d0
	rts

; copied to $100: wait (from the cache: the bus idle for the dump), report
land:
	move.w	#$00F0,CUSTOM+$180      ; green: at $100, the ring frozen
	move.l	#200000,d0
.w:	subq.l	#1,d0
	bne.s	.w
	move.l	#$600D0000,MBOX
.h:	bra.s	.h

h_lev2:
	tst.b	CIAA+$D00               ; ICR: read clears
	move.w	#$0008,CUSTOM+$9C
	move.w	#$0008,CUSTOM+$9C
	addq.l	#1,d7
	rte

unexpected:
	move.w	#$0F00,CUSTOM+$180      ; red
	moveq	#0,d0
	move.w	6(sp),d0                ; the format/vector word
	PUTHEX	d0
	move.l	2(sp),d0
	PUTHEX	d0                      ; the PC
	move.l	#$BAD00001,MBOX
.h:	bra.s	.h
