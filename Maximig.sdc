derive_pll_clocks
derive_clock_uncertainty

# The PLL's outputs: counter[0] clk_114 (SDRAM, DDR3, video), counter[1]
# clk_sys (the chipset, 28 MHz), counter[2] clk_57 (the CPU card and the
# local bus).  The CPU's own clock is clk_57 through a clock-control block
# whose enable drops pulses (a4k_cpuclk): TimeQuest carries clk_57 through
# it, so every CPU <-> local bus path is an ordinary clk_57 path.

# The chip bus into the SDRAM slot (Minimig's relaxations): the chipset's
# address, data and strobes are launched by the 28 MHz logic and taken at
# the start of the SDRAM's 7 MHz slot, two clk_114 cycles later.
set_multicycle_path -from {emu|machine|amiga_clk|cck*} -to {emu|machine|sdram|*} -setup 2
set_multicycle_path -from {emu|machine|amiga_clk|cck*} -to {emu|machine|sdram|*} -hold 1
set_multicycle_path -from {emu|machine|chipset|*} -to {emu|machine|sdram|*} -setup 2
set_multicycle_path -from {emu|machine|chipset|*} -to {emu|machine|sdram|*} -hold 1
set_multicycle_path -from {emu|machine|amiga_clk|c1*} -to {emu|machine|sdram|*} -setup 2
set_multicycle_path -from {emu|machine|amiga_clk|c1*} -to {emu|machine|sdram|*} -hold 1
set_multicycle_path -from {emu|machine|amiga_clk|c3*} -to {emu|machine|sdram|*} -setup 2
set_multicycle_path -from {emu|machine|amiga_clk|c3*} -to {emu|machine|sdram|*} -hold 1
# Budgie's long-word write data (chipWR2) is held from the start of the
# chip-bus cycle to its end, many slots
set_multicycle_path -from {emu|machine|budgie|cpu_dout2*} -to {emu|machine|sdram|*} -setup 2
set_multicycle_path -from {emu|machine|budgie|cpu_dout2*} -to {emu|machine|sdram|*} -hold 1

# configuration words: written while the machine is in reset
set_false_path -from {emu|machine|chipset|USERIO1|cpu_config*}
set_false_path -from {emu|machine|chipset|USERIO1|ide_config*}
set_false_path -from {emu|machine|chipset|USERIO1|memory_config*}
set_false_path -from {emu|machine|chipset|USERIO1|chipset_config*}
set_false_path -from {emu|machine|chipset|CPU1|halt}
set_false_path -from {emu|machine|cpu_speed*}

# the video path (as Minimig)
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 1
