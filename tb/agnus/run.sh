#!/bin/sh
# Agnus/Alice regression on the real agnus.v (and its submodules, with
# amiga_clk.v): the beam counters (PAL/NTSC, long/short lines and frames,
# LOL, VPOSR ID, VHPOSR across the line end), DMACON, the copper (WAIT,
# SKIP, CDANG, the restart), the DMA slot map, sprites against the bitplane
# DMA window, the last line, BLTPRI, the programmed vertical blank.
# tb_agnus.cpp plays the 68k bridge and Paula's DMAL.  (After an audit's bench, 2026-10-24.)
cd "$(dirname "$0")"
M=${R:-../../rtl}/minimig
verilator --cc --exe --build -j 8 -O2 --no-timing --public-flat-rw --x-assign fast --x-initial fast -Wno-fatal -Wno-lint -Wno-style \
	-Wno-STMTDLY -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-COMBDLY -Wno-LATCH \
	--top-module tb_agnus -Mdir obj tb_agnus.sv \
	$M/agnus.v $M/agnus_spritedma.v $M/agnus_refresh.v $M/agnus_diskdma.v $M/agnus_copper.v \
	$M/agnus_blitter.v $M/agnus_blitter_minterm.v $M/agnus_blitter_fill.v $M/agnus_blitter_barrelshifter.v \
	$M/agnus_blitter_adrgen.v $M/agnus_bitplanedma.v $M/agnus_beamcounter.v $M/agnus_audiodma.v \
	$M/amiga_clk.v tb_agnus.cpp -o tb_agnus > build.log 2>&1 || { tail -20 build.log; exit 1; }
: > run.log
for t in "beam" "beam ntsc" "lol" "dmacon" "lace" "lace ntsc" "lastline" "vhposr" "cop" "sprwin" "nasty" "bltend" "vbstrt" "slots pal 0"; do
	echo "=== tb_agnus $t" >> run.log
	timeout 300 ./obj/tb_agnus $t >> run.log 2>&1 || echo "FAIL tb_agnus $t exited $?" >> run.log
done
if grep -q FAIL run.log; then grep -E "^===|FAIL" run.log | grep -B1 FAIL; echo "tb_agnus FAIL"; exit 1; fi
echo "tb_agnus PASS ($(grep -c PASS run.log) checks)"
