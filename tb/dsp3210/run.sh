#!/bin/sh
# The DSP3210 regression: the assembler's encodings, the core's tests (also
# with external wait states).
cd "$(dirname "$0")"
./build.sh > /dev/null || { echo "tb_dsp3210 FAIL (build)"; exit 1; }
fail=0
PYTHONDONTWRITEBYTECODE=1 python3 asm_check.py | grep -q PASS || { python3 asm_check.py; fail=1; }
PYTHONDONTWRITEBYTECODE=1 python3 run.py > run.log 2>&1 || { cat run.log; fail=1; }
DSPARGS="--waits 3" PYTHONDONTWRITEBYTECODE=1 python3 run.py > run_w3.log 2>&1 || { cat run_w3.log; fail=1; }
[ $fail -eq 0 ] && echo "tb_dsp3210 PASS" || echo "tb_dsp3210 FAIL"
exit $fail
