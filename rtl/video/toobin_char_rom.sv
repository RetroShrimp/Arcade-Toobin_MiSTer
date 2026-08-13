// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' alphanumerics character ROM + 2bpp gfx decoder.
//
// Holds the 16 KB char ROM (1024 tiles x 16 bytes); loader writes bytes, the
// renderer fetches an 8-pixel row of a tile. Decode per MAME `anlayout`
// (8x8, 2bpp, planes {0,4}, x-offsets {0,1,2,3,8,9,10,11}, y*16), MSB-first bits:
//   row y uses bytes A=tile*16+y*2 (pixels 0-3) and B=A+1 (pixels 4-7);
//   pixel x in 0-3: {A[3-x], A[7-x]};  x in 4-7: {B[3-(x-4)], B[7-(x-4)]}.

module toobin_char_rom
(
	input  logic        clk,
	input  logic        ce,         // pixel enable for the fetch read (tie 1 for full rate)
	// loader write (byte)
	input  logic        wr,
	input  logic [13:0] wr_addr,
	input  logic  [7:0] wr_data,
	// fetch: tile + row -> 8 pixels of 2bpp (pix0=[1:0] .. pix7=[15:14])
	input  logic  [9:0] tile,
	input  logic  [2:0] row,
	output logic [15:0] pixrow
);

	logic [7:0] mem [0:16383];
`ifndef ALTERA_RESERVED_QIS
	initial begin for (int i=0;i<16384;i++) mem[i]=8'h00; end   // sim-only; M10K powers to 0
`endif

	wire [13:0] a_addr = (14'(tile) << 4) + (14'(row) << 1);   // tile*16 + row*2
	logic [7:0] A, B;

	always_ff @(posedge clk) begin
		if (wr) mem[wr_addr] <= wr_data;          // loader write (full rate)
	end
	always_ff @(posedge clk) if (ce) begin        // fetch read (pixel-gated)
		A <= mem[a_addr];
		B <= mem[a_addr | 14'd1];
	end

	// {pix7,pix6,...,pix0}, each pixel = {MSB=plane[0]@off0, LSB=plane[1]@off4}
	// (MAME: planeoffset[0] is the most-significant pixel bit).
	assign pixrow = { {B[4],B[0]}, {B[5],B[1]}, {B[6],B[2]}, {B[7],B[3]},
	                  {A[4],A[0]}, {A[5],A[1]}, {A[6],A[2]}, {A[7],A[3]} };

endmodule
