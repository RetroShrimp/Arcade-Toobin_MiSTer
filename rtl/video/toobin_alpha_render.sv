// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' alpha (text/HUD) layer renderer.
//
// Owns the 3072-word alpha RAM (0xC08000, 64x48 tiles of 8x8) and an instance of
// the tested char_rom (anlayout 2bpp).  Given a raster pixel (hpos 0..511,
// vpos 0..383) it produces that pixel's alpha pen (0x200 + color*4 + pix) and an
// opaque flag (pix != 0 => draws over lower layers).  SP-320 sheet 6 is the
// electrical authority: D11 drives ANHFLIP, D9:0 select one of the 1024
// characters, and D10 reaches only the optional ANROMA14/VPP socket pin.  The
// populated rev-3 character image is 16 KiB, so D10 has no address effect.
//
// 3-stage pixel pipeline (advances every clk; wrap with ce_pix at integration).
// Raster coords are carried through so (pen_out, hpos_out, vpos_out) name the pixel.
//   s0: alpha RAM read           s1: char_rom fetch          s2: pixel select + pen

module toobin_alpha_render
(
	input  logic        clk,
	input  logic        ce,             // pixel enable for the display pipeline
	// char ROM loader (bytes)
	input  logic        char_wr,
	input  logic [13:0] char_wr_addr,
	input  logic  [7:0] char_wr_data,
	// alpha RAM CPU port (16-bit, byte enables); read-back valid 1 clk after addr
	input  logic        a_wr,
	input  logic [11:0] a_wr_addr,      // 0..3071 word address (CPU read+write)
	input  logic [15:0] a_wr_data,
	input  logic  [1:0] a_wr_be,
	output logic [15:0] a_rdata,        // aram[a_wr_addr] (CPU read-back)
	// raster read
	input  logic  [9:0] hpos,           // 0..511
	input  logic  [9:0] vpos,           // 0..383
	// output (valid 3 clks after the matching hpos/vpos were presented)
	output logic  [9:0] pen,
	output logic        opaque,
	output logic  [9:0] hpos_out,
	output logic  [9:0] vpos_out
);

	// ---- alpha RAM: CPU-writable, read by BOTH the CPU (read-back) and the video ----
	// 1 byteena write + 2 reads can't be an inline M10K (see toobin_pf_render); use the proven
	// toobin_dpram (auto-duplicated into two SDP M10Ks).  Port A = CPU write + read-back, port B =
	// video read.  The video read is un-gated (the M10K reads every clk) — equivalent to the old
	// ce-gated read because a_rd_addr only changes on ce (hpos/vpos advance on ce).
	wire [11:0] a_rd_addr = {vpos[8:3], hpos[8:3]};   // (vpos/8)*64 + hpos/8
	logic [15:0] alpha_q;

	toobin_dpram #(.DW(16), .AW(12)) u_aram (
		.clk(clk),
		.a_addr(a_wr_addr), .a_din(a_wr_data), .a_we(a_wr ? a_wr_be : 2'b0), .a_dout(a_rdata),
		.b_addr(a_rd_addr), .b_din(16'b0),     .b_we(2'b0), .b_re(ce),       .b_dout(alpha_q) );  // display read: 1-CE latency

	// ---- stage 0 -> 1 pipelined coords ----
	logic [9:0] h1, v1;
	always_ff @(posedge clk) if (ce) begin h1 <= hpos; v1 <= vpos; end

	// stage 1: decode the alpha word, drive char_rom
	wire  [9:0] code1  = alpha_q[9:0];
	wire  [3:0] color1 = alpha_q[15:12];
	wire        flipx1 = alpha_q[11];
	wire        unused_a = &{1'b0, alpha_q[10]};   // optional ROM A14/VPP; unused by 16 KiB rev-3 ROM
	logic [15:0] pixrow;
	toobin_char_rom u_char (
		.clk(clk), .ce(ce), .wr(char_wr), .wr_addr(char_wr_addr), .wr_data(char_wr_data),
		.tile(code1), .row(v1[2:0]), .pixrow(pixrow) );

	// carry color/flip/coords alongside char_rom's 1-clk fetch latency
	logic [3:0] color2; logic flipx2; logic [9:0] h2, v2;
	always_ff @(posedge clk) if (ce) begin
		color2 <= color1; flipx2 <= flipx1; h2 <= h1; v2 <= v1;
	end

	// stage 2: select pixel (flipx mirrors within tile), form pen + opaque
	wire  [2:0] cx    = flipx2 ? ~h2[2:0] : h2[2:0];
	wire  [1:0] pixv  = pixrow[cx*2 +: 2];
	// pen = 0x200 + color*4 + pix; color*4+pix < 64 so it fits bits [5:0] with no
	// carry into the 0x200 base => exact and width-clean as a concatenation.
	always_ff @(posedge clk) if (ce) begin
		pen      <= {4'b1000, color2, pixv};
		opaque   <= |pixv;
		hpos_out <= h2;
		vpos_out <= v2;
	end

endmodule
