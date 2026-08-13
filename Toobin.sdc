derive_pll_clocks
derive_clock_uncertainty

# ============================================================================
#  Toobin core timing constraints
#
#  clk_sys = 64 MHz (emu|pll outclk_0).  The whole core is a SINGLE clk_sys
#  domain with clock ENABLES -- there are no other fabric clocks:
#     68010 (u_cpu)                advances on ce_cpu   = clk_sys / 8   (8 MHz)
#     JSA sound: 6502 on ce ~ clk_sys / 36; YM/POKEY use separate enables
#     video display pipeline       on ce_pix = clk_sys / 4   (16 MHz)
#  Only the SDRAM/gfx datapath (u_sdram, u_gfx, the pf-render tile-fetch FSM and
#  the MO engine) runs at the FULL clk_sys rate and must genuinely meet 64 MHz.
#
#  Without multicycle constraints the analyzer holds the big, slow CE-gated
#  logic (notably the 68010 and 6502) to the full 15.6 ns period, which is the
#  bulk of the reported negative slack and is FALSE for registers proven to
#  share one clock enable.  Relax the INTRA-block reg->reg paths only: a
#  CE-gated block's *outputs* to full-rate logic stay single-cycle (correct --
#  a full-rate sampler may latch a held CPU output on any edge).
# ============================================================================

# ---- 68010 kernel: ce_cpu = clk_sys/8 -> kernel paths have 8 cycles -------
# TG68K's cpu1 kernel and its ALU contain rising-edge state whose retained
# dynamic non-reset updates are qualified by clkena_in/clkena_lw; both enables
# include cpu_cen.  (The source-level unguarded use_VBR_Stackframe assignment is
# a CPU-generic constant and is synthesized away.)  Keep the exception inside
# that kernel only.  In particular, do NOT
# cover TG68K.vhd's wrapper: it contains a free-running sync counter plus the
# mixed rising/falling-edge bus state machines.  Those wrapper and half-cycle
# paths must be analyzed at their real clk_sys timing.
set_multicycle_path -setup -end 8 -from [get_registers {*u_cpu|u_tg68k|cpu1|*}] -to [get_registers {*u_cpu|u_tg68k|cpu1|*}]
set_multicycle_path -hold  -end 7 -from [get_registers {*u_cpu|u_tg68k|cpu1|*}] -to [get_registers {*u_cpu|u_tg68k|cpu1|*}]

# ---- JSA 6502 only -----------------------------------------------------------
# Every sequential process in T65.vhd is gated by the same Enable input.  Limit
# the exception to that core.  The former *u_jsa|* collection also covered
# full-rate mailbox/mixer state, POKEY pin sampling, and jt51 timer state that
# does not uniformly share a CE; those paths must remain ordinary single-cycle
# clk_sys paths.  Eight cycles is deliberately conservative versus ce_6502's
# minimum 35-clock interval at 64 MHz.
set_multicycle_path -setup -end 8 -from [get_registers {*u_jsa|u_cpu|u_t65|*}] -to [get_registers {*u_jsa|u_cpu|u_t65|*}]
set_multicycle_path -hold  -end 7 -from [get_registers {*u_jsa|u_cpu|u_t65|*}] -to [get_registers {*u_jsa|u_cpu|u_t65|*}]

# ---- JT51 LFO modulation into phase generator -------------------------------
# jt51 drives the LFO PM value, channel frequency/modulation outputs, operator
# DT2 output, and phase-generator keycode_II destination from the same cen_p1
# enable.  At 64 MHz successive cen_p1 pulses are never closer than 35 fabric
# clocks, so these data cannot be launched and captured on adjacent clk_sys
# edges.  Keep the exception on the exact source blocks and destination rather
# than relaxing all of jt51: its timer flag and wrapper state do not uniformly
# share this enable.  Two clocks is deliberately conservative and is paired
# with the standard N-1 hold adjustment.
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_lfo|pm[*]}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_lfo|pm[*]}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

# ============================================================================
#  SDRAM external I/O timing (MT48LC16M16 class, CL2, 64 MHz controller).
#  SDRAM_CLK is PLL outclk_2 (64 MHz, -180 deg of clk_sys) wired straight to the
#  pin -- a clean phase-controlled clock, so these delays can actually close.
#  Values from the MT48LC16M16 datasheet (same chip as the sibling cores).
#  If Quartus reports the -source PLL node cannot be found, open Timing Analyzer
#  -> Report Clocks and substitute the actual outclk_2 ...general[2]...divclk path;
#  if it does not apply the SDRAM I/O just falls back to unconstrained (no break).
# ============================================================================
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# Read capture: data access time tAC = 6.0 ns (max), output hold tOH = 2.5 ns (min).
set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

# Command/address/data launch: input setup tIS = 1.5 ns (max), hold tIH = 0.8 ns (min).
set_output_delay -clock SDRAM_CLK -max  1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]

# The controller launches/captures on clk_sys (outclk_0); SDRAM_CLK is 180 deg from
# it, so allow the read the proper (next) capture edge instead of the half-cycle one.
# Endpoints must be CLOCK collections (get_clocks), not pins.  get_clocks does Tcl
# string-matching where [..] is a char class, so match the literal "general[0]" with
# "?" wildcards; the *|pll|pll_inst| prefix disambiguates it from the audio PLL.
set_multicycle_path -setup -end 2 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 1 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
