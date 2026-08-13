// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' pixel priority / compositor.
//
// Functional form of MAME toobin.cpp screen_update():
//   pix = playfield_index;
//   if (mo_opaque && (!pf_category || !(pf_index & 8)))  pix = mo_index;
//   if (alpha_opaque)                                    pix = alpha_index;   // alpha on top
// i.e. a non-transparent motion-object pixel wins UNLESS the playfield pixel is
// high-priority (category != 0) AND its pen bit 3 is set; the alpha layer is
// always drawn last. (MAME notes the exact PAL equation is unverified; this is
// the functional model, pending a fuse map for PAL 7E on sheet 16.)

module toobin_priority
(
	input  logic [9:0] pf_idx,      // playfield palette index (base 0)
	input  logic [1:0] pf_cat,      // playfield category / priority (0-3)
	input  logic       pf_pen3,     // playfield pen bit 3  (pf_idx & 8)
	input  logic [9:0] mo_idx,      // motion-object palette index (base 256)
	input  logic [1:0] mo_pri,      // preserved PCB LBPRI1:0; PAL equation still unresolved
	input  logic       mo_opaque,   // motion-object pixel not transparent
	input  logic [9:0] al_idx,      // alphanumerics palette index (base 512)
	input  logic       al_opaque,   // alpha pixel not transparent
	output logic [9:0] pen          // final palette index
);

	always_comb begin
		pen = pf_idx;
		if (mo_opaque && ((pf_cat == 2'd0) || !pf_pen3)) pen = mo_idx;
		if (al_opaque)                                   pen = al_idx;
	end

	// Sheet 16 exposes LBPRI1:0 to PAL 7E, but no fuse map/truth table is
	// available. Preserve the bits at this boundary without guessing an equation.
	wire unused_mo_pri = &{1'b0, mo_pri};

endmodule
