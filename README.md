# Maximig-AGA_MiSTer

An Amiga 4000/040 for MiSTer: a 68040 on an A3640-style CPU card, the
A4000 motherboard's bus controllers and the AGA chipset, modelled as
closely to the real machine as an FPGA allows (bus widths, cycle timing,
the A4000's own chips rather than an A1200 with a fast CPU).

* CPU: [AP68040](https://github.com/apolkosnik/AP68040) (branch `faster`,
  submodule `rtl/AP68040`), a pin-level MC68040 with caches, MMU and FPU,
  at 25, 33, 40, 50 or 56.75 MHz.
* Motherboard: Fat Gary (decode, bus timeout), Ramsey-07 (up to 16 MB of
  motherboard RAM at `$07000000`, page and refresh timing), Budgie (the
  chip bus), Buster (Zorro II and Zorro III autoconfig), the A4000 IDE
  port and the RP5C01 clock.
* Chipset: Alice, Lisa, Paula and the 8520s from the MiSTer
  [Minimig](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer) core,
  always AGA, 2 MB of chip RAM.
* Zorro III: 128, 256 or 384 MB of fast RAM in DDR3, and an RTG board
  compatible with [ZZMiSTerRTG](https://github.com/georgemog/ZZMiSTerRTG);
  optional A2065 Ethernet and Toccata sound on Zorro II.

Bus timing follows the real A4000 + A3640 at 25 MHz, measured with
Copperline's accelprobe: a line fill from chip RAM, motherboard RAM and
Zorro III RAM takes what it takes on the real machine (within 6%).  A
*Fast* option drops to the shortest timing the FPGA memories allow.
`docs/ARCHITECTURE.md` describes the design and the references it follows
(Commodore's chip specifications, WinUAE, Copperline).

## Status

Early.  In simulation the core boots Kickstart 3.1 (40.70, A4000) to the
insert-disk screen, and the board and timing tests pass.  It has not yet
run on a DE10-Nano.

## Building

```
git clone --recursive https://github.com/apolkosnik/Maximig-AGA_MiSTer
```

Open `Maximig.qpf` in Quartus Prime 17.0 (the MiSTer standard) and
compile; the core is `output_files/Maximig.rbf`.

Main_MiSTer recognises the Minimig family by core name.  Until it knows
this one, apply `main_patch/0001-Add-Maximig-A4000-core-support.patch` to
Main_MiSTer: it gives the core Minimig's HPS support under the name
Maximig, the games/Amiga directory, an A4000 System menu (CPU clock, bus
timing, Zorro III and motherboard RAM) and `KICK4000.ROM` as the default
Kickstart.

## Simulation

`tb/system` simulates the whole machine with Verilator (5.x):

```
tb/system/run_tests.sh             # build, then t_board and t_timing
tb/system/obj_tests/Vtb_top --rom KICK4000.ROM --ms 3000 --frames out
```

`sim_main.cpp` lists the options (bus and custom-register traces, FST
waveforms, a chip RAM dump).  The AP68040's own regression is
`rtl/AP68040/tb/run_tests.sh`.

## Licence

GPL v3 (`LICENSE`).  The Minimig chipset is GPL v3
(`rtl/minimig/COPYING.minimig`); AP68040 has its own licence, GPL v2
(`rtl/AP68040/LICENSE`).
