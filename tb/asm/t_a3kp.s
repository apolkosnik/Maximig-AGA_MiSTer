; t_a3kp: the AA3000+'s motherboard as the CPU sees it (an a4k_machine built
; with A3000P; docs/AA3000.md):
;   1     the DMAC+'s WTC reads 0 (bit 2 fixed at zero: the new DMAC)
;   2-3   CONTR's bits read back
;   4     ACR rounds the address down to a word
;   5     ISTR with no DMA running: FE
;   6-8   ST_DMA sets DMAENA (CONTR bit 8) and clears FE, SP_DMA clears it
;   9     the registers again $100 up (the DMAC+ decodes A6-A2)
;   10    the DSP status at $DD005C after the reset: $FFFF000F (in reset,
;         both host interrupts masked, none pending)
;   11-12 the latch at $DD0080: out of reset, both host interrupts enabled
;         ($B3); the byte at $DD005F
;   13    DSP INT0 and INT1 asserted ($B0)
;   14    a long word write: its last byte (the 8-bit port's last cycle)
;   15    everything asserted ($00)
;   16    a read at $DD0080 is nobody's: Gary's timeout, all ones
;   17    the RESET instruction resets the latch
;   18-19 chip RAM at $01000000, both ways
;   20-21 the ROM at $03F80000
;   98    an unexpected exception

	include	"hw.i"

DMAC	equ	$00DD0000
CHIPBUF	equ	$00030000

	ROMHEADER start
	org	$F80400

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA             ; OVL off
	lea	$20000,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	moveq	#0,d0
	movec	d0,vbr
	movec	d0,cacr
	lea	CUSTOM,a6
	move.w	#$7FFF,$9A(a6)
	move.w	#$7FFF,$9C(a6)
	lea	DMAC,a5

	; 1 WTC
	move.l	$04(a5),d0
	TCHECK	d0,$00000000,1

	; 2-3 CONTR
	move.l	#$00000016,$08(a5)
	move.l	$08(a5),d0
	TCHECK	d0,$00000016,2
	move.l	#$00000006,$08(a5)
	move.l	$08(a5),d0
	TCHECK	d0,$00000006,3

	; 4 ACR
	move.l	#$00123457,$0C(a5)
	move.l	$0C(a5),d0
	TCHECK	d0,$00123456,4

	; 5 ISTR
	move.l	$1C(a5),d0
	TCHECK	d0,$00000001,5

	; 6-8 ST_DMA / SP_DMA
	move.l	d0,$10(a5)
	move.l	$08(a5),d0
	TCHECK	d0,$00000106,6
	move.l	$1C(a5),d0
	TCHECK	d0,$00000000,7
	move.l	d0,$3C(a5)
	move.l	$08(a5),d0
	TCHECK	d0,$00000006,8

	; 9 the mirror
	move.l	$108(a5),d0
	TCHECK	d0,$00000006,9

	; 10 the DSP status
	move.l	$5C(a5),d0
	TCHECK	d0,$FFFF000F,10

	; 11-12 out of reset, host interrupts enabled
	move.b	#$B3,$80(a5)
	move.l	$5C(a5),d0
	TCHECK	d0,$FFFF00BF,11
	moveq	#0,d0
	move.b	$5F(a5),d0
	TCHECK	d0,$000000BF,12

	; 13 DSP INT0/INT1
	move.b	#$B0,$80(a5)
	move.l	$5C(a5),d0
	TCHECK	d0,$FFFF00BC,13

	; 14 a long word: its last byte
	move.l	#$000000F3,$80(a5)
	move.l	$5C(a5),d0
	TCHECK	d0,$FFFF00BF,14

	; 15 everything asserted
	move.b	#$00,$80(a5)
	move.l	$5C(a5),d0
	TCHECK	d0,$FFFF000C,15

	; 16 a read with A7 set
	move.l	$80(a5),d0
	TCHECK	d0,$FFFFFFFF,16

	; 17 RESET
	move.b	#$B3,$80(a5)
	reset
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA             ; OVL off again
	move.l	$5C(a5),d0
	TCHECK	d0,$FFFF000F,17

	; 18-19 chip RAM at $01000000
	move.l	#$CAFEF00D,CHIPBUF
	move.l	$01000000+CHIPBUF,d0
	TCHECK	d0,$CAFEF00D,18
	move.l	#$12345678,$01000000+CHIPBUF+4
	move.l	CHIPBUF+4,d0
	TCHECK	d0,$12345678,19

	; 20-21 the ROM at $03F80000
	move.l	$03F80000,d0
	TCHECK	d0,$00002000,20
	move.l	$03F80004,d0
	TCHECK	d0,start,21

	TPASS	0

unexpected:
	move.l	2(sp),d0                ; the stacked PC
	PUTHEX	d0
	move.w	6(sp),d0                ; format/vector
	PUTHEX	d0
	TFAIL	98
