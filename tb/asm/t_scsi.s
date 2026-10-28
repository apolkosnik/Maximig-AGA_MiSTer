; t_scsi: the AA3000+'s SCSI as its scsi.device drives it -- the WD33C93A
; (a3kp_sbic) in DMA mode behind the SuperDMAC (a3kp_dmac), the disks
; (a3kp_scsi_disk) on IDE channel 0 as Main serves it (sim_main --hdf, the
; image made by mkhdf.py: long word k of sector n is n<<16 | k)
;   1-2   the SBIC's Reset (Own ID 7): its interrupt, status $00
;   3-7   INQUIRY by Select-With-ATN-And-Transfer, DMA to chip RAM: status
;         $16, the target's status byte (Target LUN) $00, the command phase
;         $60, the disconnect ($85), the data (direct access, the vendor)
;   8-9   READ CAPACITY: the last block and 512-byte blocks
;   10-11 READ(10) of blocks 3-4 to chip RAM: their pattern
;   12-14 WRITE(10) of block 9 from chip RAM, READ(10) back to motherboard
;         RAM: the same data
;   15    READ(6) of block 7 to a word-aligned buffer (the DMAC+'s word first)
;   16-18 an INQUIRY whose transfer count exceeds the data: the unexpected
;         status phase ($4B), the count left (255 - 36), resumed at phase
;         $46: completed
;   19-20 TEST UNIT READY (no data): completed, good status
;   21-23 an unknown opcode: CHECK CONDITION; REQUEST SENSE: ILLEGAL REQUEST,
;         ASC $20 (18 bytes: FLUSH writes the last word)
;   24    a target that is not there: the selection timeout ($42)
;   25    the SCSI interrupt as the CPU's level 2 (INTENA, PORTS)
;   30-38 Level II, as Kickstart's scsi.device drives it (polled, DM 0):
;         Select-With-ATN completes ($11), the target's Message Out REQ is
;         its own service required interrupt ($8E); Transfer Info (SBT) of
;         the Identify -> $1A, of the six CDB bytes -> $1B, of the status
;         byte -> $1F, of the Command Complete message -> $20 (ACK held);
;         Negate ACK: the disconnect ($85)
;   26-29 the SBIC's words, as Kickstart's scsi.device uses them: a long
;         write at $48 selects, a long read at $40 is the aux status and the
;         data; a long write at $40 writes SASR alone; words $48 / $46; $44
;         reads $FFFF
;   96-97 a polled byte never offered (DBR)
;   98    an unexpected exception

	include	"hw.i"

DMAC	equ	$00DD0000
BUF0	equ	$00040000
BUF1	equ	$00041000
BUF2	equ	$00042000
BUF3	equ	$00043000
BUF5	equ	$00045002               ; word aligned, not long aligned
MBBUF	equ	$07F00000               ; motherboard RAM

; SBIC registers
S_OWNID	equ	$00
S_CTRL	equ	$01
S_TPER	equ	$02
S_CDB1	equ	$03
S_TLUN	equ	$0F
S_CPR	equ	$10
S_TCH	equ	$12
S_DEST	equ	$15
S_STAT	equ	$17
S_CMD	equ	$18
S_DATA	equ	$19

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
	move.l	#h_lev2,$68.w
	moveq	#0,d0
	movec	d0,vbr
	movec	d0,cacr
	lea	CUSTOM,a6
	move.w	#$7FFF,$9A(a6)
	move.w	#$7FFF,$9C(a6)
	lea	DMAC,a5

	; the power-up reset's interrupt
	moveq	#S_STAT,d0
	bsr	sbic_rd
	move.l	d0,$18(a5)              ; CLR_INT

	; 1-2 Reset with Own ID 7
	moveq	#S_OWNID,d0
	moveq	#7,d1
	bsr	sbic_wr
	moveq	#S_CMD,d0
	moveq	#0,d1
	bsr	sbic_wr
	bsr	wait_int
	TCHECK	d1,$00000000,1
	moveq	#S_OWNID,d0
	bsr	sbic_rd
	TCHECK	d1,$00000007,2
	moveq	#S_CTRL,d0
	move.b	#$80,d1                 ; DMA mode
	bsr	sbic_wr
	moveq	#S_TPER,d0
	moveq	#2,d1                   ; ~11 ms
	bsr	sbic_wr

	; 3-7 INQUIRY
	lea	cdb_inq,a0
	moveq	#36,d3
	lea	BUF0,a1
	moveq	#0,d4
	moveq	#0,d5
	bsr	scsi_cmd
	TCHECK	d1,$00000016,3
	moveq	#S_TLUN,d0
	bsr	sbic_rd
	TCHECK	d1,$00000000,4
	moveq	#S_CPR,d0
	bsr	sbic_rd
	TCHECK	d1,$00000060,5
	bsr	wait_int
	TCHECK	d1,$00000085,6
	bsr	dma_end
	move.l	BUF0,d0
	TCHECK	d0,$00000202,7
	move.l	BUF0+8,d0
	TCHECK	d0,'MiST',7

	; 8-9 READ CAPACITY
	lea	cdb_cap,a0
	moveq	#8,d3
	lea	BUF1,a1
	bsr	scsi_cmd0
	TCHECK	d1,$00000016,8
	bsr	wait_int
	bsr	dma_end
	move.l	BUF1,d0
	TCHECK	d0,8191,8
	move.l	BUF1+4,d0
	TCHECK	d0,512,9

	; 10-11 READ(10) blocks 3-4
	lea	cdb_rd10,a0
	move.l	#1024,d3
	lea	BUF2,a1
	bsr	scsi_cmd0
	TCHECK	d1,$00000016,10
	bsr	wait_int
	bsr	dma_end
	lea	BUF2,a0
	move.l	#$00030000,d2
	bsr	check_block
	TCHECK	d0,0,11
	lea	BUF2+512,a0
	move.l	#$00040000,d2
	bsr	check_block
	TCHECK	d0,0,11

	; 12-14 WRITE(10) block 9 from chip RAM, READ(10) back to motherboard RAM
	lea	BUF3,a0
	move.w	#127,d1
	move.l	#$A5000000,d0
.fill:	move.l	d0,(a0)+
	addq.l	#1,d0
	dbra	d1,.fill
	lea	cdb_wr10,a0
	move.l	#512,d3
	lea	BUF3,a1
	moveq	#1,d4
	moveq	#0,d5
	bsr	scsi_cmd
	TCHECK	d1,$00000016,12
	bsr	wait_int
	bsr	dma_end
	moveq	#S_TLUN,d0
	bsr	sbic_rd
	TCHECK	d1,$00000000,13
	lea	cdb_rd10b,a0
	move.l	#512,d3
	lea	MBBUF,a1
	bsr	scsi_cmd0
	bsr	wait_int
	bsr	dma_end
	lea	MBBUF,a0
	move.l	#$A5000000,d2
	bsr	check_block
	TCHECK	d0,0,14

	; 15 READ(6) block 7 to a word-aligned buffer
	lea	cdb_rd6,a0
	move.l	#512,d3
	lea	BUF5,a1
	bsr	scsi_cmd0
	bsr	wait_int
	bsr	dma_end
	lea	BUF5,a0
	move.l	#$00070000,d2
	bsr	check_block
	TCHECK	d0,0,15

	; 16-18 more transfer count than data: the unexpected status phase
	lea	cdb_inq,a0
	move.l	#255,d3
	lea	BUF0,a1
	bsr	scsi_cmd0
	TCHECK	d1,$0000004B,16
	moveq	#S_TCH+2,d0             ; the count left (low byte)
	bsr	sbic_rd
	TCHECK	d1,255-36,17
	moveq	#S_CPR,d0
	move.b	#$46,d1
	bsr	sbic_wr
	moveq	#S_CMD,d0
	moveq	#8,d1                   ; resume
	bsr	sbic_wr
	bsr	wait_int
	TCHECK	d1,$00000016,18
	bsr	wait_int
	bsr	dma_end

	; 19-20 TEST UNIT READY
	lea	cdb_tur,a0
	moveq	#0,d3
	lea	BUF0,a1
	bsr	scsi_cmd0
	TCHECK	d1,$00000016,19
	moveq	#S_TLUN,d0
	bsr	sbic_rd
	TCHECK	d1,$00000000,20
	bsr	wait_int
	bsr	dma_end

	; 21-23 an unknown opcode, REQUEST SENSE
	lea	cdb_bad,a0
	moveq	#0,d3
	lea	BUF0,a1
	bsr	scsi_cmd0
	bsr	wait_int
	bsr	dma_end
	moveq	#S_TLUN,d0
	bsr	sbic_rd
	TCHECK	d1,$00000002,21
	lea	BUF1,a0
	move.l	#$11111111,d0
	moveq	#7,d1
.clr:	move.l	d0,(a0)+
	dbra	d1,.clr
	lea	cdb_sense,a0
	moveq	#18,d3
	lea	BUF1,a1
	bsr	scsi_cmd0
	bsr	wait_int
	bsr	dma_end
	move.l	BUF1,d0
	TCHECK	d0,$70000500,22
	move.l	BUF1+12,d0                ; ASC, ASCQ and the last word (FLUSH)
	and.l	#$FFFF0000,d0
	TCHECK	d0,$20000000,23
	moveq	#0,d0
	move.w	BUF1+16,d0
	TCHECK	d0,$00000000,23

	; 24 no target 3
	lea	cdb_tur,a0
	moveq	#0,d3
	lea	BUF0,a1
	moveq	#0,d4
	moveq	#3,d5
	bsr	scsi_cmd
	TCHECK	d1,$00000042,24
	bsr	dma_end

	; 25 the interrupt as level 2 (CIA-A's own interrupts, also level 2,
	; masked and cleared first)
	moveq	#0,d7
	move.b	#$7F,CIAA_PRA+$D00      ; CIA-A ICR: all masked
	tst.b	CIAA_PRA+$D00           ; and what was pending cleared
	move.w	#$0008,$9C(a6)
	move.w	#$C008,$9A(a6)          ; INTEN | PORTS
	move.l	d0,$18(a5)              ; CLR_INT: check 24's interrupt is still recorded
	move.l	#$00000004,$08(a5)      ; CONTR: INTENA
	move	#$2000,sr
	lea	cdb_tur,a0
	moveq	#0,d3
	moveq	#S_DEST,d0
	moveq	#0,d1
	bsr	sbic_wr
	bsr	load_cdb
	moveq	#S_CMD,d0
	moveq	#8,d1
	bsr	sbic_wr
	move.l	#200000,d6
.w25:	tst.l	d7
	bne.s	.got25
	subq.l	#1,d6
	bne.s	.w25
.got25:	move	#$2700,sr
	TCHECK	d7,$00000016,25

	; 26-29 the long and word accesses
	move.l	#$00000000,$48(a5)      ; SASR: Own ID (the upper word)
	move.l	$40(a5),d1              ; aux status : Own ID
	and.l	#$FF00FFFF,d1
	TCHECK	d1,$00000007,26
	move.l	#S_OWNID,$40(a5)        ; SASR alone (no data write of 0)
	moveq	#0,d1
	move.b	$43(a5),d1
	TCHECK	d1,$00000007,27
	move.w	#S_OWNID,$48(a5)
	moveq	#0,d1
	move.w	$46(a5),d1
	TCHECK	d1,$00000007,28
	moveq	#0,d1
	move.w	$44(a5),d1
	TCHECK	d1,$0000FFFF,29

	; 30-38 Level II, polled
	moveq	#S_CTRL,d0
	moveq	#0,d1                   ; DM 0: the host moves the bytes
	bsr	sbic_wr
	move.l	d0,$3C(a5)              ; SP_DMA
	moveq	#S_DEST,d0
	moveq	#0,d1
	bsr	sbic_wr
	moveq	#S_CMD,d0
	moveq	#6,d1                   ; Select-With-ATN
	bsr	sbic_wr
	bsr	wait_int
	TCHECK	d1,$00000011,30
	bsr	wait_int
	TCHECK	d1,$0000008E,31
	moveq	#S_CMD,d0
	move.b	#$A0,d1                 ; Transfer Info, single byte
	bsr	sbic_wr
	move.b	#$80,d1                 ; Identify, LUN 0
	bsr	put_data
	bsr	wait_int
	TCHECK	d1,$0000001A,32
	moveq	#6,d1
	bsr	set_tc
	moveq	#S_CMD,d0
	moveq	#$20,d1                 ; Transfer Info, TC bytes
	bsr	sbic_wr
	moveq	#5,d2
.cdb:	moveq	#0,d1                   ; TEST UNIT READY
	bsr	put_data
	dbra	d2,.cdb
	bsr	wait_int
	TCHECK	d1,$0000001B,33
	moveq	#1,d1
	bsr	set_tc
	moveq	#S_CMD,d0
	moveq	#$20,d1
	bsr	sbic_wr
	bsr	get_data
	TCHECK	d1,$00000000,34         ; GOOD
	bsr	wait_int
	TCHECK	d1,$0000001F,35
	moveq	#1,d1
	bsr	set_tc
	moveq	#S_CMD,d0
	moveq	#$20,d1
	bsr	sbic_wr
	bsr	get_data
	TCHECK	d1,$00000000,36         ; COMMAND COMPLETE
	bsr	wait_int
	TCHECK	d1,$00000020,37
	moveq	#S_CMD,d0
	moveq	#3,d1                   ; Negate ACK
	bsr	sbic_wr
	bsr	wait_int
	TCHECK	d1,$00000085,38

	TPASS	0

; the level-2 handler, as an interrupt server: the DMAC's if ISTR's INT_P
; says so; the SBIC's status (the interrupt's cause), CLR_INT
h_lev2:
	movem.l	d0-d1,-(sp)
	btst	#4,$1F(a5)              ; ISTR INT_P
	beq.s	.notme
	moveq	#S_STAT,d0
	bsr	sbic_rd
	tst.l	d7                      ; (the first one: the completion, not the disconnect after it)
	bne.s	.seen
	move.l	d1,d7
.seen:	move.l	d0,$18(a5)
.notme:	move.w	#$0008,$9C(a6)
	movem.l	(sp)+,d0-d1
	rte

; the SBIC register d0 := d1 (byte)
sbic_wr:
	move.b	d0,$41(a5)
	move.b	d1,$43(a5)
	rts

; d1 := the SBIC register d0 (byte, zero-extended)
sbic_rd:
	move.b	d0,$41(a5)
	moveq	#0,d1
	move.b	$43(a5),d1
	rts

; the transfer count := d1
set_tc:
	movem.l	d0-d2,-(sp)
	move.l	d1,d2
	moveq	#S_TCH,d0
	swap	d1
	bsr	sbic_wr
	moveq	#S_TCH+1,d0
	move.l	d2,d1
	lsr.l	#8,d1
	bsr	sbic_wr
	moveq	#S_TCH+2,d0
	move.l	d2,d1
	bsr	sbic_wr
	movem.l	(sp)+,d0-d2
	rts

; the Data register := d1 once DBR asks for it (polled transfers)
put_data:
	move.l	#100000,d6
.p:	btst	#0,$41(a5)              ; DBR
	bne.s	.go
	subq.l	#1,d6
	bne.s	.p
	TFAIL	97
.go:	move.b	#S_DATA,$41(a5)
	move.b	d1,$43(a5)
	rts

; d1 := the Data register once DBR has a byte
get_data:
	move.l	#100000,d6
.g:	btst	#0,$41(a5)
	bne.s	.go
	subq.l	#1,d6
	bne.s	.g
	TFAIL	96
.go:	move.b	#S_DATA,$41(a5)
	moveq	#0,d1
	move.b	$43(a5),d1
	rts

; wait for the SBIC's interrupt; d1 := its status
wait_int:
	move.l	#400000,d6
.w:	btst	#7,$41(a5)
	bne.s	.got
	subq.l	#1,d6
	bne.s	.w
	moveq	#-1,d1
	rts
.got:	moveq	#S_STAT,d0
	bsr	sbic_rd
	rts

; the CDB at a0 (12 bytes) to the SBIC's CDB registers
load_cdb:
	movem.l	d0-d2/a0,-(sp)
	moveq	#S_CDB1,d0
	moveq	#11,d2
.l:	move.b	(a0)+,d1
	bsr	sbic_wr
	addq.b	#1,d0
	dbra	d2,.l
	movem.l	(sp)+,d0-d2/a0
	rts

; a SCSI command to target 0, data in: a0 the CDB, d3 the count, a1 the buffer
scsi_cmd0:
	moveq	#0,d4
	moveq	#0,d5
; a SCSI command: a0 the CDB, d3 the transfer count, a1 the buffer, d4 the
; direction (0 in, 1 out), d5 the target; d1 := the first interrupt's status
scsi_cmd:
	move.l	d0,$3C(a5)              ; SP_DMA
	move.l	d0,$18(a5)              ; CLR_INT
	move.l	d4,d0
	add.l	d0,d0                   ; DMADIR
	move.l	d0,$08(a5)
	move.l	a1,$0C(a5)              ; ACR
	move.l	d0,$10(a5)              ; ST_DMA
	moveq	#S_DEST,d0
	move.l	d5,d1
	bsr	sbic_wr
	moveq	#S_TLUN,d0
	moveq	#0,d1
	bsr	sbic_wr
	moveq	#S_CPR,d0
	moveq	#0,d1
	bsr	sbic_wr
	moveq	#S_TCH,d0
	move.l	d3,d1
	swap	d1
	bsr	sbic_wr
	moveq	#S_TCH+1,d0
	move.l	d3,d1
	lsr.l	#8,d1
	bsr	sbic_wr
	moveq	#S_TCH+2,d0
	move.l	d3,d1
	bsr	sbic_wr
	bsr	load_cdb
	moveq	#S_CMD,d0
	moveq	#8,d1                   ; Select-With-ATN-And-Transfer
	bsr	sbic_wr
	bra	wait_int

; the end of a transfer: FLUSH, wait for FE, SP_DMA
dma_end:
	move.l	d0,$14(a5)              ; FLUSH
	move.w	#1000,d6
.f:	btst	#0,$1F(a5)
	bne.s	.e
	dbra	d6,.f
.e:	move.l	d0,$3C(a5)              ; SP_DMA
	rts

; the 512 bytes at a0 against the pattern d2 + k (k = 0..127); d0 := 0 if equal
check_block:
	moveq	#127,d1
.c:	cmp.l	(a0)+,d2
	bne.s	.bad
	addq.l	#1,d2
	dbra	d1,.c
	moveq	#0,d0
	rts
.bad:	move.l	-4(a0),d0
	PUTHEX	d0
	PUTHEX	d2
	moveq	#1,d0
	rts

unexpected:
	move.l	2(sp),d0                ; the stacked PC
	PUTHEX	d0
	move.w	6(sp),d0                ; format/vector
	PUTHEX	d0
	TFAIL	98

	cnop	0,4
cdb_inq:	dc.b	$12,0,0,0,255,0,0,0,0,0,0,0
cdb_cap:	dc.b	$25,0,0,0,0,0,0,0,0,0,0,0
cdb_rd10:	dc.b	$28,0,0,0,0,3,0,0,2,0,0,0
cdb_wr10:	dc.b	$2A,0,0,0,0,9,0,0,1,0,0,0
cdb_rd10b:	dc.b	$28,0,0,0,0,9,0,0,1,0,0,0
cdb_rd6:	dc.b	$08,0,0,7,1,0,0,0,0,0,0,0
cdb_tur:	dc.b	$00,0,0,0,0,0,0,0,0,0,0,0
cdb_bad:	dc.b	$C7,0,0,0,0,0,0,0,0,0,0,0
cdb_sense:	dc.b	$03,0,0,0,18,0,0,0,0,0,0,0
