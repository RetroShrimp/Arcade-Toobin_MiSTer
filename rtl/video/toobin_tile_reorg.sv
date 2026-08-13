// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' playfield tile-ROM load-time reorganizer.  The tile ROM downloads in
// MAME pflayout order (first half 0..0x3FFFF = planes 2,3; second half
// 0x40000..0x7FFFF = planes 0,1).  pf_render fetches one 32-bit word {D,C,B,A} per
// tile row (index code*8+row).  This maps a download byte offset to its byte
// address in the reorganized 32-bit tile ROM, so the loader can write it straight
// to SDRAM in fetch-ready order.
//
//   half = off[18]        (0 = first half A/B, 1 = second half C/D)
//   tile = off[17:4]      (byte offset within a half / 16)
//   row  = off[3:1]       ((off>>1) & 7)
//   byte = off[0]         (0 = low byte of the pair, 1 = high)
//   lane = {half, byte}   (A=0, B=1, C=2, D=3)
//   reorg word = tile*8 + row = {tile,row};  reorg byte addr = word*4 + lane
//              = {tile, row, lane}

module toobin_tile_reorg
(
	input  logic [18:0] off,          // tile ROM download offset (0..0x7FFFF)
	output logic [18:0] reorg_addr    // byte address in the reorganized 32-bit ROM
);

	wire        half = off[18];
	wire [13:0] tile = off[17:4];
	wire  [2:0] row  = off[3:1];
	wire  [1:0] lane = {half, off[0]};

	assign reorg_addr = {tile, row, lane};

endmodule
