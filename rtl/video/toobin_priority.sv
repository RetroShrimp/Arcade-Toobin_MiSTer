// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' pixel priority / compositor.
//
// This is the real PAL 7E equation, not a functional approximation.
//
// 136061-1151 (PAL16L8A at 7E) was bruteforced by Caius and tested on a board by
// gamefixer; the JEDEC is on PLD Archive as `Toobin_136061-1151`, dated
// 07/10/2019. Decoded with MAME's jedutil as a gal16v8: simple mode, active-low
// outputs, only pins 13/14 driven. Those two pins are the shared SB/SA select
// rails of the five 74F153 muxes that build the colour-RAM address (pin14 ->
// F153 pin 2 = B/msb, pin13 -> F153 pin 14 = A/lsb), whose data inputs are
// C0=playfield, C1=motion object, C2=alpha, C3=CPU BA10:1:
//
//   CRAM asserted                                  -> C3  CPU
//   else ANPIX1:0 != 0                             -> C2  alpha
//   else MO pen != 0 and !(PFPRI_sel & !LBPRI_sel) -> C1  motion object
//   else                                           -> C0  playfield
//
//   LBPRI_sel = LBPIX3  ? LBPRI1  : LBPRI0
//   PFPRI_sel = PFPIX3D ? PFPRI1D : PFPRI0D
//
// The C3 case is absent here because our colour RAM is dual-ported -- the CPU has
// its own port and never has to steal the display's mux cycle.
//
// Two structural differences from MAME's model (toobin.cpp screen_update, which
// notes its own merge is unverified), each confirmed against all 1024 fuse
// vectors:  (a) a layer's pen bit 3 SELECTS which of that layer's two priority
// bits is compared -- MAME instead treats PF pen bit 3 as a gate that must be set
// before the playfield may cover a motion object;  (b) LBPRI1:0 is live, so a
// motion object with its selected priority bit set beats the playfield -- MAME
// ignores LBPRI entirely. 24 of the 64 MO-opaque/alpha-off input combinations
// differ between the two.

module toobin_priority
(
	input  logic [9:0] pf_idx,      // playfield palette index (base 0)
	input  logic [1:0] pf_cat,      // PFPRI1:0 (playfield category / priority)
	input  logic       pf_pen3,     // PFPIX3D -- playfield pen bit 3
	input  logic [9:0] mo_idx,      // motion-object palette index (base 256); [3:0] = LBPIX3:0
	input  logic [1:0] mo_pri,      // LBPRI1:0, carried through the line buffer
	input  logic       mo_opaque,   // MO pen != 0 (the 11E F21 AND of /LBPIX3:0)
	input  logic [9:0] al_idx,      // alphanumerics palette index (base 512)
	input  logic       al_opaque,   // ANPIX1:0 != 0 (the alpha layer is 2bpp)
	output logic [9:0] pen          // final palette index
);

	// Each layer's pen bit 3 chooses which of its two priority bits is compared.
	wire mo_pri_sel = mo_idx[3] ? mo_pri[1] : mo_pri[0];
	wire pf_pri_sel = pf_pen3   ? pf_cat[1] : pf_cat[0];

	// The playfield covers an opaque motion object only when the playfield's
	// selected priority bit is set AND the motion object's selected bit is clear.
	always_comb begin
		pen = pf_idx;
		if (mo_opaque && !(pf_pri_sel && !mo_pri_sel)) pen = mo_idx;
		if (al_opaque)                                 pen = al_idx;
	end

endmodule
