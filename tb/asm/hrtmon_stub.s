; hrtmon_stub: a stand-in for hrtmon.rom, loaded where Main uploads it
; ($A10000, the cartridge RAM; sim_main --cart).  The NMI from the HRTmon key
; enters at $A1000C, as HRTmon does; this records that it ran, what the
; custom register mirror ($A9F000) holds for COLOR00 and a word of the
; cartridge RAM, for t_board (130-139) to check, and returns.

	org	$A10000
	dc.l	0,0,0

entry:	move.l	#$C0DEF00D,$1F04.w      ; ran
	move.w	$A9F180,$1F08.w         ; the mirror: COLOR00 as last written
	move.w	cartw,$1F0A.w           ; the cartridge RAM
	rte

	cnop	0,4
cartw:	dc.w	$5A5A
