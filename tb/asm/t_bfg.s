; t_bfg: the BFG9060 card (sim_main --bfg; a4k_bfg9060), as the 68040 sees
; it on the real machine:
;   1-2   the firmware ID: $FF040008 reads $BF690601, $FF040000 all ones
;   3-6   the flash at $F00000: the boot code's DiagROM word $1111, a long
;         word, a byte, erased flash past the image ($FF), its ROMtag's name
;   7-12  the card's RAM at $08000000-$0FFFFFFF: long, word and byte lanes,
;         the top long word, 64 MB apart not aliased, $07FFFFFC and
;         $10000000 not the card's
;   13-14 cached: a copyback line written and pushed (CPUSHA), read back past
;         the cache; a line read through the cache
;   15-16 MOVE16 chip RAM -> card RAM and card RAM -> card RAM
;   17    a level-2 interrupt (CIA-A timer A), autovectored by the card
;   18    TCI: chip RAM's data is not cached on the BFG9060 -- a word read
;         through the data cache, cleared by the blitter, reads back cleared
;   19    marks 21-24: timing (uncached long reads and writes of card RAM,
;         and the same for chip RAM), printed by the bench
;   98    an unexpected exception

	include	"hw.i"

BFGRAM	equ	$08000000
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
	movec	d0,dtt0
	movec	d0,dtt1
	movec	d0,itt0
	movec	d0,itt1
	lea	CUSTOM,a6
	move.w	#$7FFF,$9A(a6)
	move.w	#$7FFF,$9C(a6)
	move.w	#$7FFF,$96(a6)

	; 1-2 the firmware ID
	move.l	$FF040008,d0
	TCHECK	d0,$BF690601,1
	move.l	$FF040000,d0
	TCHECK	d0,$FFFFFFFF,2

	; 3-6 the flash
	moveq	#0,d0
	move.w	$F00000,d0
	TCHECK	d0,$00001111,3
	move.l	$F00000,d0
	TCHECK	d0,$1111007C,4
	moveq	#0,d0
	move.b	$F00002,d0
	TCHECK	d0,$00000000,5
	move.l	$F40000,d0
	TCHECK	d0,$FFFFFFFF,6
	; (the name "BFG9060" of its expansion ROMtag)
	lea	$F00000,a0
	move.w	#$1F0/2-1,d1
.nm:	cmp.l	#'BFG9',(a0)
	beq.s	.nmok
	addq.l	#2,a0
	dbra	d1,.nm
	moveq	#0,d0
	TCHECK	d0,1,6
.nmok:	cmp.l	#'060'<<8,4(a0)
	beq.s	.ram
	move.l	4(a0),d0
	TCHECK	d0,0,6

	; 7-12 the card's RAM
.ram:	lea	BFGRAM,a0
	move.l	#$11223344,(a0)
	move.l	#$55667788,4(a0)
	move.l	(a0),d0
	TCHECK	d0,$11223344,7
	move.w	#$AABB,2(a0)
	move.b	#$CC,(a0)
	move.b	#$DD,5(a0)
	move.l	(a0),d0
	TCHECK	d0,$CC22AABB,8
	move.l	4(a0),d0
	TCHECK	d0,$55DD7788,8
	moveq	#0,d0
	move.w	6(a0),d0
	TCHECK	d0,$00007788,8
	lea	$0FFFFFFC,a1
	move.l	#$CAFEF00D,(a1)
	move.l	(a1),d0
	TCHECK	d0,$CAFEF00D,9
	lea	$0C000000,a1
	move.l	#$0C0C0C0C,(a1)
	move.l	#$08080808,(a0)
	move.l	(a1),d0
	TCHECK	d0,$0C0C0C0C,10
	move.l	(a0),d0
	TCHECK	d0,$08080808,10
	; motherboard RAM ($07xxxxxx, 16 MB fitted) is not the card's
	move.l	#$07070707,$07FFFFFC
	move.l	$07FFFFFC,d0
	TCHECK	d0,$07070707,11
	move.l	(a1),d0
	TCHECK	d0,$0C0C0C0C,11
	; $10000000 (nothing configured): Gary's timeout, not the card
	move.l	$10000000,d0
	TCHECK	d0,$FFFFFFFF,12
	move.l	(a0),d0
	TCHECK	d0,$08080808,12

	; 13 a copyback line, pushed: data cache on, the card's RAM copyback
	; through DTT0 ($08000000-$0FFFFFFF, both modes)
	move.l	#$0807C020,d0
	movec	d0,dtt0
	cinva	bc
	move.l	#$80000000,d0
	movec	d0,cacr
	lea	BFGRAM+$100,a0
	move.l	#$A0A0A0A0,(a0)
	move.l	#$A1A1A1A1,4(a0)
	move.l	#$A2A2A2A2,8(a0)
	move.l	#$A3A3A3A3,12(a0)
	cpusha	dc
	moveq	#0,d0
	movec	d0,cacr
	move.l	(a0),d0
	TCHECK	d0,$A0A0A0A0,13
	move.l	12(a0),d0
	TCHECK	d0,$A3A3A3A3,13
	; 14 a line read through the cache (a burst), then each long word
	lea	BFGRAM+$200,a0
	move.l	#$B0B0B0B0,(a0)
	move.l	#$B1B1B1B1,4(a0)
	move.l	#$B2B2B2B2,8(a0)
	move.l	#$B3B3B3B3,12(a0)
	cinva	dc
	move.l	#$80000000,d0
	movec	d0,cacr
	move.l	8(a0),d0                ; the line, critical long word first
	TCHECK	d0,$B2B2B2B2,14
	move.l	(a0),d0
	TCHECK	d0,$B0B0B0B0,14
	move.l	4(a0),d0
	TCHECK	d0,$B1B1B1B1,14
	move.l	12(a0),d0
	TCHECK	d0,$B3B3B3B3,14
	moveq	#0,d0
	movec	d0,cacr
	movec	d0,dtt0

	; 15-16 MOVE16
	lea	CHIPBUF,a0
	moveq	#7,d1
	move.l	#$12340000,d0
.fill:	move.l	d0,(a0)+
	addq.l	#1,d0
	dbra	d1,.fill
	lea	CHIPBUF,a0
	lea	BFGRAM+$400,a1
	move16	(a0)+,(a1)+
	move16	(a0)+,(a1)+
	lea	BFGRAM+$400,a1
	moveq	#7,d1
	move.l	#$12340000,d2
.c15:	move.l	(a1)+,d0
	cmp.l	d2,d0
	beq.s	.n15
	PUTHEX	d0
	TFAIL	15
.n15:	addq.l	#1,d2
	dbra	d1,.c15
	lea	BFGRAM+$400,a0
	lea	BFGRAM+$800,a1
	move16	(a0)+,(a1)+
	move16	(a0)+,(a1)+
	lea	BFGRAM+$800,a1
	moveq	#7,d1
	move.l	#$12340000,d2
.c16:	move.l	(a1)+,d0
	cmp.l	d2,d0
	beq.s	.n16
	PUTHEX	d0
	TFAIL	16
.n16:	addq.l	#1,d2
	dbra	d1,.c16

	; 17 a level-2 interrupt: CIA-A timer A, one shot
	move.l	#h_lev2,$68.w
	moveq	#0,d7
	move.b	#$7F,CIAA_PRA+$D00      ; ICR: all off
	tst.b	CIAA_PRA+$D00
	move.b	#20,CIAA_PRA+$400       ; TALO
	move.b	#0,CIAA_PRA+$500        ; TAHI
	move.b	#$19,CIAA_PRA+$E00      ; CRA: start, one shot, load
	move.b	#$81,CIAA_PRA+$D00      ; ICR: TA on
	move.w	#$C008,$9A(a6)          ; INTEN, PORTS
	move.w	#$2000,sr
	move.l	#20000,d1
.w17:	tst.l	d7
	bne.s	.ok17
	subq.l	#1,d1
	bne.s	.w17
	TFAIL	17
.ok17:	move.w	#$2700,sr
	move.w	#$0008,$9A(a6)

	; 18 TCI: chip RAM read through the data cache (MMU and TTs off: the
	; default mode is cacheable), cleared by the blitter, read again
	lea	CHIPBUF+$100,a0
	move.w	#$5A5A,(a0)
	cinva	dc
	move.l	#$80000000,d0
	movec	d0,cacr
	move.w	(a0),d0                 ; (on the A3640 this allocates the line)
	move.w	#$8240,$96(a6)          ; DMAEN, BLTEN
	move.l	a0,$54(a6)              ; BLTDPT
	move.w	#0,$66(a6)              ; BLTDMOD
	move.w	#$0100,$40(a6)          ; BLTCON0: D only, minterm 0
	move.w	#0,$42(a6)              ; BLTCON1
	move.w	#(1<<6)|1,$58(a6)       ; BLTSIZE: one line, one word
	tst.w	$02(a6)
.bw:	btst	#6,$02(a6)              ; DMACONR BBUSY
	bne.s	.bw
	moveq	#0,d0
	move.w	(a0),d0
	TCHECK	d0,$00000000,18
	moveq	#0,d0
	movec	d0,cacr
	move.w	#$0240,$96(a6)

	; 19 timing, the loops from the instruction cache: 256 uncached long
	; reads, then writes, of the card's RAM; 256 line fills; 256 chip RAM
	; reads (marks 21-27 give the times)
	cinva	bc
	move.l	#$00008000,d0
	movec	d0,cacr
	lea	BFGRAM,a0
	move.w	#255,d1
.tw:	move.l	(a0),d0                 ; (the loops into the cache)
	move.l	d0,(a0)
	dbra	d1,.tw
	TMARK	21
	move.w	#255,d1
.t1:	move.l	(a0),d0
	dbra	d1,.t1
	TMARK	22
	move.w	#255,d1
.t2:	move.l	d0,(a0)
	dbra	d1,.t2
	TMARK	23
	; (cached lines: 256 line fills, 16 bytes apart, copyback via DTT0)
	move.l	#$0807C020,d0
	movec	d0,dtt0
	cinva	dc
	move.l	#$80008000,d0
	movec	d0,cacr
	lea	BFGRAM+$10000,a0
	TMARK	24
	move.w	#255,d1
.t3:	move.l	(a0),d0
	lea	16(a0),a0
	dbra	d1,.t3
	TMARK	25
	move.l	#$00008000,d0
	movec	d0,cacr
	moveq	#0,d0
	movec	d0,dtt0
	lea	CHIPBUF,a0
	TMARK	26
	move.w	#255,d1
.t4:	move.l	(a0),d0
	dbra	d1,.t4
	TMARK	27
	moveq	#0,d0
	movec	d0,cacr

	TPASS	0

h_lev2:
	move.b	CIAA_PRA+$D00,d0        ; ICR: acknowledge
	move.w	#$0008,$9C(a6)
	moveq	#1,d7
	rte

unexpected:
	move.l	2(sp),d0                ; the stacked PC
	PUTHEX	d0
	move.w	6(sp),d0                ; format/vector
	PUTHEX	d0
	TFAIL	98
