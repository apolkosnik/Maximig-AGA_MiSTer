; t_board: the A4000 motherboard as the 68040 sees it, on the real machine
; (tb/system, default configuration: 16 MB motherboard RAM, no Zorro III
; RAM, the RTG, A2065 and Toccata boards fitted).
;
;  1-9    Gary: power-up values, read/write, mirrors, the long word's lanes
;  10-19  Ramsey: version, power-up control value, a write taking effect
;         only at the next refresh, mirrors
;  20-29  motherboard RAM: lanes, the top of the window, the banks distinct
;  30-39  chip RAM: 32-bit, byte and word lanes, a misaligned long word
;  40-49  custom registers: INTENA/INTENAR, Lisa's ID
;  50-59  CIA-A: timer A latch read back
;  60-79  AUTOCONFIG: the chain at $E80000, the RTG board configured and its
;         framebuffer and registers answering
;  80-89  A4000 IDE with no drive, the RP5C01
;  90-99  unanswered cycles (floating, Gary's DSACK timeout), CPU space
;         (bus error), an autovectored interrupt
;  100-109 chipset DMA: the copper started by COPJMP1, COPJMP2 and the start
;         of the frame (its MOVEs to INTREQ seen by the CPU), the blitter
;         (a copy, an inverting blit with an A modulo)
;  110-119 the RESET instruction: Paula and CIA-A reset, the overlay back
;  130-139 the HRTmon cartridge: the Help key's NMI (CIA-A, level 7) enters
;         at $A1000C with the VBR in motherboard RAM (bench: --cart, mark 4)
;  120-129 the HPS share window ($DD4000): a request flag Main recognises,
;         and Main's acknowledge read back (the bench plays Main at mark 3)

	include	"hw.i"

	ROMHEADER start

start:
	move.b	#3,CIAA_DDRA            ; OVL, LED: outputs
	move.b	#2,CIAA_PRA             ; OVL off: chip RAM at $000000
	lea	$2000.w,sp
	lea	$8.w,a0                 ; every vector: unexpected
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	TPRINT	msg_start

;--- Gary ------------------------------------------------------------------
	moveq	#0,d0
	move.b	$DE0000,d0              ; TIMEOUT 0
	TCHECK	d0,$7F,1
	move.b	$DE0001,d0              ; TOENB 0
	TCHECK	d0,$7F,2
	move.b	$DE0002,d0              ; COLDBOOT: a power-up
	TCHECK	d0,$FF,3
	move.b	#$80,$DE0100            ; TIMEOUT through the mirror at +$100
	move.b	$DE0000,d0
	TCHECK	d0,$FF,4
	move.b	#$00,$DE0300
	move.b	#$00,$DE7F02            ; COLDBOOT cleared through a far mirror
	move.b	$DE0002,d0
	TCHECK	d0,$7F,5
	move.l	$DE0000,d0              ; TIMEOUT, TOENB, COLDBOOT, Ramsey control
	TCHECK	d0,$7F7F7F28,6

;--- Ramsey ----------------------------------------------------------------
	moveq	#0,d0
	move.b	$DE0043,d0              ; version: Ramsey-07
	TCHECK	d0,$0F,10
	move.b	$DE0047,d0              ; ... mirrored
	TCHECK	d0,$0F,11
	move.b	$DE0143,d0
	TCHECK	d0,$0F,12
	move.b	$DE0003,d0              ; control: 1M x 4, refresh 238 clocks
	TCHECK	d0,$28,13
	move.b	#$2D,$DE0003            ; + page mode, wrap
	move.b	$DE0003,d0              ; not yet: until the next refresh
	TCHECK	d0,$28,14
	move.w	#2000,d1
.rw:	move.b	$DE0003,d0
	cmp.b	#$2D,d0
	beq.s	.rok
	dbra	d1,.rw
	TFAIL	15
.rok:	move.b	#$28,$DE0003            ; back to standard mode
	move.w	#2000,d1
.rw2:	move.b	$DE0003,d0
	cmp.b	#$28,d0
	beq.s	.rok2
	dbra	d1,.rw2
	TFAIL	16
.rok2:
	move.b	$DE0083,d0              ; lane 3 elsewhere: $FF
	TCHECK	d0,$FF,17

;--- motherboard RAM (16 MB: $07000000-$07FFFFFF) ----------------------------
	lea	$07000000,a0
	move.l	#$12345678,(a0)
	move.l	#$9ABCDEF0,4(a0)
	move.l	(a0),d0
	TCHECK	d0,$12345678,20
	move.l	4(a0),d0
	TCHECK	d0,$9ABCDEF0,21
	move.b	#$AA,1(a0)
	move.w	#$BEEF,2(a0)
	move.l	(a0),d0
	TCHECK	d0,$12AABEEF,22
	moveq	#0,d0
	move.b	3(a0),d0
	TCHECK	d0,$EF,23
	move.l	#$11111111,$07000000
	move.l	#$22222222,$07400000
	move.l	#$33333333,$07800000
	move.l	#$44444444,$07C00000
	move.l	#$55555555,$07FFFFFC
	move.l	$07000000,d0
	TCHECK	d0,$11111111,24
	move.l	$07400000,d0
	TCHECK	d0,$22222222,25
	move.l	$07800000,d0
	TCHECK	d0,$33333333,26
	move.l	$07C00000,d0
	TCHECK	d0,$44444444,27
	move.l	$07FFFFFC,d0
	TCHECK	d0,$55555555,28

;--- chip RAM -----------------------------------------------------------------
	lea	$00010000,a0
	move.l	#$CAFEBABE,(a0)
	move.l	(a0),d0
	TCHECK	d0,$CAFEBABE,30
	moveq	#0,d0
	move.w	2(a0),d0
	TCHECK	d0,$BABE,31
	move.b	#$11,(a0)
	move.b	#$22,3(a0)
	move.l	(a0),d0
	TCHECK	d0,$11FEBA22,32
	move.l	#$00000000,$10010
	move.l	#$00000000,$10014
	move.l	#$01020304,$10011       ; misaligned: the 68040 splits it
	move.l	$10010,d0
	TCHECK	d0,$00010203,33
	move.l	$10014,d0
	TCHECK	d0,$04000000,34
	move.l	#$A5A5A5A5,$001FFFFC    ; the top of 2 MB
	move.l	$001FFFFC,d0
	TCHECK	d0,$A5A5A5A5,35

;--- custom registers ---------------------------------------------------------
	lea	CUSTOM,a1
	move.w	#$7FFF,$9A(a1)          ; INTENA: all off
	move.w	#$C028,$9A(a1)          ; INTEN | VERTB | PORTS
	moveq	#0,d0
	move.w	$1C(a1),d0              ; INTENAR
	TCHECK	d0,$4028,40
	move.w	#$7FFF,$9A(a1)
	move.w	$1C(a1),d0
	TCHECK	d0,$0000,41
	move.w	$7C(a1),d0              ; DENISEID: Lisa
	and.l	#$FF,d0
	TCHECK	d0,$F8,42

;--- CIA-A --------------------------------------------------------------------
	move.b	#$00,$BFEE01            ; CRA: timer A stopped
	move.b	#$34,$BFE401            ; TALO
	move.b	#$12,$BFE501            ; TAHI (loads the counter when stopped)
	moveq	#0,d0
	move.b	$BFE501,d0
	lsl.w	#8,d0
	move.b	$BFE401,d0
	TCHECK	d0,$1234,50

;--- AUTOCONFIG -----------------------------------------------------------------
	; board 1: the RTG board (Zorro III, mfr $139C, product $30)
	moveq	#0,d0
	move.b	$E80000,d0              ; er_Type high: Zorro III, not memory
	TCHECK	d0,$80,60
	bsr	ac_mfr
	TCHECK	d0,$139C,61
	bsr	ac_prod
	TCHECK	d0,$30,62
	move.w	#$4000,$E80044          ; base $40000000
	; board 2: A2065 (Zorro II, Commodore $0202, product $70, 64 KB)
	moveq	#0,d0
	move.b	$E80000,d0
	TCHECK	d0,$C0,63
	move.b	$E80002,d0
	TCHECK	d0,$10,64               ; 64 KB
	bsr	ac_mfr
	TCHECK	d0,$0202,65
	bsr	ac_prod
	TCHECK	d0,$70,66
	move.b	#$E9,$E80048            ; base $E90000
	; board 3: Toccata (MacroSystem $4754, product $0C)
	bsr	ac_mfr
	TCHECK	d0,$4754,67
	bsr	ac_prod
	TCHECK	d0,$0C,68
	move.b	#$EA,$E80048            ; base $EA0000
	; the end of the chain
	moveq	#0,d0
	move.b	$E80000,d0
	TCHECK	d0,$00,69
	; the RTG board answers: framebuffer in DDR3, its registers
	move.l	#$DEADBEEF,$40000000
	move.l	#$01234567,$407FFFFC
	move.l	$40000000,d0
	TCHECK	d0,$DEADBEEF,70
	move.l	$407FFFFC,d0
	TCHECK	d0,$01234567,71
	move.b	#$55,$40000001
	move.l	$40000000,d0
	TCHECK	d0,$DE55BEEF,72
	moveq	#0,d0
	move.w	$4080010E,d0            ; rtg.v ID/version
	TCHECK	d0,$5001,73
	move.w	#$0280,$40800108        ; HSIZE
	move.w	$40800108,d0
	TCHECK	d0,$0280,74
	move.l	#$00010000,$40800100    ; ADDR: one long word, two registers
	move.l	$40800100,d0
	TCHECK	d0,$00010000,75

;--- A4000 IDE, RP5C01 -----------------------------------------------------------
	moveq	#0,d0
	move.b	$DD203E,d0              ; status, no drive: $7F (DD7 pulled down)
	TCHECK	d0,$7F,80
	move.b	$DD3020,d0              ; interrupt status: none
	TCHECK	d0,$00,81
	move.b	$DC0037,d0              ; RTC mode register D: timer on, bank 0
	and.b	#$0F,d0
	TCHECK	d0,$08,82
	move.b	#$0A,$DC0037            ; bank 2: battery RAM, low nibbles
	move.b	#$05,$DC0003
	move.b	#$0B,$DC0037            ; bank 3: high nibbles
	move.b	#$0C,$DC0003
	move.b	#$0A,$DC0037
	move.b	$DC0003,d0
	and.b	#$0F,d0
	TCHECK	d0,$05,83
	move.b	#$0B,$DC0037
	move.b	$DC0003,d0
	and.b	#$0F,d0
	TCHECK	d0,$0C,84
	move.b	#$08,$DC0037            ; bank 0 again
	move.b	$DC0003,d0              ; seconds, ones: a BCD digit
	and.b	#$0F,d0
	cmp.b	#9,d0
	bls.s	.bcd
	TFAIL	85
.bcd:

;--- unanswered cycles, CPU space, interrupts -------------------------------------
	move.l	$00200000,d0            ; Zorro II memory space, empty: floats
	TCHECK	d0,$FFFFFFFF,90
	TMARK	1
	move.l	$00D00000,d0            ; Gary's DSACK timeout
	TMARK	2
	TCHECK	d0,$FFFFFFFF,91
	move.l	#berr,$8.w              ; access error
	clr.l	flag
	moveq	#7,d0
	movec	d0,sfc
	lea	$00001000,a0
	moves.l	(a0),d1                 ; CPU space: bus error
	TFAIL	92
after_berr:
	lea	$2000.w,sp
	tst.l	flag
	bne.s	.berr_ok
	TFAIL	93
.berr_ok:
	move.l	#vertb,$6C.w            ; level 3 autovector
	clr.l	flag
	move.w	#$7FFF,$9C(a1)          ; INTREQ: clear
	move.w	#$C020,$9A(a1)          ; INTEN | VERTB
	move.w	#$2000,sr               ; IPL 0
	move.l	#200000,d1
.wv:	tst.l	flag
	bne.s	.vok
	subq.l	#1,d1
	bne.s	.wv
	TFAIL	94
.vok:	move.w	#$2700,sr
	move.w	#$7FFF,$9A(a1)

;--- chipset DMA: the copper, the blitter -----------------------------------------
	move.w	#$7FFF,$96(a1)          ; DMACON: all DMA off
	lea	COPL1,a0                ; list 1: INTREQ = SET | COPER, end
	move.l	#$009C8010,(a0)+
	move.l	#$FFFFFFFE,(a0)
	lea	COPL2,a0                ; list 2: INTREQ = SET | SOFT, end
	move.l	#$009C8004,(a0)+
	move.l	#$FFFFFFFE,(a0)
	move.l	#COPL1,$80(a1)          ; COP1LC
	move.l	#COPL2,$84(a1)          ; COP2LC
	move.w	#$8280,$96(a1)          ; DMAEN | COPEN
	bsr	wait_vertb              ; a frame has just started: the next is 20 ms away
	move.w	#$7FFF,$9C(a1)
	move.w	d0,$88(a1)              ; COPJMP1: list 1
	move.w	#$0010,d2
	bsr	poll_intreq
	TCHECK	d0,$0010,100
	move.w	#$7FFF,$9C(a1)
	move.w	d0,$8A(a1)              ; COPJMP2: list 2
	move.w	#$0004,d2
	bsr	poll_intreq
	TCHECK	d0,$0004,101
	move.w	#$7FFF,$9C(a1)          ; the copper waits at the end of list 2
	bsr	wait_vertb              ; the start of the frame restarts it at list 1
	move.w	#$0010,d2
	bsr	poll_intreq
	TCHECK	d0,$0010,102
	move.w	#$0080,$96(a1)          ; COPEN off

	lea	BLTSRC,a0               ; 32 source words, 32 cleared destination words
	lea	BLTDST,a2
	move.l	#$0F1E2D3C,d0
	moveq	#15,d1
.fill:	move.l	d0,(a0)+
	clr.l	(a2)+
	add.l	#$01010101,d0
	dbra	d1,.fill
	move.w	#$8240,$96(a1)          ; DMAEN | BLTEN
	move.l	#$FFFFFFFF,$44(a1)      ; BLTAFWM, BLTALWM
	move.w	#$09F0,$40(a1)          ; BLTCON0: A and D, D = A
	clr.w	$42(a1)                 ; BLTCON1
	move.l	#BLTSRC,$50(a1)         ; BLTAPT
	move.l	#BLTDST,$54(a1)         ; BLTDPT
	clr.w	$64(a1)                 ; BLTAMOD
	clr.w	$66(a1)                 ; BLTDMOD
	move.w	#(1<<6)|16,$58(a1)      ; BLTSIZE: one row of 16 words
	bsr	wait_blit
	lea	BLTSRC,a2
	lea	BLTDST,a3
	moveq	#15,d1
.cpy:	move.w	(a2)+,d0
	cmp.w	(a3)+,d0
	beq.s	.cpyn
	move.l	a3,d0
	PUTHEX	d0
	TFAIL	103
.cpyn:	dbra	d1,.cpy
	tst.w	(a3)                    ; the word after the blit: untouched
	beq.s	.cpye
	TFAIL	104
.cpye:	move.w	#$090F,$40(a1)          ; BLTCON0: D = ~A
	move.l	#BLTSRC,$50(a1)
	move.l	#BLTDST+$40,$54(a1)
	move.w	#8,$64(a1)              ; BLTAMOD: the source rows are 8 words
	move.w	#(2<<6)|4,$58(a1)       ; two rows of 4 words
	bsr	wait_blit
	lea	BLTSRC,a2
	lea	BLTDST+$40,a3
	moveq	#1,d3
.row:	moveq	#3,d1
.inv:	move.w	(a2)+,d0
	not.w	d0
	cmp.w	(a3)+,d0
	beq.s	.invn
	move.l	a3,d0
	PUTHEX	d0
	TFAIL	105
.invn:	dbra	d1,.inv
	addq.l	#8,a2                   ; the A modulo
	dbra	d3,.row
	move.w	#$7FFF,$96(a1)

;--- the RESET instruction: RSTO resets the chipset and the CIAs ------------------
	move.l	#$12345678,$0.w         ; chip RAM at 0 (OVL is off)
	move.w	#$C020,$9A(a1)          ; INTENA: INTEN | VERTB
	reset
	moveq	#0,d0
	move.w	$1C(a1),d0              ; INTENAR: Paula was reset
	TCHECK	d0,$0000,110
	move.l	$0.w,d0                 ; OVL set again: the ROM's first long word
	TCHECK	d0,$00002000,111
	move.b	#3,CIAA_DDRA            ; CIA-A was reset too: its outputs again
	move.b	#2,CIAA_PRA             ; OVL off
	move.l	$0.w,d0                 ; chip RAM back, its contents kept
	TCHECK	d0,$12345678,112

;--- the HPS share window: the request flag as Main's minimig_share.cpp sees it ---
	move.l	#$5104A55A,$DD4000      ; a request, as L:MiSTerFileSystem raises one
	move.l	$DD4000,d0              ; (the read follows the posted write)
	TCHECK	d0,$5104A55A,120
	TMARK	3                       ; the bench: Main takes it and acknowledges
	move.l	$DD4000,d0              ; the acknowledge: the id in the low word
	TCHECK	d0,$51045104,121
	moveq	#0,d0
	move.w	$DD4002,d0
	TCHECK	d0,$5104,122
	moveq	#0,d0
	move.b	$DD4003,d0
	TCHECK	d0,$04,123

;--- the HRTmon cartridge: the key's NMI enters at $A1000C, VBR in fast RAM -------
	lea	VBR2,a0                 ; a VBR in motherboard RAM (as MuFastZero)
	move.w	#255,d0
.vb:	move.l	#unexpected,(a0)+
	dbra	d0,.vb
	move.l	#nmi_own,VBR2+$7C       ; the table's own NMI vector: must not be taken
	lea	VBR2,a0
	movec	a0,vbr
	clr.l	$1F04.w
	clr.l	$1F08.w
	move.w	#$0ABC,$180(a1)         ; COLOR00, for the custom register mirror
	; Keep the chip bus busy while the cartridge is fetched.  A running
	; display does not stop DMA just because F11 raises level 7.
	move.l	#$01820000,COPL1        ; COLOR01 = 0
	move.l	#$00880000,COPL1+4      ; COPJMP1: repeat without a WAIT
	move.l	#COPL1,$80(a1)
	move.w	#$8280,$96(a1)          ; DMAEN | COPEN
	move.w	d0,$88(a1)
	move.w	#$0100,$40(a1)          ; D-only blit, fill with zero
	clr.w	$42(a1)
	clr.w	$66(a1)
	move.l	#$80000,$54(a1)
	move.w	#$8040,$96(a1)          ; BLTEN, normal CPU arbitration
	clr.w	$58(a1)                 ; 1024 rows of 64 words
	TMARK	4                       ; the bench presses the HRTmon key
	move.l	#400000,d1
.nw:	tst.l	$1F04.w
	bne.s	.nmi
	subq.l	#1,d1
	bne.s	.nw
	TFAIL	130
.nmi:	move.l	$1F04.w,d0              ; the stub at $A1000C ran
	TCHECK	d0,$C0DEF00D,131
	moveq	#0,d0
	move.w	$1F08.w,d0              ; it read the mirror at $A9F180
	TCHECK	d0,$0ABC,132
	moveq	#0,d0
	move.w	$1F0A.w,d0              ; and the cartridge RAM
	TCHECK	d0,$5A5A,133
	move.w	#$7FFF,$96(a1)
	moveq	#0,d0
	movec	d0,vbr

	TPRINT	msg_pass
	TPASS	0

;------------------------------------------------------------------------------
; AUTOCONFIG helpers: the current board's manufacturer (registers $10-$16)
; and product ($04-$06), both stored inverted
ac_mfr:
	moveq	#0,d0
	moveq	#3,d2
	lea	$E80010,a2
.m:	lsl.w	#4,d0
	move.b	(a2),d1
	lsr.b	#4,d1
	or.b	d1,d0
	addq.l	#2,a2
	dbra	d2,.m
	not.w	d0
	and.l	#$FFFF,d0
	rts
ac_prod:
	moveq	#0,d0
	move.b	$E80004,d0
	and.b	#$F0,d0
	move.b	$E80006,d1
	lsr.b	#4,d1
	or.b	d1,d0
	not.b	d0
	and.l	#$FF,d0
	rts

print_str:
	moveq	#0,d0
.p:	move.b	(a0)+,d0
	beq.s	.e
	PUTC	d0
	bra.s	.p
.e:	rts

unexpected:
	move.l	2(sp),d0                ; the stacked PC
	PUTHEX	d0
	move.w	6(sp),d0                ; format/vector
	PUTHEX	d0
	TFAIL	255

nmi_own:
	TFAIL	134

berr:
	move.l	#1,flag
	jmp	after_berr

vertb:
	move.w	#$0020,CUSTOM+$9C       ; acknowledge VERTB
	move.l	#1,flag
	rte

; wait for the next start of frame (INTREQR VERTB), ~100 ms at most
wait_vertb:
	move.w	#$0020,$9C(a1)
	move.l	#100000,d1
.w:	btst	#5,$1F(a1)
	bne.s	.e
	subq.l	#1,d1
	bne.s	.w
	TFAIL	108
.e:	rts

; d0 = INTREQR & d2 once a bit of the mask is set, or 0 after ~200 us
poll_intreq:
	move.w	#199,d1
.p:	moveq	#0,d0
	move.w	$1E(a1),d0
	and.w	d2,d0
	bne.s	.e
	dbra	d1,.p
.e:	rts

; wait for the blitter (DMACONR BBUSY; the first read only lets Agnus set it)
wait_blit:
	tst.w	$02(a1)
	move.l	#100000,d1
.b:	btst	#6,$02(a1)
	beq.s	.e
	subq.l	#1,d1
	bne.s	.b
	TFAIL	109
.e:	rts

msg_start:	dc.b	"t_board: start",10,0
msg_pass:	dc.b	"t_board: all checks passed",10,0
	even

flag	equ	$00001F00
COPL1	equ	$00003000
COPL2	equ	$00003040
BLTSRC	equ	$00003100
BLTDST	equ	$00003200
VBR2	equ	$07F00000
