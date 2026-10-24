#!/bin/sh
# IDE regression: the real ide.v and a4k_budgie.sv (and hps_ext.v for the
# second bench) with Main's side played by the bench.  Transfers (10249
# words: byte order, word/long accesses, timings, streaming stalls,
# multi-block, ATAPI), the status/alternate-status IRQ semantics, nIEN,
# SRST, the interrupt status register over a warm reset, HOB.
# tb_ide drives the IDE's management port directly, tb_hps through hps_ext
# as Main does.  (After an audit's reproducers, 2026-10-24.)
set -e
cd "$(dirname "$0")"
R=../../rtl
fail=0
for t in ide hps; do
	src="$R/minimig/ide.v $R/a4000/a4k_budgie.sv $R/a4000/dpram.v"
	[ $t = hps ] && src="$src $R/minimig/hps_ext.v"
	verilator --binary --timing -Wno-fatal --top-module tb --Mdir obj_$t tb_$t.sv $src > build_$t.log 2>&1 || { tail -20 build_$t.log; exit 1; }
	if ./obj_$t/Vtb > run_$t.log 2>&1 && ! grep -q "CONTROL FAIL" run_$t.log; then
		echo "tb_$t PASS"
	else
		grep -v "^- " run_$t.log; echo "tb_$t FAIL"; fail=1
	fi
done
exit $fail
