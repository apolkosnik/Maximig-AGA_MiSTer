; t_blitter: the blits of tb/system/blitter_check.py on the real machine.
;
; The table (build/blit_tab.bin, written by blitter_check.py): the number of
; blits, the end of the area to fill, then 48 bytes a blit:
;   +0 BLTCON0  +2 BLTCON1  +4 BLTAFWM  +6 BLTALWM
;   +8 BLTAPT   +12 BLTBPT  +16 BLTCPT  +20 BLTDPT
;   +24 BLTAMOD +26 BLTBMOD +28 BLTCMOD +30 BLTDMOD
;   +32 BLTADAT +34 BLTBDAT +36 BLTCDAT
;   +38 BLTSIZE (0: BLTSIZV +40 then BLTSIZH +42, the ECS start)
;   +44 the address of the last word D writes (0: none, or a line)
; Chip RAM from $20000 to the end of the area is filled with an xorshift32
; stream first; DMACONR after blit n goes to $10000 + 2n, and the last word
; D wrote, read as soon as BBUSY clears, to $14000 + 2n (AGA holds BBUSY
; until that write has been done).  The bench dumps
; chip RAM when the run ends, and blitter_check.py compares it with its
; model of the blitter.

	include	"hw.i"

FILL	equ	$00020000
ZTAB	equ	$00010000
RACE	equ	$00018000
RACE2	equ	$00018100
LTAB	equ	$00014000               ; the last D word, read as BBUSY clears

	ROMHEADER start

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA
	lea	$2000.w,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	TPRINT	msg_start
	cinva	ic
	move.l	#$00008000,d0           ; CACR: the instruction cache (data: off,
	movec	d0,cacr                 ; the custom registers polled are uncached)
	lea	CUSTOM,a1
	move.w	#$7FFF,$9A(a1)
	move.w	#$7FFF,$9C(a1)
	move.w	#$7FFF,$96(a1)
	move.w	#$8240,$96(a1)          ; DMAEN, BLTEN

	; the fill (blitter_check.py xorshift_fill)
	lea	FILL,a0
	move.l	tab+4,a2
	move.l	#$2545F491,d0
	moveq	#13,d3
	moveq	#17,d4
.fill:	move.l	d0,d1
	lsl.l	d3,d1
	eor.l	d1,d0
	move.l	d0,d1
	lsr.l	d4,d1
	eor.l	d1,d0
	move.l	d0,d1
	lsl.l	#5,d1
	eor.l	d1,d0
	move.l	d0,(a0)+
	cmp.l	a2,a0
	blo.s	.fill
	TMARK	1

	lea	tab,a0
	move.l	(a0)+,d7                ; blits
	addq.l	#4,a0
	lea	ZTAB,a3
	subq.l	#1,d7
.blit:	move.w	(a0)+,$40(a1)           ; BLTCON0
	move.w	(a0)+,$42(a1)           ; BLTCON1
	move.w	(a0)+,$44(a1)           ; BLTAFWM
	move.w	(a0)+,$46(a1)           ; BLTALWM
	move.l	(a0)+,$50(a1)           ; BLTAPT
	move.l	(a0)+,$4C(a1)           ; BLTBPT
	move.l	(a0)+,$48(a1)           ; BLTCPT
	move.l	(a0)+,$54(a1)           ; BLTDPT
	move.w	(a0)+,$64(a1)           ; BLTAMOD
	move.w	(a0)+,$62(a1)           ; BLTBMOD
	move.w	(a0)+,$60(a1)           ; BLTCMOD
	move.w	(a0)+,$66(a1)           ; BLTDMOD
	move.w	(a0)+,$74(a1)           ; BLTADAT
	move.w	(a0)+,$72(a1)           ; BLTBDAT
	move.w	(a0)+,$70(a1)           ; BLTCDAT
	move.w	(a0)+,d0
	beq.s	.ecs
	move.w	d0,$58(a1)              ; BLTSIZE: go
	addq.l	#4,a0
	bra.s	.wait
.ecs:	move.w	(a0)+,$5C(a1)           ; BLTSIZV
	move.w	(a0)+,$5E(a1)           ; BLTSIZH: go
.wait:	move.l	(a0)+,a4                ; the last word D writes (0: none)
	tst.w	$02(a1)                 ; (the first read after the start)
.busy:	btst	#6,$02(a1)              ; BBUSY
	bne.s	.busy
	move.l	a4,d0
	beq.s	.nod
	move.w	(a4),LTAB-ZTAB(a3)      ; read at once: it must be written
.nod:	move.w	$02(a1),(a3)+           ; DMACONR: BZERO
	dbra	d7,.blit

	; the race: BLTDPT rewritten the moment BBUSY clears.  AGA holds BBUSY
	; until the final D write (WinUAE: "AGA has workaround delay circuit
	; that adds 2 extra cycles if D is enabled and not line mode"), so the
	; blit's last word lands where it belongs, not at the new pointer
	moveq	#0,d6                   ; delay after the start, in loop turns
.race:	lea	RACE,a2
	clr.l	(a2)
	clr.l	4(a2)
	clr.l	RACE2-RACE(a2)
	clr.l	RACE2-RACE+4(a2)
	move.w	#$01FF,$40(a1)          ; BLTCON0: D, D = 1
	clr.w	$42(a1)
	move.l	a2,$54(a1)              ; BLTDPT
	clr.w	$66(a1)
	move.w	d6,d0
.dly:	dbra	d0,.dly
	move.w	#(1<<6)|4,$58(a1)       ; 4 x 1
	tst.w	$02(a1)
.rbusy:	btst	#6,$02(a1)
	bne.s	.rbusy
	move.l	#RACE2,$54(a1)          ; the next blit's BLTDPT, at once
	move.w	#50,d0
.set:	dbra	d0,.set
	move.l	4(a2),d0
	TCHECK	d0,$FFFFFFFF,2          ; the last two words of the blit
	move.l	RACE2-RACE(a2),d0
	TCHECK	d0,$00000000,3          ; nothing at the new pointer
	addq.w	#1,d6
	cmp.w	#8,d6
	bne.w	.race

	TPASS	0

unexpected:
	TFAIL	99

print_str:
	moveq	#0,d0
.c:	move.b	(a0)+,d0
	beq.s	.e
	PUTC	d0
	bra.s	.c
.e:	rts

msg_start:	dc.b	"t_blitter",10,0
	cnop	0,4
tab:	incbin	"build/blit_tab.bin"
