; t_chipset: chip behaviour the board test does not reach, on the real
; machine (tb/system).
;
;  1-9    the HAM palette: an AGA palette read (BPLCON2 RDRAM) must not
;         write it; a HAM6 screen showing palette entry 1, red, stays red
;         (bench: mark 5 reports the frame's dominant colour at $1F10)
;  10-19  CIA-B TOD: writes to another register of the CIA around the
;         ticks do not lose the count or the carry ($000FFF + 1 = $001000)
;  20-29  CIA-A ICR: an interrupt that has occurred stays pending (IR) when
;         its mask bit is cleared, until ICR is read
;  30-39  CIA-A TOD: reading the high byte latches the count for the low
;         byte with CRB7 (ALARM) set too
;  40-49  CIA-A port B: output bits read back from the output register

	include	"hw.i"

CIAA	equ	$BFE001
CIAB	equ	$BFD000
PLANE1	equ	$00004000               ; 40 bytes of ones
PLANEZ	equ	$00004100               ; 40 bytes of zeros (planes 2-6)

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
	lea	CUSTOM,a1
	move.w	#$7FFF,$9A(a1)
	move.w	#$7FFF,$9C(a1)

;--- the HAM palette and RDRAM --------------------------------------------------
	lea	PLANE1,a0
	lea	PLANEZ,a2
	moveq	#9,d0
.pl:	move.l	#$FFFFFFFF,(a0)+
	clr.l	(a2)+
	dbra	d0,.pl
	move.w	#$7FFF,$96(a1)
	move.w	#$2C81,$8E(a1)          ; DIWSTRT
	move.w	#$2CC1,$90(a1)          ; DIWSTOP
	move.w	#$0038,$92(a1)          ; DDFSTRT
	move.w	#$00D0,$94(a1)          ; DDFSTOP
	move.w	#-40,$108(a1)           ; BPL1MOD: every line the same 40 bytes
	move.w	#-40,$10A(a1)           ; BPL2MOD
	clr.w	$102(a1)                ; BPLCON1
	clr.w	$104(a1)                ; BPLCON2
	move.w	#$0C00,$106(a1)         ; BPLCON3 (AGA default)
	clr.w	$1FC(a1)                ; FMODE
	move.l	#PLANE1,$E0(a1)         ; plane 1: ones -> pixel value 000001
	move.l	#PLANEZ,$E4(a1)
	move.l	#PLANEZ,$E8(a1)
	move.l	#PLANEZ,$EC(a1)
	move.l	#PLANEZ,$F0(a1)
	move.l	#PLANEZ,$F4(a1)         ; planes 5, 6: 00 = HAM "set" from the palette
	clr.w	$180(a1)                ; COLOR00 black
	move.w	#$0F00,$182(a1)         ; COLOR01 red (both palettes)
	move.w	#$6A00,$100(a1)         ; BPLCON0: 6 planes, HAM, colour
	move.w	#$0100,$104(a1)         ; BPLCON2: RDRAM
	move.w	$182(a1),d0             ; a palette read
	clr.w	$104(a1)                ; RDRAM off
	and.l	#$0FFF,d0
	TCHECK	d0,$0F00,1              ; the read gives the palette's red
	move.w	#$8300,$96(a1)          ; DMAEN | BPLEN
	clr.w	$1F14.w
	TMARK	5                       ; the bench: the next frame's colour
	move.l	#400000,d1
.cw:	cmp.w	#$AA55,$1F14.w
	beq.s	.cgot
	subq.l	#1,d1
	bne.s	.cw
	TFAIL	2
.cgot:	move.w	#$7FFF,$96(a1)
	moveq	#0,d0
	move.w	$1F10.w,d0
	swap	d0
	move.w	$1F12.w,d0
	TCHECK	d0,$00FF0000,3          ; HAM entry 1 is still red (not the read's $FFFF)

;--- CIA-B TOD: writes elsewhere in the CIA around the ticks ---------------------
	move.b	#$00,CIAB+$F00          ; CRB: TOD writes, timer B stopped
	moveq	#49,d7                  ; 50 rounds
.tr:	move.b	#$00,CIAB+$A00          ; TOD hi: stop
	move.b	#$0F,CIAB+$900
	move.b	#$FF,CIAB+$800          ; lo: $000FFF, counting (lines)
	move.w	#199,d1
.tw:	move.b	d1,CIAB+$400            ; timer A latch, in every cycle around the ticks
	dbra	d1,.tw
	moveq	#0,d0
	move.b	CIAB+$A00,d0            ; hi (latches)
	lsl.l	#8,d0
	move.b	CIAB+$900,d0
	lsl.l	#8,d0
	move.b	CIAB+$800,d0            ; lo (releases)
	move.l	d0,d1
	and.l	#$FFFF00,d1
	cmp.l	#$001000,d1             ; a few lines past $000FFF: $0010xx
	beq.s	.tok
	PUTHEX	d0
	TFAIL	10
.tok:	dbra	d7,.tr

;--- CIA-A ICR: a pending interrupt outlives its mask ---------------------------
	move.b	#$7F,CIAA+$D00          ; ICR: all masks off
	move.b	CIAA+$D00,d0            ; clear what is pending
	move.b	#$00,CIAA+$E00          ; CRA: stopped
	move.b	#$10,CIAA+$400          ; timer A latch: 16
	move.b	#$00,CIAA+$500
	move.b	#$81,CIAA+$D00          ; mask: timer A
	move.b	#$19,CIAA+$E00          ; CRA: load, one-shot, start
	move.w	#199,d1
.iw:	tst.b	CIAA+$100               ; (E-clock cycles: well past 16)
	dbra	d1,.iw
	move.b	#$01,CIAA+$D00          ; mask: timer A off
	moveq	#0,d0
	move.b	CIAA+$D00,d0            ; IR and TA
	TCHECK	d0,$81,20
	moveq	#0,d0
	move.b	CIAA+$D00,d0            ; read: cleared
	TCHECK	d0,$00,21

;--- CIA-A TOD: the read latch with CRB7 set -----------------------------------
	move.b	#$00,CIAA+$F00          ; CRB7 = 0: TOD writes
	move.b	#$00,CIAA+$A00
	move.b	#$01,CIAA+$900
	move.b	#$23,CIAA+$800          ; $000123, counting (frames)
	move.b	#$80,CIAA+$F00          ; CRB7 = 1: ALARM writes; reads are TOD
	move.b	CIAA+$A00,d0            ; hi: latches
	moveq	#2,d2                   ; three frames go by
.vw:	move.w	#$0020,$9C(a1)
.vw2:	btst	#5,$1F(a1)
	beq.s	.vw2
	dbra	d2,.vw
	moveq	#0,d0
	move.b	CIAA+$900,d0
	lsl.w	#8,d0
	move.b	CIAA+$800,d0            ; lo: the latched count, not three frames on
	cmp.w	#$0123,d0
	beq.s	.lok
	cmp.w	#$0124,d0               ; (a tick between the write and the latch)
	beq.s	.lok
	PUTHEX	d0
	TFAIL	30
.lok:	move.b	#$00,CIAA+$F00

;--- CIA-A port B: the output register ------------------------------------------
	move.b	#$FF,CIAA+$300          ; DDRB: all outputs
	move.b	#$5A,CIAA+$100          ; PRB
	moveq	#0,d0
	move.b	CIAA+$100,d0
	TCHECK	d0,$5A,40
	move.b	#$00,CIAA+$300

	TPRINT	msg_pass
	TPASS	0

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

msg_start:	dc.b	"t_chipset: start",10,0
msg_pass:	dc.b	"t_chipset: all checks passed",10,0
	even
