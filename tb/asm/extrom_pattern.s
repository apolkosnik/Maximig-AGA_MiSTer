; extrom_pattern: what t_board (140-149) reads at $E00000 when the bench
; loads it as the extension ROM (sim_main --extrom)
	dc.l	$E0E0C0DE,$12345678
