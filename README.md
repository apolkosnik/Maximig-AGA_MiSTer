# Maximig-AGA_MiSTer

An Amiga 4000/040 for MiSTer: a 68040 on an A3640-style CPU card, the
A4000 motherboard's own bus controllers and the AGA chipset, modelled as
closely to the real machine as an FPGA allows: bus widths, cycle timing,
and the A4000's chips rather than an A1200 with a fast CPU.

* **CPU:** [AP68040](https://github.com/apolkosnik/AP68040) (branch
  `faster`, submodule `rtl/AP68040`), a pin-level MC68040 with caches,
  MMU and FPU, at 25 (the A3640's clock), 33, 40, 50 or 56.75 MHz.
* **Motherboard:** Fat Gary (decode, bus timeout), Ramsey-07 (up to 16 MB
  of motherboard RAM at `$07000000`, page and refresh timing), Budgie (the
  chip bus), Buster (Zorro II and Zorro III autoconfig), the A4000 IDE
  port (`$DD2020`) and the RP5C01 clock.
* **Chipset:** Alice, Lisa, Paula and the 8520s from the MiSTer
  [Minimig](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer) core,
  always AGA, 2 MB of chip RAM.
* **Zorro III:** 128, 256 or 384 MB of fast RAM in DDR3, and an RTG board
  (the board [ZZMiSTerRTG](https://github.com/georgemog/ZZMiSTerRTG)
  drives); optional A2065 Ethernet and Toccata sound on Zorro II.
* **From Minimig, adapted to the A4000:** floppies, IDE hard disks
  through the HPS, the shared folder (`MiSTer:`), the HRTmon freezer
  cartridge, an extension ROM at `$E00000` for 1 MB Kickstarts.

Bus timing follows a real A4000 + A3640 at 25 MHz, measured with
Copperline's accelprobe. Line fills from chip RAM, motherboard RAM and
Zorro III RAM take what they take on the real machine, within 6%. The
*Fast* bus option drops to the shortest timing the FPGA memories allow.
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) describes the design and
the references it follows (Commodore's chip specifications, WinUAE,
Copperline).

## Status

Work in progress.

* **Working on a DE10-Nano:** AmigaOS 3.2 (A4000 Kickstart 47.115) boots
  from an IDE hard file to Workbench at 25 and 50 MHz, and the shared
  folder's request handshake with Main completes.
* **Simulation:** Kickstart 3.1 (40.70) reaches its insert-disk screen,
  and HRTmon enters and draws its screen over a running Kickstart.
* **56.75 MHz:** depends on the build. The AP68040's longest paths sit at
  the edge of that clock, and a build that misses timing hangs early in
  boot at 56 MHz. 25 MHz is never affected, because the CPU never gets two
  consecutive base-clock cycles at that speed.
* **HRTmon on hardware:** not working yet; it is being debugged.
* **CPU instruction timing:** the AP68040's own instruction timing differs
  from a real 68040's (some loops faster, cache misses and stores slower);
  the board's timing is calibrated, the CPU's is not.

## Installing

1. **Core:** copy an RBF from [`releases/`](releases) to the SD card as
   `Maximig_<date>.rbf`, under `_Computer/` or at the top level. The name
   must start with `Maximig`.
2. **Main:** Main_MiSTer recognises the Minimig family by core name and
   does not know this one yet. Build Main_MiSTer with
   [`main_patch/0001-Add-Maximig-A4000-core-support.patch`](main_patch)
   applied, and install the binary as `/media/fat/MiSTer`. The patch gives
   the core Minimig's HPS support under the name Maximig, the
   `games/Amiga` directory, an A4000 System menu, IDE on by default,
   HRTmon configured for the A4000's IDE, and `KICK4000.ROM` as the
   default Kickstart.
3. **Kickstart:** put an **A4000** Kickstart in `games/Amiga/` as
   `KICK4000.ROM`, or pick one from the menu.

   An A500/A600/A1200 Kickstart starts, but it looks for the IDE
   controller at Gayle's `$DA0000`, so the hard disk is never seen and
   the 16 MB of motherboard RAM is never added. If `KICK4000.ROM` is
   missing, Main falls back to `KICK.ROM`, which is often an A1200 ROM.
4. **HRTmon (optional):** put `HRTMON.ROM` in `games/Amiga/` and enable
   HRTmon in the System menu; F11 (the Amiga's Help key) freezes the
   machine into it.

### The System menu

```
 CPU      : 68040 25MHz (A3640)   (33MHz / 50MHz / 56MHz)
 Bus      : A4000                 (Fast)
 Chipset  : AGA                   (fixed)
 ChipRAM  : 2M                    (fixed)
 Z3 RAM   : none                  (128M / 256M / 384M)
 MB RAM   : none                  (4M / 8M / 16M)
```

### RTG

The RTG board is a Zorro III board (manufacturer `$139C`, product `$30`):
an 8 MB framebuffer at the board's base and the registers at
board + `$800100`.

Minimig's stock `MiSTer.card` is written for Minimig's older RTG, with its
registers hard-coded at `$B80100` and the framebuffer at `$02000000`.
Neither exists on the A4000, and the driver crashes the `MiSTer` monitor
at boot (an illegal instruction, guru `#80000004`).
[`extra/rtg_driver`](extra/rtg_driver) has a version that finds the
Zorro III board through autoconfig; build it with `build.sh` (vasm) and
copy it to `LIBS:Picasso96/MiSTer.card`.

### MMU setups (MMULib)

With MMULib's `68040.library` and an `ENVARC:MMU-Configuration` that
starts with `ClearMMU Memory Blank Motherboard`, every region not listed
afterwards is unmapped. Add the core's windows:

```
SetCacheMode from 0x00A00000 size 0x00100000 Valid IOSpace CacheInhibit
SetCacheMode from 0x00dd4000 0x00002000 Valid IOSpace CacheInhibit
```

The first is HRTmon's cartridge RAM and register mirror. Without it, F11
jumps into an unmapped page and ends in guru `#80000004`. The second is
the shared folder's window.

## Building

```
git clone --recursive https://github.com/apolkosnik/Maximig-AGA_MiSTer
```

Open `Maximig.qpf` in Quartus Prime 17.0 (the MiSTer standard) and
compile; the core is `output_files/Maximig.rbf`.

* **Fitter seed:** the design uses about 89% of the FPGA's logic, and
  whether the 56.75 MHz CPU clock meets timing varies from seed to seed.
  Check `output_files/Maximig.sta.summary` before using a build at 50 or
  56 MHz.
* **AP68040 submodule:** the core needs two Quartus 17.0 fixes on top of
  AP68040's `faster` branch, on branch `maximig-quartus17`. Until that
  branch is on GitHub, a recursive clone cannot check out the pinned
  submodule commit.

The Main side is plain Main_MiSTer with the patch applied, built with the
usual ARM toolchain (`make` with `arm-none-linux-gnueabihf-gcc` on the
path).

## Simulation and tests

[`tb/system`](tb/system) simulates the whole machine with Verilator
(5.x): `a4k_machine` with SDRAM and DDR3 models, and the clocks, the
config words and the uploads that the HPS provides.

```
tb/system/run_tests.sh            # build, then t_board, t_hrtmon_mmu, t_timing
tb/system/obj_tests/Vtb_top --rom KICK4000.ROM --ms 3000 --frames out
```

* **`t_board`** covers Gary, Ramsey, motherboard and chip RAM, the custom
  registers, the CIAs, the autoconfig chain and the RTG board, the IDE
  port and the RTC (12-hour mode included), floating and timed-out
  cycles, a CPU-space bus error, interrupts, the copper and the blitter,
  the RESET instruction, the shared-folder handshake (the bench plays
  Main), the extension ROM, and HRTmon's NMI entry with the vector table
  in fast RAM.
* **`t_hrtmon_mmu`** checks HRTmon's entry with the vector table
  MMU-translated.
* **`t_timing`** runs Copperline's accelprobe rows against the real
  A4000/A3640; `timing_check.py` gates the board's line fills and lists
  every row outside 10%.

`sim_main.cpp` lists the bench's options:

* **Traces:** bus beats, custom-register writes, PCs, FST waveforms.
* **Dumps:** chip RAM, DDR3 long words.
* **Uploads:** a cartridge image, the way Main uploads one, including
  HRTmon's configuration block, and an extension ROM.
* **Keys:** a key press at a given time, for example F11.

The AP68040's own regression is `rtl/AP68040/tb/run_tests.sh`.

### On hardware

A debug build can sample the CPU's PC: add
`set_global_assignment -name VERILOG_MACRO "MAXIMIG_PCSAMPLE=1"` to
`Maximig.qsf` (normal builds leave it out: its DDR3 writes share the
local bus with the CPU). The core then samples the PC about every 72 µs
into a ring of 64 long words at DDR3 `0x27FF6000`, which the MiSTer can read with
`devmem 0x27FF6000 32` (each long word reads byte-reversed). Next to it
are the sample count (`+$100`), and the counts of level-7 interrupt
acknowledges and HRTmon NMI vectors (`+$104`). After an HRTmon entry the
ring stops, so it keeps the first moments of HRTmon's code.

## Licence

GPL v3 (`LICENSE`). The Minimig chipset is GPL v3
(`rtl/minimig/COPYING.minimig`); AP68040 has its own licence, GPL v2
(`rtl/AP68040/LICENSE`).
