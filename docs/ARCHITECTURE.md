# Maximig: an Amiga 4000/040 for MiSTer

The core models a Commodore Amiga 4000 with the A3640 CPU card: a 68040 on
the CPU slot, the A4000 motherboard's local bus with its bus controllers,
and the AGA chipset.  It is built from:

* [AP68040](https://github.com/apolkosnik/AP68040), branch `faster`, as a
  submodule in `rtl/AP68040`: a pin-level MC68040 (caches, MMU, FPU, the
  real 68040 bus).
* The [MiSTer Minimig](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer)
  chipset (Alice/Lisa/Paula/8520s, userio, the HPS protocol), copied into
  `rtl/minimig` (upstream commit in `rtl/minimig/UPSTREAM.txt`), with the
  OCS/ECS, CD32, CDTV, Akiko, Gayle and 68000-68030 paths removed.
* New A4000 motherboard logic in `rtl/a4000`.

Everything below the 68040 is A4000-specific; nothing of Minimig's 68020
`cpu_wrapper`, `fastchip`, `memory_router` or Gayle is used.

## References, in order of authority

1. Real hardware measurements.  Copperline's
   `timing-test/accelprobe.asm` header records an A4000 with a Commodore
   A3640 (68040 at 25 MHz, no CPU-card RAM): the per-region read/write
   rates used to calibrate this core's bus timing (section *Timing*).
2. Commodore's chip specifications (amiga_replacement_project):
   RAMSEY 390541, FAT GARY 390540, FAT BUSTER 390539, Bridgette 391380,
   the A4000/A3000 Hardware Developer Notes v1.11 and the Zorro III
   specification.
3. WinUAE (the user's Unix port): `gayle.cpp` (A4000 IDE, motherboard
   resources), `memory.cpp` (map, Gary timeout), `expansion.cpp`
   (autoconfig).
4. Copperline's `docs/internals/peripherals.md` (Gary/Ramsey mirrors, the
   A4000 IDE, the RP5C01).

## Clocks

One PLL (Minimig's fractional PLL, PAL/NTSC reconfigured) gives three
edge-aligned clocks:

| clock | PAL | NTSC | what runs on it |
|---|---:|---:|---|
| `clk_114` | 113.50 MHz | 114.55 MHz | SDRAM controller, DDR3 port, video out |
| `clk_57`  |  56.75 MHz |  57.27 MHz | the CPU card and the motherboard local bus |
| `clk_sys` |  28.38 MHz |  28.64 MHz | the chipset (Alice, Lisa, Paula, CIAs), IDE, RTC, Zorro II boards |

The 68040 runs on `clk_cpu`, `clk_57` through a clock-control block
(`cyclonev_clkena`, enable registered on the falling edge): a phase
accumulator drops base-clock pulses so the CPU sees 25, 33, 40, 50 or 56.75
MHz on average.  The CPU's bus is 1:1 with its own clock (`bclk_en` = 1), so
`clk_cpu` is both PCLK-rate pipeline clock and BCLK; on the real A3640 the
68040's BCLK is 25 MHz and is also the motherboard's CPUCLK.  The local bus
logic runs on `clk_57` and changes the signals the CPU samples only in the
base cycles that end on a CPU clock edge (`cpu_ce`), so CPU and motherboard
form one synchronous design and every bus timing is counted in CPU clocks
-- exactly as Ramsey, Buster and Gary count CPUCLK.

## The CPU card (`a4k_a3640`)

`ap68040` (its bus as the MC68040 user's manual describes it) and
`a4k_a3640`, the card's bus converter, which is the 68040's only bus
slave (both instantiated in `a4k_machine`):

* Each transfer (byte, word, long, or a line as four beats with A3:A2
  wrapping) becomes one local-bus beat at a time.
* Interrupt acknowledge cycles are answered with TA + AVEC (Gary
  autovectors every level on the A3000/A4000).
* TCI comes from the motherboard decode (cache-inhibited I/O regions).
* The card's synchronisation overhead between the 68040 bus and the
  68030-style motherboard bus is a number of CPU clocks before and after
  each beat (`pre`/`post`); the calibration (*Timing*) put the whole of
  each region's cost into the local bus's per-region cycle counts, so both
  are 0.
* No other master exists on the CPU bus (no Zorro DMA masters are
  modelled), so the 68040 owns the bus permanently; chipset DMA into chip
  RAM is not snooped, as on the real machine (the OS flushes caches around
  DMA).

## The local bus (`a4k_lbus`): Gary, Ramsey, Budgie, Buster

One beat at a time arrives from the card: 32-bit address, byte enables,
read/write, write data.  The decoder (Fat Gary's role) selects a target:

| address | target | port, caching |
|---|---|---|
| `$00000000-$001FFFFF` | chip RAM (ROM for reads while OVL) | Budgie -> chip bus, 32 bit, cacheable |
| `$00200000-$009FFFFF` | Zorro II memory space | Buster (no boards: the cycle floats) |
| `$00A00000-$00B7FFFF` | Zorro II I/O space | Buster (no boards: the cycle floats), TCI |
| `$00BFD000/$00BFE001` | CIA-B / CIA-A | Budgie, E-clock synchronised, TCI |
| `$00C00000-$00CFFFFF` | chip register mirror (Fat Gary) | Budgie, TCI |
| `$00DC0000-$00DCFFFF` | RP5C01 real-time clock | I/O bus, TCI |
| `$00DD2000-$00DD3FFF` | A4000 IDE | I/O bus, TCI |
| `$00DE0000-$00DE7FFF` | Gary and Ramsey registers | local, TCI |
| `$00DF0000-$00DFFFFF` | custom registers | Budgie, TCI |
| `$00E80000-$00E8FFFF` | Zorro II autoconfig | Buster, TCI |
| `$00E90000-$00EFFFFF` | Zorro II I/O boards (A2065, Toccata) | Buster -> I/O bus, TCI; elsewhere floats |
| `$00F00000-$00F7FFFF` | (cartridge / diagnostic ROM space) | floats |
| `$00F80000-$00FFFFFF` | Kickstart ROM | SDRAM, Gary ROM timing, cacheable |
| `$07000000-$07FFFFFF` | motherboard fast RAM (Ramsey) | SDRAM, Ramsey timing, cacheable |
| `$10000000-$7FFFFFFF` | Zorro III boards (fast RAM, RTG) | DDR3, Buster Z3 timing |
| `$FF000000-$FFFFFFFF` | Zorro III autoconfig | Buster, TCI |

Unmapped addresses below `$B80000` and in `$E80000-$F7FFFF` float: the
cycle ends after Buster's Zorro II autoconfig-speed cycle with the data
lines pulled up (all ones), WinUAE's `gary_nonrange`.  This matters for
speed: Kickstart's ROMtag scan reads `$F00000-$F7FFFF` word by word, and
at 9 us a word that scan alone would take over a second.  Everything else
in the 24-bit space that nothing decodes is answered by Gary's bus
timeout: after 32 C1 periods (~9 us) with a DSACK (data reads as all
ones), or, once software selects BERR mode, after ~250 ms with a bus
error; timeouts never apply to chip RAM and chip registers.  A disabled
timeout (`$DE0001` bit 7) leaves the cycle unanswered, as Fat Gary would.

Writes to motherboard RAM and Zorro III RAM are posted: the beat ends
after its region's cycle time while the memory write goes on behind it,
one write deep, the next memory access waiting for it.  A line fill from
motherboard RAM reads the beat's SDRAM quad word and then fetches the
line's other quad word behind it into a one-line buffer; one from Zorro
III RAM reads the whole 16-byte line in one DDR3 burst into its buffer.
The line's later beats are served from the buffers.  Neither shortens a
beat below its calibrated time: each beat's clock count runs from the
beat's start whatever the memory did.

### Gary and Ramsey registers (`$DE0000` page)

As WinUAE `mbres_read`/`mbres_write` and the RAMSEY/FAT GARY
specifications: only A1:A0 and A7:A6 decode, the layout mirrors every
$100 in `$DE0000-$DE7FFF`.

| address | register |
|---|---|
| `$DE0000` bit 7 | Gary TIMEOUT mode (0 DSACK, 1 BERR) |
| `$DE0001` bit 7 | Gary TOENB (0 timeout enabled, 1 disabled) |
| `$DE0002` bit 7 | Gary COLDBOOT (power-up detect, read/write) |
| `$DE0003` | Ramsey control: page, burst, wrap, RAM size, skip, refresh rate, test |
| `$DE0043` | Ramsey version, `$0F` (Ramsey-07) |

Other bits of the Gary bytes read as one; other lane-3 bytes read `$FF`.
Ramsey's control register changes take effect at the next refresh (a
write is not visible on read-back until then), as the specification
states and Kickstart's read-back loop expects.

### Ramsey timing (motherboard fast RAM)

Per the RAMSEY specification at 25 MHz: standard mode 5 clocks per access
(4 with the Skip bit), page mode 3 clocks on a page hit and 7 on a miss,
68030 burst beats 2 clocks.  RAM size and population follow the RAS map:
1M x 4 SIMMs give 4 MB banks at `$07000000`, `$07400000`, `$07800000`,
`$07C00000`; fitted memory fills from the top down, so 4 MB is
`$07C00000-$07FFFFFF` and 16 MB is the whole window.  Unfitted banks
answer (Ramsey decodes the whole window) but hold nothing.

### Budgie (the chip bus side)

A CPU access to chip RAM, the custom registers or a CIA runs on Alice's
CPU port at the 7 MHz chip-bus rate: a long word to chip RAM is one 32-bit
chip-bus cycle (the AGA CPU path), a long word to a 16-bit register is two
cycles.  CIA cycles synchronise to the E clock (Minimig's cycle-exact CIA
timing).  Budgie adds the motherboard-to-chip-bus synchronisation.

### Buster (Zorro)

Autoconfig at `$E80000` (Zorro II nibble layout; Kickstart 3.1 configures
Zorro III boards here) and at `$FF000000` (Zorro III layout: register pairs
at +$000/+$100).  The chain:

1. Zorro III fast RAM (0, 128, 256 or 384 MB, in DDR3).
2. The Zorro III RTG board, mfr `$139C` product `$30`, 16 MB: framebuffer
   at board+0 (8 MB, DDR3 at `0x27000000`, Amiga byte order), `rtg.v`
   registers and CLUT at board+`$800000` -- the board MiSTer.card and
   ZZMiSTerRTG drive.  The register half and the ZZMiSTerRTG mailbox
   (board+`$7C0000`-`$7FFFFF`) answer with TCI (Zorro III CINH), so the
   68040 never caches what the ARM writes behind its back.
3. A2065 Ethernet (Zorro II, Commodore `$0202/$70`), optional.
4. Toccata (Zorro II), optional.

Zorro II cycles run at the 7 MHz Zorro II rate (16 bits per cycle); Zorro
III cycles take Buster's FCS/DTACK cycle plus the board's own wait states
(calibrated, *Timing*).  The Zorro III bases are written as words at
`$44`; every board here is 16 MB aligned or larger, so the A23-A16 byte
(`$48`, before `$44`) is taken but not needed.

## Memory placement

| SDRAM (16-bit, `clk_114`) | contents |
|---|---|
| `0x0000000-0x01FFFFF` | chip RAM, 2 MB |
| `0x0780000-0x07FFFFF` | Kickstart ROM, 512 KB (written by the HPS through the chip bus with the CPU halted, as on Minimig) |
| `0x1000000-0x1FFFFFF` | motherboard fast RAM, up to 16 MB |

| DDR3 (physical) | contents |
|---|---|
| `0x20000000-0x207FFFFF` | MiSTer scaler (sys) |
| `0x27000000-0x277FFFFF` | RTG framebuffer |
| `0x28000000-0x2FFFFFFF` | Zorro III fast RAM board, 128 MB |
| `0x30000000-0x3FFFFFFF` | Zorro III fast RAM board, 256 MB |

## Timing (A4000 bus mode)

Real-hardware targets (A3640 at 25 MHz, accelprobe rows; E-clock ticks
converted to time):

| row | access | real A3640 |
|---|---|---:|
| 16 | chip RAM `move.l` read, stride 16 (line fill) | 3.41 us / line |
| 17 | chip RAM `move.l` write | 856 ns |
| 19 | motherboard RAM read, stride 16 | 1.30 us / line |
| 20 | motherboard RAM write | 367 ns |
| 22 | Zorro III (ZZ9000) read, stride 16 | 2.13 us / line |
| 23 | Zorro III (ZZ9000) write | 523 ns |

The bus-timing option selects these (A4000) or the shortest the FPGA
memories allow (Fast).

`tb/asm/t_timing.s` runs accelprobe's loops on the full-system
simulation; `tb/system/timing_check.py` compares them.  The board's part,
the time a line fill keeps the bus (four beats, from the local-bus beat
trace), against the real rows' time per line:

| row | region | core line fill | real per line | ratio |
|---|---|---:|---:|---:|
| 16 | chip RAM | 3.409 us | 3.415 us | 1.00 |
| 19 | motherboard RAM | 1.264 us | 1.304 us | 0.97 |
| 22 | Zorro III RAM | 1.997 us | 2.132 us | 0.94 |

The rows as a whole are further off, and that is the CPU, not the board:
AP68040 spends 0.56-0.74 us between one line fill's last beat and the
next miss's first (a real 68040 a few clocks), about 10 CPU clocks after
each write-through store's TA before the next bus cycle, and runs the
pure CPU loops (`dbra`, `mulu`, `bsr`/`rts`) two to four times faster
than a real 68040 at 25 MHz (rows 6-13), while `movem`, `cpushl` and
exception stacking to fast RAM run slower (rows 10, 14, 15).  The check
gates the board's line fills (10%) and lists every row outside 10%;
`--strict` gates the rows too.

## Simulation and tests

`tb/system` is a Verilator model of the whole machine (`a4k_machine` with
an SDRAM and a DDR3 model; the clocks, the HPS's config words and ROM
upload as the real HPS does them).  `tb/system/run_tests.sh` builds it and
runs the regression:

* `t_board`: Gary, Ramsey, motherboard and chip RAM lanes, the custom
  registers, CIA-A, the autoconfig chain and the RTG board, the IDE port
  and the RTC, floating and timed-out cycles, a CPU-space bus error, an
  autovectored interrupt, chipset DMA (the copper started by COPJMP1,
  COPJMP2 and the start of the frame, and two blits), and the RESET
  instruction (Paula and CIA-A reset, the overlay back).
* `t_timing` with `timing_check.py` (*Timing*).

`sim_main.cpp` also boots a Kickstart image (`--rom`), writes frames
(`--frames`), traces local-bus beats, custom-register writes and FST
waveforms, and dumps chip RAM (`--dumpchip`).

Minimig's chipset had registers assigned with blocking `=` in clocked
blocks and read by other blocks (the copper's COPJMP strobes, the floppy
FIFOs' outputs, some userio state).  Synthesis builds the same flip-flops
either way, but a simulator may run the reading block first: Verilator
lost the copper's pointer reload to it, so the copper never ran.  They
are `<=` here (`rtl/minimig/UPSTREAM.txt`).

## HPS interface

The core speaks Minimig's HPS protocol (`hps_ext`, `userio`): kickstart
upload, floppy (ADF, DD), IDE hard disks and ATAPI through the HPS, the
config words, the RTG framebuffer, A2065 Ethernet.  Main_MiSTer recognises
the Minimig family by core name; `main_patch/` adds `Maximig` to it with an
A4000 System menu.  The config words are interpreted as:

| config | bits | meaning here |
|---|---|---|
| chipset | N | NTSC (everything else: always AGA) |
| CPU | TT | 68040 clock: 0 25 MHz, 1 33 MHz, 2 50 MHz, 3 56.75 MHz |
| CPU | P (bit 5) | bus timing: 0 A4000, 1 Fast |
| memory | SS | motherboard RAM: none, 4, 8, 16 MB |
| memory | FF, bit 7 | Zorro III RAM: none, 128, 128, 128, 256, 384 MB |
| memory | CC | ignored: 2 MB chip RAM |
