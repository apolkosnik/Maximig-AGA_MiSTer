#!/bin/sh
# The machine's RTL (a4k_machine and everything below it), for the
# simulations.  Source this with R set to the repository root.
A40=$R/rtl/AP68040/rtl
M=$R/rtl/minimig
CPU_SRC="$A40/ap68040_pkg.sv $A40/gen/ap68040_upkg.sv $A40/ap68040_alu.sv $A40/ap68040_alu_slow.sv
 $A40/ap68040_muldiv.sv $A40/ap68040_biu.sv $A40/ap68040_ram.sv $A40/ap68040_atc.sv $A40/ap68040_dmu.sv
 $A40/ap68040_predec.sv $A40/ap68040_fetch.sv $A40/ap68040_decode.sv $A40/ap68040_useq.sv
 $A40/fpu/ap040_fpu.v $A40/ap68040_fpif.sv $A40/ap68040_backend.sv $A40/ap68040_snoop.sv $A40/ap68040.sv"
CPU_INC="-I$A40 -I$A40/fpu -I$A40/gen"
CHIP_SRC="$M/agnus.v $M/agnus_spritedma.v $M/agnus_refresh.v $M/agnus_diskdma.v $M/agnus_copper.v
 $M/agnus_blitter.v $M/agnus_blitter_minterm.v $M/agnus_blitter_fill.v $M/agnus_blitter_barrelshifter.v
 $M/agnus_blitter_adrgen.v $M/agnus_bitplanedma.v $M/agnus_beamcounter.v $M/agnus_audiodma.v
 $M/denise.v $M/denise_sprites.v $M/denise_sprites_shifter.v $M/denise_spritepriority.v $M/denise_playfields.v
 $M/denise_hamgenerator.v $M/denise_colortable.v $M/denise_colortable_ram_mf.v $M/denise_collision.v
 $M/denise_bitplanes.v $M/denise_bitplane_shifter.v
 $M/paula.v $M/paula_uart.v $M/paula_intcontroller.v $M/paula_floppy.v $M/paula_floppy_fifo.v
 $M/paula_audio.v $M/paula_audio_volume.v $M/paula_audio_mixer.v $M/paula_audio_channel.v
 $M/ciaa.v $M/ciab.v $M/cia_timerd.v $M/cia_timerb.v $M/cia_timera.v $M/cia_int.v
 $M/MiSTerFloppyi2c.v $M/MiSTerFloppyPLL.v $M/MiSTerFloppyRAWIO.v $M/MiSTerFloppySHUGART.v
 $M/MiSTerFloppyFifo.v $M/MiSTerFloppyVirtualFluxDrive.v
 $M/amiga_clk.v $M/userio.v $M/minimig_syscontrol.v $M/minimig_m68k_bridge.v $M/ide.v $M/rtg.v $M/drive_sounds.v
 $M/A2065/a2065.v $M/A2065/a2065_ddr3_mailbox.v $M/A2065/a2065_ddram.v $M/A2065/a2065_ddram_arbiter.v $M/A2065/a2065_regfile.v
 $M/fpga-toccata/toccata_capture.sv $M/fpga-toccata/toccata_playback.sv $M/fpga-toccata/toccata_volume.sv
 $M/fpga-toccata/toccata_fifo.sv $M/fpga-toccata/toccata.sv"
A4K_SRC="$R/rtl/a4000/dpram.v $R/rtl/a4000/a4k_cpuclk.sv $R/rtl/a4000/a4k_a3640.sv $R/rtl/a4000/a4k_bfg9060.sv $R/rtl/a4000/a4k_buster.sv
 $R/rtl/a4000/a4k_lbus.sv $R/rtl/a4000/a3kp_dmac.sv $R/rtl/a4000/a3kp_sbic.sv $R/rtl/a4000/a3kp_scsi_disk.sv $R/rtl/a4000/a3kp_lbarb.sv $R/rtl/a4000/a3kp_dsp_pkg.sv $R/rtl/a4000/a3kp_dsp_rf.sv $R/rtl/a4000/a3kp_dsp3210.sv $R/rtl/a4000/a4k_budgie.sv $R/rtl/a4000/a4k_rtc.sv $R/rtl/a4000/a4k_sdram.sv
 $R/rtl/a4000/a4k_ddr3.sv $R/rtl/a4000/a4k_chipset.v $R/rtl/a4000/a4k_machine.sv"
SIMLIB_SRC="$R/tb/sim_lib/altsyncram.v"
MACHINE_SRC="$CPU_SRC $SIMLIB_SRC $CHIP_SRC $A4K_SRC"
MACHINE_INC="$CPU_INC -I$M -I$R/rtl/a4000"
