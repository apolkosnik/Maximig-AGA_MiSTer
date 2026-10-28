#!/bin/sh
# Assemble tb/asm/<name>.s into build/<name>.rom (512 KB, the ROM socket's
# image at $F80000); <name>.dsp.s, a DSP3210 program, first (asm3210.py).
set -e
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
mkdir -p build
for t in "$@"; do
	# a DSP3210 program the ROM includes (build/<name>.dsp.bin)
	if [ -f $t.dsp.s ]; then
		PYTHONDONTWRITEBYTECODE=1 python3 ../dsp3210/asm3210.py $t.dsp.s -o build/$t.dsp.bin
	fi
	$VASM -quiet -Fbin -m68040 -no-opt -L build/$t.lst -o build/$t.bin $t.s
	python3 -c "
import sys
b = open('build/$t.bin','rb').read()
assert len(b) <= 0x80000, 'image too big'
open('build/$t.rom','wb').write(b + b'\xff' * (0x80000 - len(b)))
"
	echo "build/$t.rom"
done
