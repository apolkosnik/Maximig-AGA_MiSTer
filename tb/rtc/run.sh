#!/bin/sh
# RTC regression: the real a4k_rtc (RP5C01) through its registers.  The hour
# written a digit at a time in 12- and 24-hour mode, the 12-hour count over
# AM/PM and midnight, the MiSTer's time loaded in 12-hour mode.  (After an
# audit's reproducer, 2026-10-25: 07 AM written over 12 AM read back 05 AM.)
set -e
cd "$(dirname "$0")"
R=../../rtl
verilator --binary --timing -O3 -Wno-fatal --top-module tb --Mdir obj_rtc tb_rtc.sv $R/a4000/a4k_rtc.sv > build_rtc.log 2>&1 || { tail -20 build_rtc.log; exit 1; }
if ./obj_rtc/Vtb > run_rtc.log 2>&1 && grep -q "^PASS" run_rtc.log; then
	echo "tb_rtc PASS"
else
	cat run_rtc.log; echo "tb_rtc FAIL"; exit 1
fi
