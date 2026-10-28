#!/bin/sh
# Build the DSP3210 bench (the real a3kp_dsp3210 on a memory model).
set -e
cd "$(dirname "$0")"
R=$(cd ../.. && pwd)/rtl/a4000
verilator --cc --exe --build -j 16 -O2 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNUSED $DEFS \
	--top-module tb_dsp -Mdir ${OBJ:-obj} -I$R $R/a3kp_dsp_pkg.sv $R/a3kp_dsp3210.sv tb_dsp.sv sim_dsp.cpp > build.log 2>&1 || { tail -30 build.log; exit 1; }
echo "built ${OBJ:-obj}/Vtb_dsp"
