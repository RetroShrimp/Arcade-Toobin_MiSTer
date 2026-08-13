// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' playfield vertical-scroll counter model.
//
// SP-320 sheet 14 latches BD14:6 as VS8:0 and feeds two cascaded LS163
// counters clocked by /HSYNC.  FF8700 D0 participates in /VRES: a zero written
// during HBLANK reloads the running counter immediately; otherwise the latched
// value becomes the line-zero base at the next frame reset.
//
// The renderer addresses source row = raster_v + effective_offset.  Reloading
// the physical counter to L at raster line V is therefore represented exactly
// by effective_offset = L - V (modulo the 512-line playfield map).

module toobin_vscroll_ctrl
(
	input  logic       clk,
	input  logic       reset,
	input  logic       frame_start,
	input  logic       restart,
	input  logic [8:0] vpos,
	input  logic [8:0] scroll_latch,
	output logic [8:0] effective_offset
);
	always_ff @(posedge clk) begin
		if (reset) effective_offset <= 9'd0;
		else if (restart)     effective_offset <= scroll_latch - vpos;
		else if (frame_start) effective_offset <= scroll_latch;
	end
endmodule
