#!/bin/sh
# Build maximig_ext.rom (512 KB, the size Main loads as an Ext.ROM) with vasm.
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
$VASM -quiet -Fbin -m68060 -no-opt -o maximig_ext.bin maximig_ext.s || exit 1
python3 -c "
b = open('maximig_ext.bin', 'rb').read()
assert len(b) <= 0x80000
open('maximig_ext.rom', 'wb').write(b + b'\xff' * (0x80000 - len(b)))
"
rm -f maximig_ext.bin
echo maximig_ext.rom
