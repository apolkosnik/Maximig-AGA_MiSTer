#!/bin/sh
# Paula regression on the real modules: audio DMA block lengths and channel
# attachment (paula + agnus_audiodma, paula_top.v), the analog joystick pot
# counters (userio, pot_top.v).  (After audits' benches, 2026-10-24/25.)
set -e
cd "$(dirname "$0")"
M=${R:-../../rtl}/minimig
W="-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD"
fail=0
verilator --no-timing --cc --exe --build -j 8 $W --top-module paula_top -Mdir obj_audio paula_top.v \
	$M/paula.v $M/paula_uart.v $M/paula_intcontroller.v $M/paula_floppy.v $M/paula_floppy_fifo.v \
	$M/paula_audio.v $M/paula_audio_volume.v $M/paula_audio_mixer.v $M/paula_audio_channel.v $M/agnus_audiodma.v \
	$M/MiSTerFloppyi2c.v $M/MiSTerFloppyPLL.v $M/MiSTerFloppyRAWIO.v $M/MiSTerFloppySHUGART.v $M/MiSTerFloppyFifo.v $M/MiSTerFloppyVirtualFluxDrive.v \
	tb_audio.cpp -o tb_audio > build_audio.log 2>&1 || { tail -20 build_audio.log; exit 1; }
if ./obj_audio/tb_audio > run_audio.log 2>&1; then echo "tb_audio PASS"; else grep FAIL run_audio.log; echo "tb_audio FAIL"; fail=1; fi
verilator --no-timing --cc --exe --build -j 8 $W --top-module paula_top -Mdir obj_attach paula_top.v \
	$M/paula.v $M/paula_uart.v $M/paula_intcontroller.v $M/paula_floppy.v $M/paula_floppy_fifo.v \
	$M/paula_audio.v $M/paula_audio_volume.v $M/paula_audio_mixer.v $M/paula_audio_channel.v $M/agnus_audiodma.v \
	$M/MiSTerFloppyi2c.v $M/MiSTerFloppyPLL.v $M/MiSTerFloppyRAWIO.v $M/MiSTerFloppySHUGART.v $M/MiSTerFloppyFifo.v $M/MiSTerFloppyVirtualFluxDrive.v \
	tb_attach.cpp -o tb_attach > build_attach.log 2>&1 || { tail -20 build_attach.log; exit 1; }
if ./obj_attach/tb_attach > run_attach.log 2>&1; then echo "tb_attach PASS"; else grep FAIL run_attach.log; echo "tb_attach FAIL"; fail=1; fi
verilator --no-timing --cc --exe --build -j 8 $W --public-flat-rw --top-module pot_top -Mdir obj_pot pot_top.v $M/userio.v tb_pot.cpp -o tb_pot > build_pot.log 2>&1 || { tail -20 build_pot.log; exit 1; }
if ./obj_pot/tb_pot > run_pot.log 2>&1; then echo "tb_pot PASS"; else grep FAIL run_pot.log; echo "tb_pot FAIL"; fail=1; fi
exit $fail
