#!/bin/sh
# Assemble tb/asm/<name>.s into build/<name>.rom (512 KB, the ROM socket's
# image at $F80000).
set -e
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
mkdir -p build
for t in "$@"; do
	$VASM -quiet -Fbin -m68040 -no-opt -L build/$t.lst -o build/$t.bin $t.s
	python3 -c "
import sys
b = open('build/$t.bin','rb').read()
assert len(b) <= 0x80000, 'image too big'
open('build/$t.rom','wb').write(b + b'\xff' * (0x80000 - len(b)))
"
	echo "build/$t.rom"
done
