#!/bin/sh
# Build MiSTer.card (the Zorro III RTG board's Picasso96 driver) with vasm.
cd "$(dirname "$0")"
VASM=${VASM:-/opt/amiga-cc/vbcc/bin/vasmm68k_mot}
$VASM -quiet -Iinclude -Fhunkexe -nosym -phxass -opt-fconst -nowarn=62 -o MiSTer.card MiSTer.card.asm && echo MiSTer.card
