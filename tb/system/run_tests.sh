#!/bin/sh
# System regression: the real machine (a4k_machine with the SDRAM and DDR3
# models) running the test ROMs of tb/asm.
#   t_board   the motherboard and the chipset as the 68040 sees them; the
#             ROM reports PASS/FAIL through the mailbox
#   t_hrtmon_mmu  HRTmon's NMI entry with the vector table MMU-translated
#   t_timing  Copperline's accelprobe rows against the real A4000/A3640
#             (timing_check.py)
# OBJ=<dir> picks the simulator build (default obj_tests, rebuilt here).
set -e
cd "$(dirname "$0")"
OBJ=${OBJ:-obj_tests}
OBJ=$OBJ ./build.sh > build_tests.log 2>&1 || { tail -30 build_tests.log; exit 1; }
../asm/build.sh t_board t_timing hrtmon_stub t_hrtmon_mmu > /dev/null

fail=0
out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_board.rom --cart ../asm/build/hrtmon_stub.bin --ms 400 --quiet 2>&1) || true
echo "$out" | grep -v '^\[sim\]'
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_board  PASS"; else echo "t_board  FAIL"; fail=1; fi

out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_hrtmon_mmu.rom --cart ../asm/build/hrtmon_stub.bin --ms 200 --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_hrtmon_mmu PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_hrtmon_mmu FAIL"; fail=1; fi

if PYTHONDONTWRITEBYTECODE=1 python3 timing_check.py --sim ./$OBJ/Vtb_top --rom ../asm/build/t_timing.rom; then
	echo "t_timing PASS"
else
	echo "t_timing FAIL"; fail=1
fi

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit $fail
