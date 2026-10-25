#!/bin/sh
# A2065 regression: the real a2065_ddr3_mailbox's CMD ring against a host
# model.  A full ring makes a command wait for the host, not write over an
# unread entry; past the wait limit the command is dropped and counted.
# (After an audit's probe, 2026-10-25.)
set -e
cd "$(dirname "$0")"
verilator --binary --timing -Wno-fatal --top-module tb --Mdir obj_ring tb_ring.sv \
	../../rtl/minimig/A2065/a2065_ddr3_mailbox.v > build_ring.log 2>&1 || { tail -20 build_ring.log; exit 1; }
if ./obj_ring/Vtb > run_ring.log 2>&1 && grep -q "^PASS" run_ring.log; then
	echo "tb_a2065 PASS"
else
	grep -v "^- " run_ring.log | head -40; echo "tb_a2065 FAIL"; exit 1
fi
