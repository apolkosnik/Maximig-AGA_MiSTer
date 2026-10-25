#!/bin/sh
# CIA regression: the real ciaa.v and ciab.v at the pins.  Timer A and B's
# outputs on PB6/PB7 (PBON, toggle and pulse, one-shot, over DDRB, read back
# through PRB).  (After an audit's reproducer, 2026-10-25: PBON was stored
# and had no effect.)
set -e
cd "$(dirname "$0")"
M=../../rtl/minimig
verilator --binary --timing -Wno-fatal --top-module tb --Mdir obj_cia tb_cia.sv \
	$M/ciaa.v $M/ciab.v $M/cia_timera.v $M/cia_timerb.v $M/cia_timerd.v $M/cia_int.v > build_cia.log 2>&1 || { tail -20 build_cia.log; exit 1; }
if ./obj_cia/Vtb > run_cia.log 2>&1 && grep -q "^PASS" run_cia.log; then
	echo "tb_cia PASS"
else
	grep -v "^- " run_cia.log; echo "tb_cia FAIL"; exit 1
fi
