; maximig_ext: the Maximig extension ROM (Main: System > Ext.ROM).
;
; Main uploads it to $E00000; the core also shows it at $F00000, where
; Kickstart looks for a DiagROM at reset and for resident modules.
;
; * DiagROM ($1111 at $F00000): Kickstart's reset code jumps to $F00002
;   with the return address in A5, before exec starts.  On a full 68060
;   (PCR ID $0430) the FPU is switched off (PCR DFP): Kickstart 3.1 does not
;   know the 060 and its FPU probe crashes there; 68060.library switches it
;   back on.  On the 68040 the PCR access traps, the handler returns, and
;   nothing changes.  (After Henryk Richter's kick31_060 for the Z3660.)
; * A resident module (cold start, after expansion.library) adds ConfigDev
;   entries for two windows of the core that no board's autoconfig
;   describes, so MMULib maps them (its ClearMMU without EXPANSION keeps
;   boards) and MMU-Configuration needs no lines for them:
;     $00A00000 1 MB  the HRTmon cartridge (RAM, custom register mirror)
;     $00DD4000 8 KB  the HPS share window (SHARE:, MiSTer:)
;   They are added once (FindConfigDev first), so a warm reboot keeps one
;   of each, and only with an MMU: a 68040-class CPU in AttnFlags (Kickstart
;   3.1 also flags a 68060 so), and the 040/060 PFLUSHA executing rather
;   than taking the line-F trap (the EC040/EC060 have no MMU).  Without
;   one nothing maps these windows away, and the module does nothing.
;
;   vasmm68k_mot -quiet -Fbin -m68060 -no-opt -o maximig_ext.bin maximig_ext.s
;   (build.sh: padded to 512 KB, the size Main loads)

; exec, expansion
_LVOOpenLibrary   equ -552
_LVOCloseLibrary  equ -414
_LVOAllocConfigDev equ -48
_LVOAddConfigDev  equ -30
_LVOFindConfigDev equ -72
_LVOSupervisor    equ -30
AttnFlags         equ $128             ; ExecBase
AFB_68040         equ 3
RTC_MATCHWORD     equ $4AFC
RTF_COLDSTART     equ $01
; struct ConfigDev
cd_Flags          equ 14
cd_Rom            equ 16              ; struct ExpansionRom
er_Type           equ 0
er_Product        equ 1
er_Manufacturer   equ 4
cd_BoardAddr      equ 32
cd_BoardSize      equ 36
cd_SlotAddr       equ 40
cd_SlotSize       equ 42
ERT_ZORROII       equ $C0

MANUF             equ $139C           ; the core's boards (the Z3 RTG board is $30)
PROD_CART         equ $31
PROD_SHARE        equ $32

	org	$F00000

;------------------------------------------------------------------------------
; the DiagROM
;------------------------------------------------------------------------------
	dc.w	$1111
diag:
	or.w	#$0700,sr
	lea	$BFE001,a0
	move.b	#3,$200(a0)             ; CIA-A DDRA: OVL, LED outputs
	move.b	#2,(a0)                 ; OVL off: the vectors at $0 are RAM
	move.l	$10.w,a1                ; illegal instruction, line F: kept
	move.l	$2C.w,a2
	move.l	sp,a3
	lea	$400.w,sp               ; a stack in chip RAM (as exec's early one)
	lea	.out(pc),a0
	move.l	a0,$10.w
	move.l	a0,$2C.w
	movec	pcr,d0                  ; 68040 and earlier: a trap to .out
	swap	d0
	cmp.w	#$0430,d0               ; a full 68060 (the EC/LC have $0431)
	bne.s	.out
	moveq	#2,d0                   ; PCR DFP: the FPU off until 68060.library
	movec	d0,pcr
.out:	move.l	a3,sp                   ; (a trap's frame is dropped with it)
	move.l	a1,$10.w
	move.l	a2,$2C.w
	jmp	(a5)                    ; back to Kickstart

;------------------------------------------------------------------------------
; the resident module
;------------------------------------------------------------------------------
	cnop	0,4
romtag:
	dc.w	RTC_MATCHWORD
	dc.l	romtag
	dc.l	romtag_end
	dc.b	RTF_COLDSTART
	dc.b	1                       ; version
	dc.b	0                       ; NT_UNKNOWN
	dc.b	100                     ; after expansion.library (110), diag init (105)
	dc.l	rt_name
	dc.l	rt_id
	dc.l	init

init:
	movem.l	d2-d3/a2/a5/a6,-(sp)
	move.l	4.w,a6
	move.w	AttnFlags(a6),d0
	btst	#AFB_68040,d0           ; a 68040 or 68060 (MOVEC VBR, PFLUSHA)
	beq.s	.none
	lea	mmu_probe(pc),a5
	jsr	_LVOSupervisor(a6)      ; d0: 1 if the CPU has an MMU
	tst.l	d0
	beq.s	.none
	lea	expname(pc),a1
	moveq	#0,d0
	jsr	_LVOOpenLibrary(a6)
	tst.l	d0
	beq.s	.none
	move.l	d0,a6
	lea	boards(pc),a2
.next:	move.w	(a2)+,d2                ; product (0: the end)
	beq.s	.done
	move.l	(a2)+,d3                ; address
	move.l	(a2)+,d1                ; size
	move.b	(a2)+,d0                ; er_Type
	addq.l	#1,a2
	bsr.s	add_board
	bra.s	.next
.done:	move.l	a6,a1
	move.l	4.w,a6
	jsr	_LVOCloseLibrary(a6)
.none:	movem.l	(sp)+,d2-d3/a2/a5/a6
	moveq	#0,d0
	rts

; in supervisor mode (exec's Supervisor(), ends with RTE): d0 = 1 if PFLUSHA
; executes, 0 if it takes the line-F trap (no MMU)
mmu_probe:
	movem.l	a0-a2,-(sp)
	movec	vbr,a0
	move.l	$2C(a0),a1              ; line F: kept
	lea	.nommu(pc),a2
	move.l	a2,$2C(a0)
	move.l	sp,a2
	moveq	#1,d0
	pflusha                         ; (the MMU is still off: nothing to flush)
	bra.s	.done
.nommu:	move.l	a2,sp                   ; the trap's frame dropped
	moveq	#0,d0
.done:	move.l	a1,$2C(a0)
	movem.l	(sp)+,a0-a2
	rte

; d2 product, d3 address, d1 size, d0 er_Type; a6 expansion.library
add_board:
	movem.l	d0-d1/a0,-(sp)
	suba.l	a0,a0
	move.l	#MANUF,d0
	move.l	d2,d1
	jsr	_LVOFindConfigDev(a6)   ; already there (a warm reboot)?
	tst.l	d0
	bne.s	.have
	jsr	_LVOAllocConfigDev(a6)
	tst.l	d0
	beq.s	.have
	move.l	d0,a0
	move.l	4(sp),d1                ; the size
	move.b	3(sp),cd_Rom+er_Type(a0)
	move.b	d2,cd_Rom+er_Product(a0)
	move.w	#MANUF,cd_Rom+er_Manufacturer(a0)
	clr.b	cd_Flags(a0)            ; configured, no driver to bind
	move.l	d3,cd_BoardAddr(a0)
	move.l	d1,cd_BoardSize(a0)
	move.l	d3,d0
	swap	d0
	move.w	d0,cd_SlotAddr(a0)      ; in 64 KB units
	move.l	d1,d0
	add.l	#$FFFF,d0
	swap	d0
	move.w	d0,cd_SlotSize(a0)
	jsr	_LVOAddConfigDev(a6)
.have:	movem.l	(sp)+,d0-d1/a0
	rts

	cnop	0,2
boards:	; product, address, size, er_Type (Zorro II, size code), pad
	dc.w	PROD_CART
	dc.l	$00A00000,$00100000
	dc.b	ERT_ZORROII+5,0         ; 1 MB
	dc.w	PROD_SHARE
	dc.l	$00DD4000,$00002000
	dc.b	ERT_ZORROII+1,0         ; (64 KB, the smallest code)
	dc.w	0

rt_name:	dc.b	"maximig.extrom",0
rt_id:		dc.b	"maximig.extrom 1.0 (24.10.2026) MMU windows, 68060 boot",13,10,0
expname:	dc.b	"expansion.library",0
	cnop	0,4
romtag_end:
