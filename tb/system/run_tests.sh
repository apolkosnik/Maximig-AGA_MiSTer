#!/bin/sh
# System regression: the real machine (a4k_machine with the SDRAM and DDR3
# models) running the test ROMs of tb/asm.
#   t_board   the motherboard and the chipset as the 68040 sees them; the
#             ROM reports PASS/FAIL through the mailbox
#   t_chipset Denise, the CIAs: behaviour the board test does not reach
#   t_hrtmon_mmu  HRTmon's NMI entry with the vector table MMU-translated
#   t_bfg     the BFG9060 card: its firmware ID, flash, 128 MB at $08000000,
#             MOVE16, interrupts, TCI (chip RAM data not cached), at 25 and
#             37.5 MHz
#   t_reset   Main's reset (halt, the configuration, reset) with the CPU on
#             the chip bus: the machine must boot again
#   t_a3kp    the AA3000+ build: the DMAC+ registers, the DSP control latch
#             (U124) and status, the chip RAM and ROM windows
#   t_scsi    the AA3000+'s SCSI (WD33C93A, SuperDMAC DMA, the disks on IDE
#             channel 0 as Main serves them): INQUIRY, READ CAPACITY, READ/
#             WRITE, the unexpected phase and its resume, CHECK CONDITION and
#             REQUEST SENSE, the selection timeout, the level-2 interrupt
#   t_dsp     the AA3000+'s DSP3210 booted through its boot ROM as
#             dsp3210.resource does (U124, INT1, location 0), running from
#             chip RAM: CA/DA results, a bus error, INT0, BIO7 to INT2
#   t_ar      the Action Replay cartridge (AR5's DeMoN v2 layout): its freezes
#             (reset, CIA traps, the key), control register, register
#             snapshot and stealth
#   t_timing  Copperline's accelprobe rows against the real A4000/A3640
#             (timing_check.py)
#   tb_ide, tb_hps  the IDE (ide.v, Budgie, hps_ext) with Main's side
#             played by the bench (tb/ide/run.sh)
#   tb_agnus  Agnus/Alice: beam counters, copper, DMA slots (tb/agnus/run.sh)
#   tb_denise Denise: BPLxDAT/SPRxDATx loads in the wide fetch modes (tb/denise/run.sh)
#   tb_rtc    the RP5C01: 12/24-hour writes and counts (tb/rtc/run.sh)
#   tb_rtg    the RTG driver's SetGC/SetPanning on the AP68040 bench (tb/rtg/run.sh)
#   tb_cia    the 8520s' PB6/PB7 timer outputs (tb/cia/run.sh)
#   tb_dsp3210  the DSP3210 core and its assembler (tb/dsp3210/run.sh)
#   tb_a2065  the A2065's CMD ring at a full host (tb/a2065/run.sh)
#   tb_audio, tb_attach, tb_pot  Paula's audio DMA blocks, channel attachment,
#             the analog pots (tb/paula/run.sh)
#   tb_memory, tb_card  the local bus, SDRAM (refresh too), DDR3, RTG
#             registers and CLUT, the A3640 (tb/mem/run.sh)
#   t_blitter 650 random blits (area, fill, descending, lines) against a
#             model of the blitter from WinUAE (blitter_check.py)
# OBJ=<dir> picks the simulator build (default obj_tests, rebuilt here).
set -e
cd "$(dirname "$0")"
OBJ=${OBJ:-obj_tests}
OBJ=$OBJ ./build.sh > build_tests.log 2>&1 || { tail -30 build_tests.log; exit 1; }
../asm/build.sh t_board t_timing hrtmon_stub t_hrtmon_mmu extrom_pattern t_chipset t_ar ar_stub t_rtr t_reset t_bfg > /dev/null

fail=0
out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_board.rom --cart ../asm/build/hrtmon_stub.bin --extrom ../asm/build/extrom_pattern.bin --ms 400 --quiet 2>&1) || true
echo "$out" | grep -v '^\[sim\]'
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_board  PASS"; else echo "t_board  FAIL"; fail=1; fi

# the same in Fast bus timing (chip writes posted by Budgie, the regions' waits gone)
out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_board.rom --cart ../asm/build/hrtmon_stub.bin --extrom ../asm/build/extrom_pattern.bin --ms 400 --fast --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_board (fast) PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_board (fast) FAIL"; fail=1; fi

out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_chipset.rom --ms 1500 --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_chipset PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_chipset FAIL"; fail=1; fi

out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_hrtmon_mmu.rom --cart ../asm/build/hrtmon_stub.bin --ms 200 --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_hrtmon_mmu PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_hrtmon_mmu FAIL"; fail=1; fi

out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_ar.rom --ar ../asm/build/ar_stub.bin --ms 300 --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_ar PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_ar FAIL"; fail=1; fi

# the BFG9060 card in place of the A3640
for sp in 0 1; do
	out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_bfg.rom --bfg --speed $sp --ms 150 --quiet 2>&1) || true
	if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_bfg (speed $sp) PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_bfg (speed $sp) FAIL"; fail=1; fi
done

# Main's reset: the halt window short (Main's commands alone) and long (an
# Action Replay upload)
for h in 2000 20000; do
	out=$(timeout 1800 ./$OBJ/Vtb_top --rom ../asm/build/t_reset.rom --mainreset $h --ms 300 --quiet 2>&1) || true
	if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_reset (halt $h) PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_reset (halt $h) FAIL"; fail=1; fi
done

# the AA3000+ (a4k_machine with A3000P and its 68030, as Maximig.sv
# builds it on this branch): the DMAC+, the DSP control latch, the chip RAM
# and ROM windows
OBJ=${OBJ}_a3kp ./build.sh -GA3000P=1 -GCPU_CARD=3 -GDRIVE_SOUNDS=0 > build_tests_a3kp.log 2>&1 || { tail -30 build_tests_a3kp.log; exit 1; }
../asm/build.sh t_a3kp > /dev/null
out=$(timeout 1800 ./${OBJ}_a3kp/Vtb_top --rom ../asm/build/t_a3kp.rom --ms 150 --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_a3kp PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_a3kp FAIL"; fail=1; fi
# its SCSI: the WD33C93A behind the SuperDMAC, the disks on IDE channel 0
# with Main's side played by the bench (a fresh image each run: t_scsi writes)
../asm/build.sh t_scsi > /dev/null
PYTHONDONTWRITEBYTECODE=1 python3 mkhdf.py ${OBJ}_a3kp/t_scsi.hdf
out=$(timeout 1800 ./${OBJ}_a3kp/Vtb_top --rom ../asm/build/t_scsi.rom --hdf ${OBJ}_a3kp/t_scsi.hdf --ms 200 --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_scsi PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_scsi FAIL"; fail=1; fi
../asm/build.sh t_dsp > /dev/null
out=$(timeout 1800 ./${OBJ}_a3kp/Vtb_top --rom ../asm/build/t_dsp.rom --ms 150 --quiet 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D'; then echo "t_dsp PASS"; else echo "$out" | grep -v '^\[sim\]'; echo "t_dsp FAIL"; fail=1; fi

# the PC sampler's recorder (a debug build: the macro MAXIMIG_PCSAMPLE, the
# ring armed after 256 retires): t_rtr freezes it at $100, the DDR3 dump is
# decoded and checked by rec_decode.py
OBJ=${OBJ}_pcs ./build.sh -DMAXIMIG_PCSAMPLE=1 -DMAXIMIG_RTR_ARM_BITS=8 > build_tests_pcs.log 2>&1 || { tail -30 build_tests_pcs.log; exit 1; }
out=$(timeout 1800 ./${OBJ}_pcs/Vtb_top --rom ../asm/build/t_rtr.rom --ms 300 --quiet --ddrdump 0x27FF6000 0x2000 ${OBJ}_pcs/t_rtr.bin 2>&1) || true
if echo "$out" | grep -q '^\[mailbox\].*result 600D' && PYTHONDONTWRITEBYTECODE=1 python3 rec_decode.py ${OBJ}_pcs/t_rtr.bin --check-rtr > /dev/null; then echo "t_rtr PASS"; else echo "$out" | grep -v '^\[sim\]'; PYTHONDONTWRITEBYTECODE=1 python3 rec_decode.py ${OBJ}_pcs/t_rtr.bin --check-rtr; echo "t_rtr FAIL"; fail=1; fi

if PYTHONDONTWRITEBYTECODE=1 python3 timing_check.py --sim ./$OBJ/Vtb_top --rom ../asm/build/t_timing.rom; then
	echo "t_timing PASS"
else
	echo "t_timing FAIL"; fail=1
fi

if PYTHONDONTWRITEBYTECODE=1 python3 blitter_check.py --sim ./$OBJ/Vtb_top; then
	echo "t_blitter PASS"
else
	echo "t_blitter FAIL"; fail=1
fi

if ../ide/run.sh; then :; else fail=1; fi
if ../mem/run.sh; then :; else fail=1; fi
if ../paula/run.sh; then :; else fail=1; fi
if ../agnus/run.sh; then :; else fail=1; fi
if ../denise/run.sh; then :; else fail=1; fi
if ../rtc/run.sh; then :; else fail=1; fi
if ../rtg/run.sh; then :; else fail=1; fi
if ../cia/run.sh; then :; else fail=1; fi
if ../a2065/run.sh; then :; else fail=1; fi
if ../dsp3210/run.sh; then :; else fail=1; fi

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit $fail
