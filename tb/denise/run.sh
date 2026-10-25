#!/bin/sh
# Denise regression: the real denise.v and its blocks on the register bus.
# BPLxDAT/SPRxDATx loads by DMA, the copper and the CPU in every fetch mode;
# in FMODE 2/3 a copper or CPU write's first word is the chip bus's previous
# word.  (After an audit's reproducer, 2026-10-25: it was the SDRAM's burst
# words of the last chip read.)
set -e
cd "$(dirname "$0")"
M=../../rtl/minimig
verilator --binary --timing -Wno-fatal --top-module tb --Mdir obj_denise tb_denise.sv \
	$M/amiga_clk.v $M/denise.v $M/denise_bitplanes.v $M/denise_bitplane_shifter.v $M/denise_playfields.v \
	$M/denise_sprites.v $M/denise_sprites_shifter.v $M/denise_spritepriority.v $M/denise_colortable.v \
	$M/denise_colortable_ram_mf.v $M/denise_hamgenerator.v $M/denise_collision.v ../sim_lib/altsyncram.v > build_denise.log 2>&1 || { tail -20 build_denise.log; exit 1; }
if ./obj_denise/Vtb > run_denise.log 2>&1 && grep -q "^PASS" run_denise.log; then
	echo "tb_denise PASS"
else
	grep -v "^- " run_denise.log; echo "tb_denise FAIL"; exit 1
fi
