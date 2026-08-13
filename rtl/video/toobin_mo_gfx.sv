// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' motion-object (sprite) 4bpp row decoder.
//
// MAME `molayout`: 16x16, 4bpp, RGN_FRAC(1,2) (sprites region 2 MB => 1 MB halves).
// planes {RGN_FRAC(1,2)+0, RGN_FRAC(1,2)+4, 0, 4} (plane0=MSB), y*32, x-offsets
// {0,1,2,3, 8,9,10,11, 16,17,18,19, 24,25,26,27}.  Each row = 32 bits = 4 bytes/half;
// each char = 64 bytes/half (16 rows).  Char T row y: first half at T*64+y*4 (+0..3),
// second half at 0x100000 + T*64 + y*4 (+0..3).
//
// This is a PURE decoder over one row's 8 fetched bytes (the 2 MB ROM is SDRAM-
// resident in the real core, streamed in): fh_row = {F3,F2,F1,F0}, sh_row = {S3,..,S0}
// with byte j = *_row[j*8 +: 8], MSB-first bits.  Emits 16 pixels x 4bpp.
//
// Pixel x (group g=x/4, sub i=x%4):
//   pix = { sh[g][7-i], sh[g][3-i], fh[g][7-i], fh[g][3-i] }  (plane0=MSB .. plane3=LSB)

module toobin_mo_gfx
(
	input  logic [31:0] fh_row,      // first-half 4 bytes of the sprite row (planes 2,3)
	input  logic [31:0] sh_row,      // second-half 4 bytes (planes 0,1)
	output logic [63:0] pixrow       // 16 pixels x 4bpp (pix0=[3:0] .. pix15=[63:60])
);

	// g = x>>2 (byte-group 0..3), i = x&3 (sub-pixel 0..3), inlined for iverilog.
	always_comb begin
		for (int x = 0; x < 16; x++)
			pixrow[x*4 +: 4] = {
				sh_row[(x>>2)*8 + 7 - (x&3)], sh_row[(x>>2)*8 + 3 - (x&3)],
				fh_row[(x>>2)*8 + 7 - (x&3)], fh_row[(x>>2)*8 + 3 - (x&3)] };
	end

endmodule
