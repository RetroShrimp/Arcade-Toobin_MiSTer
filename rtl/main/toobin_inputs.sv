// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// Toobin' control mapping: five direct cabinet buttons per player -> FF8800.
//
// Toobin uses four independent paddle-direction pushbuttons per player plus a
// Throw Can button, which the game also uses as Start (SP-320 sheet 18 and
// the FF8800 switch word, all active-low):
//   bit0 P2 R-oar fwd   bit1 P2 L-oar fwd   bit2 P2 L-oar back  bit3 P2 R-oar back
//   bit4 P1 R-oar fwd   bit5 P1 L-oar fwd   bit6 P1 L-oar back  bit7 P1 R-oar back
//   bit8 P1 throw       bit9 P2 throw       bit15:10 unused (=1)
//
// Keep all five switches independent.  In particular, do not synthesize paddle
// combinations from a D-pad: the original panel permits any combination of the
// four paddle switches, and the control-test screen observes each one directly.

module toobin_inputs
(
	input  logic p1_l_back, p1_r_back, p1_l_fwd, p1_r_fwd, p1_throw_start,
	input  logic p2_l_back, p2_r_back, p2_l_fwd, p2_r_fwd, p2_throw_start,
	output logic [15:0] switches      // FF8800, active-low (1 = not pressed)
);

	// pack active-low (assert = 0)
	assign switches = ~{ 6'b000000,        // [15:10] unused -> 1
	                     p2_throw_start,    // [9]
	                     p1_throw_start,    // [8]
	                     p1_r_back,         // [7]
	                     p1_l_back,         // [6]
	                     p1_l_fwd,          // [5]
	                     p1_r_fwd,          // [4]
	                     p2_r_back,         // [3]
	                     p2_l_back,         // [2]
	                     p2_l_fwd,          // [1]
	                     p2_r_fwd };        // [0]

endmodule
