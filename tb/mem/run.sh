#!/bin/sh
# Memory regression: the real a4k_lbus, Buster, a4k_sdram (with the SDRAM
# pin model of tb/system), the DDR3 path and rtg.v; tb_card adds the A3640
# (a4k_a3640, a4k_cpuclk) at every CPU clock.  Byte lanes, boundaries,
# bursts, DDR contention, the ROM, the RTG registers' and the CLUT's byte
# and word writes, and refresh under a CPU streaming to the motherboard RAM
# (at most 32 SDRAM slots without one).  tb_ramsey: Ramsey's refresh and
# page wait states around a refresh's start; the PC sampler off in a normal
# build, and in a MAXIMIG_PCSAMPLE build not holding up the CPU behind DDR3.  (After an audit's benches,
# 2026-10-24.)
set -e
cd "$(dirname "$0")"
R=${R:-../../rtl}
W="-Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-PINMISSING"
COMMON="$R/a4000/a4k_lbus.sv $R/a4000/a4k_buster.sv $R/a4000/a4k_sdram.sv $R/a4000/a4k_ddr3.sv $R/minimig/rtg.v $R/minimig/A2065/a2065_ddram_arbiter.v ../system/sdram_model.sv ../system/ddr3_model.sv"
fail=0
verilator --binary --timing -j 8 $W --top-module tb_memory -Mdir obj_memory tb_memory.sv $COMMON > build_memory.log 2>&1 || { tail -20 build_memory.log; exit 1; }
if ./obj_memory/Vtb_memory > run_memory.log 2>&1; then echo "tb_memory PASS"; else grep -E "FAIL|STREAM|DONE" run_memory.log; echo "tb_memory FAIL"; fail=1; fi
verilator --binary --timing -j 8 $W --top-module tb_card -Mdir obj_card tb_card.sv $R/a4000/a4k_a3640.sv $R/a4000/a4k_cpuclk.sv $COMMON > build_card.log 2>&1 || { tail -20 build_card.log; exit 1; }
if ./obj_card/Vtb_card > run_card.log 2>&1; then echo "tb_card PASS"; else grep -E "FAIL|STREAM|DONE" run_card.log; echo "tb_card FAIL"; fail=1; fi
for v in normal pcsample; do
	D=""; [ $v = pcsample ] && D="-DMAXIMIG_PCSAMPLE"
	verilator --binary --timing -j 8 $W $D --top-module tb_ramsey -Mdir obj_ramsey_$v tb_ramsey.sv $R/a4000/a4k_a3640.sv $R/a4000/a4k_cpuclk.sv $COMMON > build_ramsey_$v.log 2>&1 || { tail -20 build_ramsey_$v.log; exit 1; }
	if ./obj_ramsey_$v/Vtb_ramsey > run_ramsey_$v.log 2>&1; then echo "tb_ramsey ($v) PASS"; else grep -E "FAIL" run_ramsey_$v.log; echo "tb_ramsey ($v) FAIL"; fail=1; fi
done
exit $fail
