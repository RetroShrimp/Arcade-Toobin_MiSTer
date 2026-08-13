// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' 68010 interrupt encoder + watchdog.
//
// Interrupts (MAME toobin.cpp, set_interrupt_mixer(false)):
//   scanline compare -> IPL0 pin (weight 1); latched, set by the video
//     `scanline_match` pulse, cleared by a write to FF83C0 (irqack).
//   sound board      -> IPL1 pin (weight 2); level from the sound-comm main_irq.
// With the mixer off the pins combine as a binary level: scanline=1, sound=2,
// both=3. TG68K takes IPL[2:0] active-low (level = ~IPL, "111" = none).
//
// Watchdog (SP-320 sheet 2, 8L LS90): /VSYNC clocks a decade counter.  QD is
// RESET, so reset is asserted at counts 8 and 9 and releases when the counter
// wraps to 0.  A write to FF8000 services (clears) the counter.
//
// Source: Atari SP-320 schematics; MAME's toobin.cpp; the System 1 core's
// TG68K IPL convention (rtl/lib/TG68K/TG68K.vhd).

module toobin_irq_wd
(
	input  logic       clk,
	input  logic       reset,

	// interrupt sources
	input  logic       scanline_match,  // 1-clk pulse: raster reached FF8340 line
	input  logic       irqack_wr,       // 1-clk pulse: CPU wrote FF83C0
	input  logic       sound_irq,       // level: sound-comm main_irq (IPL1)

	// watchdog
	input  logic       vsync_start,     // 1-clk pulse at assertion edge of /VSYNC
	input  logic       wdog_clr,        // 1-clk pulse: CPU wrote FF8000

	output logic [2:0] ipl,             // -> TG68K IPL (active-low, "111"=none)
	output logic       scanline_pending,
	output logic       watchdog_reset
);

	logic [3:0] wdog_ctr;

	// scanline (IPL0) latch: set on match, cleared by the ack write. A coincident
	// match+ack keeps it pending (a new frame's request is not lost).
	always_ff @(posedge clk) begin
		if (reset)                scanline_pending <= 1'b0;
		else if (scanline_match)  scanline_pending <= 1'b1;
		else if (irqack_wr)       scanline_pending <= 1'b0;
	end

	// binary-combined level, then active-low encode for TG68K
	// level[1:0] = {sound_irq, scanline_pending}
	always_comb ipl = ~{1'b0, sound_irq, scanline_pending};

	// 74LS90 decade behavior: FF8000 clears to zero; /VSYNC advances 0..9.
	// QD is high for counts 8 and 9, giving the physical two-frame reset window.
	always_ff @(posedge clk) begin
		if (reset)             wdog_ctr <= 4'd0;
		else if (wdog_clr)     wdog_ctr <= 4'd0;
		else if (vsync_start)   wdog_ctr <= (wdog_ctr == 4'd9) ? 4'd0 : wdog_ctr + 4'd1;
	end
	assign watchdog_reset = wdog_ctr[3];

endmodule
