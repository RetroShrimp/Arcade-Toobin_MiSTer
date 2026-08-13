// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' playfield tile 4bpp row decoder (pure) — the decode half of tile_gfx,
// separated from the embedded ROM so pf_render can fetch tile rows from SDRAM.
//
// One 8x8 tile row = 4 bytes: A,B from the first ROM half (planes 2,3), C,D from
// the second half (planes 0,1), per MAME pflayout {RGN_FRAC(1,2)+0,+4,0,4}, plane0
// = MSB.  Pixel x0-3 = {C[7-x],C[3-x],A[7-x],A[3-x]}; x4-7 = {D[11-x],D[7-x],
// B[11-x],B[7-x]}.  (Identical bit-mapping to the embedded tile_gfx.)

module toobin_tile_dec
(
	input  logic [7:0] A,       // first-half byte 0  (planes 2,3, pixels 0-3)
	input  logic [7:0] B,       // first-half byte 1  (pixels 4-7)
	input  logic [7:0] C,       // second-half byte 0 (planes 0,1, pixels 0-3)
	input  logic [7:0] D,       // second-half byte 1 (pixels 4-7)
	output logic [31:0] pixrow  // 8 pixels x 4bpp (pix0=[3:0] .. pix7=[31:28])
);

	assign pixrow = {
		{D[4],D[0],B[4],B[0]}, {D[5],D[1],B[5],B[1]}, {D[6],D[2],B[6],B[2]}, {D[7],D[3],B[7],B[3]},
		{C[4],C[0],A[4],A[0]}, {C[5],C[1],A[5],A[1]}, {C[6],C[2],A[6],A[2]}, {C[7],C[3],A[7],A[3]} };

endmodule
