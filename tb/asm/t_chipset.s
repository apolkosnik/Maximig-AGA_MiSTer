; t_chipset: chip behaviour the board test does not reach, on the real
; machine (tb/system).
;
;  1-9    HAM6: an AGA palette read (BPLCON2 RDRAM) must not write the HAM
;         palette (entry 1 stays red); with the BPLCON4 XOR a modify takes its
;         value from the pixel before the XOR, and a set selects from the 16
;         entries of HAM6 (WinUAE decode_ham_pixel_aga_fast)
;         (bench: mark 5 reports the frame's dominant colour at $1F10)
;  10-19  CIA-B TOD: writes to another register of the CIA around the
;         ticks do not lose the count or the carry ($000FFF + 1 = $001000)
;  20-29  CIA-A ICR: an interrupt that has occurred stays pending (IR) when
;         its mask bit is cleared, until ICR is read
;  30-39  CIA-A TOD: with CRB7 (ALARM) set reading the high byte does not
;         latch (8520, WinUAE); a TOD write landing on the alarm value
;         raises the alarm interrupt
;  40-49  CIA-A port B: output bits read back from the output register
;  50-59  EHB: the half-brite bit is plane 6 before the BPLCON4 XOR
;  60-69  sprites (CPU-written, manual mode): EHB leaves their colours alone
;         (bank 2: entry 33); the fine position (SH1/SH0) moves a pixel
;         without narrowing it; a CPU write in 32-wide mode (FMODE $0004)
;         is both halves (the bench's sample counts)
;  70-79  sprite collisions at the hires and shres pixel rates, at every
;         fine position

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
	bsr	frame_colour
	TCHECK	d0,$00FF0000,3          ; HAM entry 1 is still red (not the read's $FFFF)

	; the XOR (BPLCON4 BPLAM $0F) and a modify: pixels $11 (planes 1, 5):
	; control 01 (blue) after the XOR, the value 1 from the pixel itself
	move.l	#PLANE1,$F0(a1)         ; plane 5: ones
	move.w	#$0F11,$10C(a1)
	bsr	frame_colour
	TCHECK	d0,$00000011,4          ; blue $11 (the XOR'd value would be $EE)
	move.l	#PLANEZ,$F0(a1)
	; the XOR ($40) and a set: pixels $01, $41 after the XOR: HAM6 sets from
	; entry 1 (red), not 65 (green)
	move.w	#$4C00,$106(a1)         ; BPLCON3: bank 2 (64-95)
	move.w	#$00F0,$182(a1)         ; COLOR65 green
	move.w	#$0C00,$106(a1)
	move.w	#$4011,$10C(a1)
	bsr	frame_colour
	TCHECK	d0,$00FF0000,5
	move.w	#$0011,$10C(a1)

	; EHB: 6 planes, no HAM, pixels $01, the XOR $20: entry 1 (red) at full
	; brightness, the half-brite bit being plane 6 as fetched (0)
	move.w	#$6200,$100(a1)
	move.w	#$2011,$10C(a1)
	bsr	frame_colour
	TCHECK	d0,$00FF0000,50         ; (a half-brite $770000 if taken after the XOR)
	move.w	#$0011,$10C(a1)
	move.w	#$0200,$100(a1)

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
	move.b	CIAA+$800,d0            ; lo: the live count, two or three ticks on
	cmp.w	#$0124,d0               ; (a latch would still read $0123 or $0124)
	bhi.s	.lok
	PUTHEX	d0
	TFAIL	30
.lok:	move.b	#$00,CIAA+$F00

	; a TOD write landing on the alarm: the alarm interrupt
	move.b	#$7F,CIAA+$D00          ; masks off
	move.b	#$80,CIAA+$F00          ; CRB7: ALARM writes
	move.b	#$00,CIAA+$A00
	move.b	#$00,CIAA+$900
	move.b	#$05,CIAA+$800          ; alarm $000005
	move.b	#$00,CIAA+$F00          ; TOD writes
	move.b	CIAA+$D00,d0            ; clear what is pending
	move.b	#$84,CIAA+$D00          ; mask: ALRM
	move.b	#$00,CIAA+$A00
	move.b	#$00,CIAA+$900
	move.b	#$05,CIAA+$800          ; TOD $000005: the alarm, by the write
	moveq	#0,d0
	move.b	CIAA+$D00,d0
	TCHECK	d0,$84,35
	move.b	#$7F,CIAA+$D00

;--- CIA-A port B: the output register ------------------------------------------
	move.b	#$FF,CIAA+$300          ; DDRB: all outputs
	move.b	#$5A,CIAA+$100          ; PRB
	moveq	#0,d0
	move.b	CIAA+$100,d0
	TCHECK	d0,$5A,40
	move.b	#$00,CIAA+$300

;--- sprites ------------------------------------------------------------------------
	; EHB, all colour 0; sprite 0 from bank 2 (ESPRM 2): its colour 1 is entry 33
	move.l	#PLANEZ,$E0(a1)
	move.w	#$2C00,$106(a1)         ; BPLCON3: bank 1 (32-63)
	move.w	#$0F00,$182(a1)         ; COLOR33 red
	move.w	#$0C00,$106(a1)
	move.w	#$00F0,$182(a1)         ; COLOR01 green
	move.w	#$0021,$10C(a1)         ; BPLCON4: ESPRM 2, OSPRM 1
	move.w	#$6200,$100(a1)         ; 6 planes: EHB
	move.w	#$2C48,$140(a1)         ; SPR0POS: H $90
	clr.w	$142(a1)                ; SPR0CTL
	clr.w	$146(a1)                ; SPR0DATB
	move.w	#$FFFF,$144(a1)         ; SPR0DATA: armed, colour 1
	bsr	frame_colour
	TCHECK	d0,$00FF0000,60         ; entry 33 (EHB truncated it to 1, halved: green)

	; one lores pixel at each fine position: the same width
	move.w	#$0011,$10C(a1)
	move.w	#$0F00,$1A2(a1)         ; COLOR17 red (sprite 0 colour 1, bank 1)
	move.w	#$1200,$100(a1)         ; 1 plane, zero
	moveq	#0,d5
.fp:	move.w	d5,d0
	lsl.w	#3,d0
	move.w	d0,$142(a1)             ; SPR0CTL: SH1/SH0
	clr.w	$146(a1)
	move.w	#$8000,$144(a1)         ; one pixel
	bsr	frame_colour
	TCHECK	d0,$00FF0000,61
	move.l	$1F16.w,d1              ; its samples
	tst.w	d5
	bne.s	.fcmp
	move.l	d1,d4                   ; position 0: the reference
	bra.s	.fnx
.fcmp:	cmp.l	d4,d1
	beq.s	.fnx
	PUTHEX	d5
	PUTHEX	d1
	PUTHEX	d4
	TFAIL	62
.fnx:	addq.w	#1,d5
	cmp.w	#4,d5
	bne.w	.fp

	; a CPU write in 32-wide mode: both halves, two pixels
	move.w	#$0004,$1FC(a1)         ; FMODE: 32-wide sprites
	clr.w	$142(a1)
	clr.w	$146(a1)
	move.w	#$8000,$144(a1)
	bsr	frame_colour
	clr.w	$1FC(a1)
	move.l	$1F16.w,d1
	move.l	d4,d2
	add.l	d2,d2                   ; twice the one pixel
	cmp.l	d2,d1
	beq.s	.w32
	PUTHEX	d1
	PUTHEX	d4
	TFAIL	64
.w32:

	; collisions: sprites 0 and 2, one pixel each, overlapping, hires then
	; shres, at each fine position: CLXDAT bit 9 (sprite 0 to sprite 2)
	clr.w	$098(a1)                ; CLXCON
	move.w	#$0C80,d6               ; BPLCON3: SPRES hires
	moveq	#70,d7                  ; the check's number
.cres:	move.w	d6,$106(a1)
	moveq	#0,d5
.cfp:	move.w	d5,d0
	lsl.w	#3,d0
	move.w	d0,$142(a1)
	move.w	d0,$152(a1)             ; SPR2CTL
	move.w	#$2C48,$150(a1)         ; SPR2POS: the same place
	clr.w	$146(a1)
	clr.w	$156(a1)
	move.w	#$8000,$144(a1)
	move.w	#$8000,$154(a1)
	move.w	$00E(a1),d0             ; CLXDAT: read clears
	move.w	#$8300,$96(a1)
	moveq	#1,d2                   ; two frames
.cv:	move.w	#$0020,$9C(a1)
.cv2:	btst	#5,$1F(a1)
	beq.s	.cv2
	dbra	d2,.cv
	move.w	#$0100,$96(a1)
	move.w	$00E(a1),d0
	btst	#9,d0
	bne.s	.cok
	PUTHEX	d6
	PUTHEX	d5
	move.l	d7,d0
	add.l	#$BAD00000,d0
	move.l	d0,MBOX
.cdead:	bra.s	.cdead
.cok:	addq.w	#1,d5
	cmp.w	#4,d5
	bne.w	.cfp
	addq.l	#1,d7
	cmp.w	#$0CC0,d6
	beq.s	.cdone
	move.w	#$0CC0,d6               ; SPRES shres
	bra.w	.cres
.cdone:	clr.w	$142(a1)                ; sprites off
	clr.w	$152(a1)
	move.w	#$0C00,$106(a1)

	TPRINT	msg_pass
	TPASS	0

; the bench's dominant colour of the next complete frame (bitplane DMA on
; for it), in d0 as $00RRGGBB; fails 2 without an answer
frame_colour:
	move.w	#$8300,$96(a1)          ; DMAEN | BPLEN
	clr.w	$1F14.w
	TMARK	5
	move.l	#400000,d1
.cw:	cmp.w	#$AA55,$1F14.w
	beq.s	.cgot
	subq.l	#1,d1
	bne.s	.cw
	TFAIL	2
.cgot:	move.w	#$0100,$96(a1)          ; BPLEN off
	moveq	#0,d0
	move.w	$1F10.w,d0
	swap	d0
	move.w	$1F12.w,d0
	rts

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
