; Reproduce HRTmon entry with an MMU-translated vector table.
;
;   tb/asm/build.sh t_hrtmon_mmu hrtmon_stub
;   tb/system/obj_tests/Vtb_top --rom tb/asm/build/t_hrtmon_mmu.rom \
;       --cart tb/asm/build/hrtmon_stub.bin --ms 200 --quiet --lbtrace
;
; VBR is logical $10000000, backed by motherboard RAM at $07F00000.
; All other accesses are transparent.  F11 must override the translated
; level-7 vector at $07F0007C, enter the cartridge and return.
;
; This failed (134 / $BAD00086) while a4k_lbus matched the physical bus
; address against the logical VBR+$7C; it now takes the first supervisor
; data read after the level-7 acknowledge.  Part of tb/system/run_tests.sh.
;
; 129 translation setup failed, 130 no entry, 131 cartridge result wrong,
; 134 original NMI handler taken, 255 unexpected exception.

	include "hw.i"

VECTORS equ $07F00000
ROOT    equ $07F01000
PTR     equ $07F01200
PAGES   equ $07F01400

	ROMHEADER start

start:
	move.b #3,CIAA_DDRA
	move.b #2,CIAA_PRA
	lea $2000.w,sp
	lea VECTORS,a0
	lea $0.w,a1
	move.w #255,d0
.vec:	move.l #unexpected,(a0)+
	move.l #unexpected,(a1)+
	dbra d0,.vec
	move.l #original_nmi,VECTORS+$7C
	clr.l $1F04.w
	move.w #$0ABC,CUSTOM+$180

	; LA $10000000 -> PA $07F00000 (4 KB page).
	move.l #PTR+3,ROOT+$20
	move.l #PAGES+3,PTR
	move.l #VECTORS+3,PAGES
	move.l #ROOT,d0
	movec d0,srp
	move.l #$000FC000,d0     ; data $00000000-$0FFFFFFF: transparent
	movec d0,dtt0
	move.l #$00FFC000,d0     ; all instructions: transparent
	movec d0,itt0
	pflusha
	move.l #$8000,d0
	movec d0,tc
	move.l #$10000000,a0
	movec a0,vbr
	move.l $7C(a0),d0
	TCHECK d0,original_nmi,129

	TMARK 4
	move.l #50000,d1
.wait:	tst.l $1F04.w
	bne.s .entered
	subq.l #1,d1
	bne.s .wait
	TFAIL 130
.entered:
	move.l $1F04.w,d0
	TCHECK d0,$C0DEF00D,131
	TPASS 0

original_nmi:
	TFAIL 134
unexpected:
	TFAIL 255
