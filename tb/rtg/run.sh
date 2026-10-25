#!/bin/sh
# RTG driver regression: extra/rtg_driver/MiSTer.card.asm's SetGC and
# SetPanning on the AP68040 program bench (t_rtg.s): the scan-out address of
# a scrolled view and the stride of a virtual screen wider than the mode, in
# 8, 16, 24 and 32 bits per pixel.  Run with no waits and with random waits.
# (After an audit's reproducers, 2026-10-25: SetPanning ignored the offsets
# and the bitmap's width.)
set -e
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
AP=../../rtl/AP68040
mkdir -p obj
$VASM -quiet -Fbin -m68040 -no-opt -I../../extra/rtg_driver -I../../extra/rtg_driver/include \
	-o obj/t_rtg.bin t_rtg.s > obj/asm.log 2>&1 || { cat obj/asm.log; exit 1; }
python3 $AP/tb/bin2hex.py obj/t_rtg.bin obj/t_rtg.hex
WORK=$(pwd)/obj $AP/tb/build_sim.sh > build_rtg.log 2>&1 || { tail -20 build_rtg.log; exit 1; }
fail=0
for cfg in "" "+waits"; do
	if ./obj/obj_prog/tb_ap68040 +prog=obj/t_rtg.hex +timeout=2000000 $cfg > run_rtg.log 2>&1 && grep -q "^PASS" run_rtg.log; then
		echo "tb_rtg ${cfg:-+nowaits} PASS"
	else
		grep -v "^- " run_rtg.log; echo "tb_rtg ${cfg:-+nowaits} FAIL"; fail=1
	fi
done
exit $fail
