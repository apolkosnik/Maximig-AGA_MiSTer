# AR5.ROM for Maximig

Action Replay V5 (https://github.com/apolkosnik/ActionReplay5, bf7484a), its DeMoN v2
hardware build: ROM at $A80000-$ABFFFF, RAM at $AC0000-$AFFFFF.  Put it in
games/Amiga/ as AR5.ROM and set System -> Cartridge: Action Replay; the
freeze key is the one HRTmon uses.

Built with vasm 1.9 (the makefile's hwv2 target, without its Amiga-side
post-processing):

    vasmm68k_mot -Fbin -no-opt -quiet -o AR5_demon2.bin AR5.asm \
        -Ddbg=0 -Dpistorm=0 -Darhardware=1 -Darsoft=0 -Ddemon2=1

-Fbin writes from address 0, so the image is bytes $A80000-$AFFFFF of the
output (512 KB: the ROM and the RAM's initial image).  The long word at
+$3FFFC is then set to AR5's own checksum, the 32-bit sum of the long words
from +$7C to +$3FFF8 (calcChecksum), which the hwv2 target's tool would
write; without it AR5 reports the ROM as corrupt.
