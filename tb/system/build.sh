#!/bin/sh
# Build the full-system simulation of the real RTL (a4k_machine with SDRAM
# and DDR3 models).  OBJ=<dir> picks the object directory (default obj_dir);
# TRACE=1 builds with FST waveform support (--vcd), into obj_trace by default.
set -e
cd "$(dirname "$0")"
R=$(cd ../.. && pwd)
. ../sources.sh
PYTHONDONTWRITEBYTECODE=1 python3 $R/rtl/AP68040/tools/ucode.py > /dev/null
if [ -n "$TRACE" ]; then TRACEOPT="--trace-fst --trace-structs"; OBJDEF=obj_trace; else TRACEOPT=""; OBJDEF=obj_dir; fi
verilator --cc --exe --build --no-timing -j 24 -O3 --x-assign fast --x-initial fast \
	-Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
	-Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-LATCH -Wno-COMBDLY \
	--top-module tb_top -Mdir ${OBJ:-$OBJDEF} $TRACEOPT \
	-CFLAGS "-O2 -march=native" \
	$MACHINE_INC $MACHINE_SRC tb_top.sv sdram_model.sv ddr3_model.sv sim_main.cpp "$@"
echo "built ${OBJ:-$OBJDEF}/Vtb_top"
