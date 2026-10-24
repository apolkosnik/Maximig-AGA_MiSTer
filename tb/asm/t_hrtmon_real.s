; t_hrtmon_real: the real hrtmon.rom entered from the Help key.
;
;   tb/asm/build.sh t_hrtmon_real
;   tb/system/obj_tests/Vtb_top --rom tb/asm/build/t_hrtmon_real.rom \
;       --cart HRTMON.ROM --cart-config --ms 300 --quiet
;
; Every exception vector reports the stacked PC and the format/vector word
; and fails 255: a trap inside HRTmon shows where.  Without one, HRTmon is
; in its monitor loop when the run ends (no result; --pctrace shows it).

	include	"hw.i"

	ROMHEADER start

start:
	move.b	#3,CIAA_DDRA
	move.b	#2,CIAA_PRA
	lea	$2000.w,sp
	lea	$8.w,a0
	move.w	#253,d0
.vec:	move.l	#unexpected,(a0)+
	dbra	d0,.vec
	; a minimal ExecBase with the 68040 AttnFlags, as Kickstart sets them on
	; this machine, and the caches on: HRTmon picks its CPU code from these
	lea	EXECB,a0
	move.w	#$7F,d0
.eb:	clr.l	(a0)+
	dbra	d0,.eb
	move.l	#EXECB,$4.w
	move.w	#$004F,EXECB+$128       ; AttnFlags: 010 020 030 040 FPU40
	cpusha	bc
	move.l	#$80008000,d0
	movec	d0,cacr
	ifd	FASTVBR
	lea	VBR2,a0                 ; the VBR in motherboard RAM, as MuFastZero puts it
	move.w	#255,d0
.vb:	move.l	#unexpected,(a0)+
	dbra	d0,.vb
	lea	VBR2,a0
	movec	a0,vbr
	endc
	TPRINT	msg_start
	TMARK	4                       ; the bench presses the HRTmon key
.idle:	bra.s	.idle

unexpected:
	move.l	2(sp),d0                ; the stacked PC
	PUTHEX	d0
	move.w	6(sp),d0                ; format/vector
	PUTHEX	d0
	TFAIL	255

print_str:
	moveq	#0,d0
.p:	move.b	(a0)+,d0
	beq.s	.e
	PUTC	d0
	bra.s	.p
.e:	rts

msg_start:	dc.b	"t_hrtmon_real: press the key",10,0
	even
EXECB	equ	$00001000
VBR2	equ	$07F00000
