; t_ddrraw: a load after a store to the same address, through the memory
; paths of the real board.  cputest on Maximig returned from flushcache
; (CPUSHA BC, then RTS) to the return slot's OLD contents, and ramlib's RTS
; popped a stale long too: a load reading what memory held before a store
; that the CPU had already issued.  The CPU bench passes the same sequences
; (audit_cpusha_raw), so this runs them on the real memory: Zorro III RAM
; (DDR3) and motherboard RAM (SDRAM), with the caches off (the bus alone),
; in write-through and in copyback mode.
;
; Runs from the ROM socket (select it as the Kickstart ROM), autoconfigures
; the boards, and loops forever.  The screen is COLOR00: yellow while
; configuring, green while every check has passed, red once one failed.
; Counters go to the HPS share window at $DD4100 (DDR3 0x27FF4100 on the
; ARM; each long word byte-reversed there):
;   +00  'RAW1'            +04  passes       +08  flags: 1 Z3 RAM, 2 mb RAM
;   +10  36 counters: [region (0 Z3, 1 mb)][mode (0 off, 1 WT, 2 CB)][pattern 0-5]
;   +A0  the last failure: address, expected, read; +AC  99 at an exception
;   +0C  the pattern running; +C0  a ring of the last 8 failures: pattern,
;        address, expected, read; +100 failures counted
; Patterns: 0 store/load, 1 store/CPUSHA DC/load, 2 PEA/CPUSHA DC/pop,
; 3 three word stores (a frame)/CPUSHA DC/long load, 4 sixteen stores/
; CPUSHA DC/sixteen loads, 5 CINVA DC/store/load (both miss: the bus alone).
; In the simulation (tb/system, --z3 5 --mbram 3) the mailbox reports after
; four passes: PASS 0 or FAIL 1.

	include	"hw.i"

SHARE	equ	$DD4100
CNT	equ	$3000                   ; the counters, in chip RAM
LASTF	equ	$30A0
FRING	equ	$30C0
NFAIL	equ	$3100
MBRAM	equ	$07000000

	ROMHEADER start

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA             ; OVL off
	lea	$2000.w,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	lea	CUSTOM,a1
	move.w	#$7FFF,$9A(a1)
	move.w	#$7FFF,$9C(a1)
	move.w	#$7FFF,$96(a1)          ; no DMA: the screen is COLOR00
	move.w	#$0FF0,$180(a1)         ; yellow: configuring
	lea	CNT,a5
	moveq	#127,d0
.clr:	clr.l	(a5)+
	dbra	d0,.clr
	lea	CNT,a5

	; autoconfig: Zorro III memory boards at $40000000 and $50000000, the
	; RTG board at $58000000, Zorro II boards at $E90000, $EA0000
	moveq	#0,d5                   ; the first Z3 memory board's base
	move.w	#$4000,d4
	moveq	#$E9-256,d6
.ac:	moveq	#0,d0
	move.b	$E80000,d0
	beq.s	.acdone
	cmp.b	#$A0,d0
	bne.s	.notmem
	move.w	d4,$E80044
	tst.l	d5
	bne.s	.z
	move.w	d4,d5
	swap	d5
	clr.w	d5                      ; d5 = base << 16 ... = $40000000
.z:	add.w	#$1000,d4
	bra.s	.ac
.notmem:
	cmp.b	#$80,d0
	bne.s	.z2
	move.w	#$5800,$E80044          ; the RTG board
	bra.s	.ac
.z2:	move.b	d6,$E80048
	addq.b	#1,d6
	bra.s	.ac
.acdone:
	; what memory is there (caches off)
	moveq	#0,d7
	tst.l	d5
	beq.s	.nz3
	move.l	d5,a0
	move.l	#$A5A55A5A,$100000(a0)
	move.l	#$5A5AA5A5,$100004(a0)
	cmp.l	#$A5A55A5A,$100000(a0)
	bne.s	.nz3
	cmp.l	#$5A5AA5A5,$100004(a0)
	bne.s	.nz3
	bset	#0,d7
.nz3:	move.l	#$A5A55A5A,MBRAM+$100000
	move.l	#$5A5AA5A5,MBRAM+$100004
	cmp.l	#$A5A55A5A,MBRAM+$100000
	bne.s	.nmb
	cmp.l	#$5A5AA5A5,MBRAM+$100004
	bne.s	.nmb
	bset	#1,d7
.nmb:	move.l	d7,8(a5)
	move.l	#$52415732,(a5)         ; 'RAW2'
	bsr	report

	; caches on; instructions cacheable everywhere, data by DTT0 per mode
	cinva	bc
	move.l	#$00FFC000,d0
	movec	d0,itt0
	moveq	#0,d0
	movec	d0,itt1
	movec	d0,dtt1
	movec	d0,tc
	move.l	#$80008000,d0
	movec	d0,cacr
	move.l	#$12345678,d6           ; the value: changes at every store
	move.w	#$00F0,CUSTOM+$180      ; green

pass:
	moveq	#0,d3                   ; mode: 0 caches off, 1 write-through, 2 copyback
.mode:
	cpusha	bc
	move.l	#$00FFC000,d0
	cmpi.l	#1,d3
	beq.s	.wt
	move.l	#$00FFC020,d0
	cmpi.l	#2,d3
	beq.s	.wt
	moveq	#0,d0
	movec	d0,cacr
	bra.s	.mset
.wt:	move.l	d0,d1
	move.l	#$80008000,d0
	movec	d0,cacr
	move.l	d1,d0
.mset:	movec	d0,dtt0
	moveq	#0,d2                   ; region
.region:
	btst	d2,d7
	beq	.nextregion
	move.l	d5,a0
	tst.l	d2
	beq.s	.r
	move.l	#MBRAM,a0
.r:	add.l	#$100000,a0             ; 1 MB in
	; the counter index: ((region*3 + mode)*6)*4
	move.l	d2,d4
	add.l	d4,d4
	add.l	d2,d4
	add.l	d3,d4
	mulu	#24,d4
	add.l	#16,d4
	lea	(a5,d4.l),a3            ; a3 -> this region/mode's 6 counters

	; pattern 0: store, load
	move.l	#0,12(a5)
	move.l	a0,a1
	move.w	#255,d1
.p0:	addq.l	#1,d6
	move.l	d6,(a1)
	move.l	(a1),d0
	cmp.l	d6,d0
	beq.s	.p0ok
	moveq	#0,d4
	bsr	fail
.p0ok:	addq.l	#6,a1
	dbra	d1,.p0

	; pattern 1: store, CPUSHA DC, load
	move.l	#1,12(a5)
	lea	$2000(a0),a1
	move.w	#255,d1
.p1:	addq.l	#1,d6
	move.l	d6,(a1)
	cpusha	dc
	move.l	(a1),d0
	cmp.l	d6,d0
	beq.s	.p1ok
	moveq	#1,d4
	bsr	fail
.p1ok:	addq.l	#6,a1
	dbra	d1,.p1

	; pattern 2: PEA, CPUSHA DC, pop (the stack in the region; the pop
	; compared, not returned through, so a stale slot cannot take over)
	move.l	#2,12(a5)
	move.l	sp,a4
	lea	$6000(a0),sp
	move.w	#255,d1
.p2:	addq.l	#1,d6
	move.l	d6,-(sp)
	cpusha	dc
	move.l	(sp)+,d0
	cmp.l	d6,d0
	beq.s	.p2ok
	move.l	sp,a1
	subq.l	#4,a1
	moveq	#2,d4
	bsr	fail
.p2ok:	lea	-6(sp),sp               ; down the lines, every alignment
	dbra	d1,.p2
	move.l	a4,sp

	; pattern 3: three word stores as an exception frame, CPUSHA DC, a
	; long load of the middle (the PC) -- at every alignment
	move.l	#3,12(a5)
	lea	$8000(a0),a1
	move.w	#255,d1
.p3:	addq.l	#1,d6
	move.w	#$0020,6(a1)            ; format/vector
	move.w	d6,4(a1)                ; PC low
	swap	d6
	move.w	d6,2(a1)                ; PC high
	swap	d6
	move.w	#$2000,(a1)             ; SR
	cpusha	dc
	move.l	2(a1),d0
	cmp.l	d6,d0
	beq.s	.p3ok
	moveq	#3,d4
	bsr	fail
.p3ok:	addq.l	#6,a1
	dbra	d1,.p3

	; pattern 4: sixteen stores (a MOVEM's), CPUSHA DC, sixteen loads
	move.l	#4,12(a5)
	lea	$A000(a0),a1
	move.w	#63,d1
.p4:	lea	64(a1),a2
	moveq	#15,d0
.p4w:	addq.l	#1,d6
	move.l	d6,-(a2)
	dbra	d0,.p4w
	cpusha	dc
	move.l	a1,a2
	move.l	d6,d4
	moveq	#15,d0
.p4r:	cmp.l	(a2)+,d4
	beq.s	.p4ok
	move.l	a2,a1                   ; (the address for the record)
	subq.l	#4,a1
	move.l	d4,d6
	moveq	#4,d4
	bsr	fail
	bra.s	.p4n
.p4ok:	subq.l	#1,d4
	dbra	d0,.p4r
.p4n:	lea	$A000(a0),a1
	move.w	d1,d0
	neg.w	d0
	add.w	#63,d0
	addq.w	#1,d0
	mulu	#70,d0
	add.l	d0,a1
	dbra	d1,.p4

	; pattern 5: CINVA DC, store, load: both miss, the bus alone
	move.l	#5,12(a5)
	lea	$E000(a0),a1
	move.w	#255,d1
.p5:	addq.l	#1,d6
	cinva	dc
	move.l	d6,(a1)
	move.l	(a1),d0
	cmp.l	d6,d0
	beq.s	.p5ok
	moveq	#5,d4
	bsr	fail
.p5ok:	addq.l	#6,a1
	dbra	d1,.p5

	bsr	report
.nextregion:
	addq.l	#1,d2
	cmpi.l	#2,d2
	bcs	.region
	addq.l	#1,d3
	cmpi.l	#3,d3
	bcs	.mode
	addq.l	#1,4(a5)
	bsr	report
	cmpi.l	#4,4(a5)
	bne	pass
	; the simulation's verdict (on the board this write floats)
	lea	16(a5),a2
	moveq	#35,d0
.sum:	tst.l	(a2)+
	bne.s	.bad
	dbra	d0,.sum
	move.l	#$600D0000,MBOX
	bra	pass
.bad:	move.l	#$BAD00001,MBOX
	bra	pass

; a failed check: pattern d4, address a1, expected d6, read d0
fail:
	movem.l	d1/a2,-(sp)
	move.l	d4,d1
	lsl.l	#2,d1
	addq.l	#1,(a3,d1.l)
	move.l	a1,LASTF
	move.l	d6,LASTF+4
	move.l	d0,LASTF+8
	move.l	NFAIL,d1
	and.l	#7,d1
	lsl.l	#4,d1
	lea	FRING,a2
	add.l	d1,a2
	move.l	d4,(a2)+
	move.l	a1,(a2)+
	move.l	d6,(a2)+
	move.l	d0,(a2)
	addq.l	#1,NFAIL
	move.w	#$0F00,CUSTOM+$180      ; red
	bsr	report
	movem.l	(sp)+,d1/a2
	rts

; the counters to the share window
report:
	movem.l	d0/a0/a1,-(sp)
	lea	CNT,a0
	lea	SHARE,a1
	moveq	#127,d0
.c:	move.l	(a0)+,(a1)+
	dbra	d0,.c
	movem.l	(sp)+,d0/a0/a1
	rts

unexpected:
	move.l	#99,CNT+$AC
	move.l	#$FF,CNT+$0C
	move.l	2(sp),CNT+$A0
	move.w	#$0F0F,CUSTOM+$180      ; magenta
	lea	CNT,a5
	bsr	report
.h:	bra.s	.h
