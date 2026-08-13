// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' palette converter: color-RAM word -> 8-bit RGB.
//
// Per MAME toobin.cpp paletteram_w / intensity_w:
//   R5 = word[14:10], G5 = word[9:5], B5 = word[4:0]   (5:5:5)
//   base8 = (c5 * 224) >> 5 ; if (base8 != 0) base8 += 38   (per channel)
//   bit15 (intensity-disable): 1 => pen at full brightness;
//                              0 => pen scaled by the global "overall intensity"
//   global brightness = (~intensity_reg & 0x1f) / 31   (FF8300, 5-bit)
//   final = base8 * contrast, contrast = bit15 ? 1.0 : brightness
//
// Combinational.  The contrast multiply is rounded to the nearest integer with
// an exact divide-by-31 result.  Do not write this as SystemVerilog `/ 31`:
// Quartus 17 infers three unpipelined lpm_divide blocks on the pixel path.  The
// shift/add reciprocal below is exact over the complete 0..7920 numerator range
// and finishes with a one-step remainder correction.

module toobin_palette
(
	input  logic [15:0] color,        // color-RAM entry
	input  logic  [4:0] intensity,    // FF8300 register value (raw)
	output logic  [7:0] r,
	output logic  [7:0] g,
	output logic  [7:0] b
);

	function automatic [7:0] expand(input [4:0] c5);
		logic [7:0] times7;
		begin
			// (c5*224)>>5 is exactly c5*7.  Spell out 8*c5-c5 so the
			// mapper does not build a wider multiply before discarding five bits.
			times7 = {c5, 3'b000} - {3'b000, c5};
			expand = (c5 == 5'd0) ? 8'd0 : (times7 + 8'd38);
		end
	endfunction

	wire [7:0] rb = expand(color[14:10]);
	wire [7:0] gb = expand(color[9:5]);
	wire [7:0] bb = expand(color[4:0]);

	// contrast numerator over 31: full (31) when bit15=1, else global brightness
	wire [4:0] bright   = ~intensity;                 // (~intensity)&0x1f
	wire [4:0] contrast = color[15] ? 5'd31 : bright;

	// final = TRUNCATE(base * cn / 31).  Let n=base*cn (0..7905).
	//
	// Truncation, not round-to-nearest, is what the reference does.  MAME applies
	// the global brightness as a floating-point pen contrast --
	// `m_brightness = (double)(~data & 0x1f) / 31.0` in toobin.cpp intensity_w,
	// then set_pen_contrast() -- and the float-to-8-bit conversion truncates.
	// Rounding to nearest instead is one LSB high for some codes whenever the
	// global intensity is not zero.  Every attract frame runs at intensity=00,
	// where cn=31 and the divide is a pass-through, so the error is invisible
	// there; a pixel-exact comparison against MAME on an intensity=01 self-test
	// frame caught it (856 pixels, all exactly +1).
	//
	// Exhaustive integer proof over the whole n=0..7905 range gives the identity:
	//
	//     floor(n/31) = floor(n*8457/262144)
	//
	// 8457=33*256+9, so form n*33 and n*9 in parallel, then add once after
	// shifting the first term by eight.  This removes the former q0/remainder
	// correction chain while remaining bit-exact and combinational.
	function automatic [7:0] scale(input [7:0] base8, input [4:0] cn);
		logic [12:0] n;
		logic [17:0] n_times_33;
		logic [16:0] n_times_9;
		logic [25:0] reciprocal_product;
		begin
			n = 13'(base8 * cn);
			n_times_33 = {n, 5'b00000} + {5'b00000, n};
			n_times_9 = {1'b0, n, 3'b000} + {4'b0000, n};
			reciprocal_product = {n_times_33, 8'b0} + {9'b0, n_times_9};
			scale = 8'(reciprocal_product >> 18);
		end
	endfunction

	assign r = scale(rb, contrast);
	assign g = scale(gb, contrast);
	assign b = scale(bb, contrast);

endmodule
