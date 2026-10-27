; t_reset: Main's reset (minimig_reset, ApplyConfiguration) while the CPU is
; on the chip bus.  Main halts first (UIO_MM2_RST SPI_CPU_HLT), applies the
; configuration with the machine running, then resets (HLT|RST_CPU|RST_USR)
; and releases (0).  The bridge (minimig_m68k_bridge) takes the halt between
; two chip-bus cycles; a cycle Budgie starts after that gets no DTACK until
; the halt ends, and the halt only ends while AS is negated.  This ROM keeps
; the chip bus busy (chip RAM writes, a custom register and a CIA read) and
; asks the bench for Main's reset with mark 7 (sim_main --mainreset); the
; second boot must get through the CIA and custom accesses at its start.
;
; The boot count is a long word in chip RAM ($100000, past the overlay; a
; reset leaves chip RAM alone):
;   not BOOT1  the first boot: BOOT1 written, mark 7, the busy loop
;   BOOT1      after the reset: BOOT2 written, the chip bus checked, PASS
;   BOOT2      a third boot: FAIL 1
;  FAIL 2: chip RAM read back wrong after the reset

	include	"hw.i"

COUNT	equ	$00100000
BOOT1	equ	$B0071111
BOOT2	equ	$B0072222

	ROMHEADER start
	org	$F80400

start:
	move.b	#3,CIAA_DDRA            ; (a chip-bus cycle: CIA-A)
	move.b	#2,CIAA_PRA             ; OVL off, the power LED on
	lea	$20000,sp
	lea	CUSTOM,a1
	move.w	#$7FFF,$9A(a1)          ; (a chip-bus cycle: a custom register)
	move.l	COUNT,d0
	cmp.l	#BOOT1,d0
	beq.s	second
	cmp.l	#BOOT2,d0
	bne.s	first
	TFAIL	1

first:
	move.l	#BOOT1,COUNT
	TMARK	7                       ; the bench: Main's reset
	moveq	#0,d1
.busy:	move.l	d1,COUNT+4              ; chip RAM
	move.w	$006(a1),d2             ; VHPOSR
	move.b	CIAA_PRA,d3             ; CIA-A
	addq.l	#1,d1
	bra.s	.busy

second:
	move.l	#BOOT2,COUNT
	move.w	#$0F0F,$180(a1)
	move.l	COUNT,d0
	TCHECK	d0,BOOT2,2
	move.b	CIAA_PRA,d3
	TPASS	0
