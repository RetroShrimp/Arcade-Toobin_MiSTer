// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' motion-object line buffer (double-buffered, clear-on-read).
//
// One line is rendered into the back buffer while the front buffer is displayed;
// reading a displayed pixel writes 0xFFFF back (clear-on-read) so the buffer is
// blank when it next becomes the back buffer.  SP-320 sheet 13 selects the two
// physical line-buffer banks directly with 1V and /1V, so line_swap always
// changes banks; it is deliberately not completion-gated.  A sprite row that
// crosses the parity edge writes its prefix into the just-finished bank and its
// suffix into the next bank, matching those write strobes.  Pen 0xFFFF is
// transparent (matches MAME's MO sentinel). Low 10 bits are MO pen =
// 0x100 + color*16 + pix; bits 15:14 preserve the PCB LBPRI1:0 value
// (transpen: pix 0 skipped).
//
// blit: writes one decoded 16-pixel sprite row (blit_row, 16x4bpp) at blit_x into
// the back buffer, honoring hflip and clipping to the 512-wide visible line.

module toobin_mo_linebuf
(
	input  logic        clk,
	input  logic        reset,
	// blit a 16-pixel row into the back (render) buffer
	input  logic        blit_req,
	input  logic signed [10:0] blit_x,   // signed: sprite may straddle the left edge
	input  logic [63:0] blit_row,     // 16 x 4bpp
	input  logic  [3:0] blit_color,
	input  logic  [1:0] blit_pri,
	input  logic        blit_hflip,
	output logic        blit_busy,
	// end-of-line buffer swap
	input  logic        line_swap,
	// display read from the front buffer (clear-on-read)
	input  logic        disp_ce,
	input  logic  [9:0] disp_x,
	output logic [15:0] disp_pen
);

	logic [15:0] b0 [0:511];
	logic [15:0] b1 [0:511];
	logic        wsel;               // back (render) buffer = wsel; front = ~wsel
	logic [15:0] dq0, dq1;

	// ---- blit FSM: one pixel per clk, 16 pixels ----
	logic        bactive;
	logic  [4:0] bi;                 // 0..16
	logic signed [10:0] bx;
	logic [63:0] brow;
	logic  [3:0] bcolor;
	logic  [1:0] bpri;
	logic        bhflip;
	assign blit_busy = bactive;

	wire  [3:0] src_sub = bhflip ? (4'd15 - bi[3:0]) : bi[3:0];
	wire  [3:0] pv      = brow[src_sub*4 +: 4];
	wire signed [11:0] tx = {bx[10], bx} + $signed({8'b0, bi[3:0]});   // screen x (signed)
	wire        do_wr   = bactive & (pv != 4'd0) & (tx >= 0) & (tx < 12'sd512);
	wire [15:0] wpen    = {bpri, 6'h01, bcolor, pv}; // {LBPRI, MO base 0x100 + color*16 + pv}
	wire  [8:0] waddr   = tx[8:0];

	// clear-on-read on the front buffer
	wire        front1  = ~wsel;     // 1 if front buffer is b1
	wire  [8:0] daddr   = disp_x[8:0];
	wire        unused_dx = &{1'b0, disp_x[9]};   // screen is 512 wide, bit9 unused

	always_ff @(posedge clk) begin
		// ---- buffer b0 ----
		if (wsel == 1'b0) begin                 // b0 is back buffer -> blit writes
			if (do_wr) b0[waddr] <= wpen;
		end else begin                          // b0 is front buffer -> display + clear
			if (disp_ce) begin b0[daddr] <= 16'hFFFF; dq0 <= b0[daddr]; end
		end
		// ---- buffer b1 ----
		if (wsel == 1'b1) begin                 // b1 is back buffer -> blit writes
			if (do_wr) b1[waddr] <= wpen;
		end else begin                          // b1 is front buffer -> display + clear
			if (disp_ce) begin b1[daddr] <= 16'hFFFF; dq1 <= b1[daddr]; end
		end

		// ---- blit sequencer ----
		if (blit_req && !bactive) begin
			bactive <= 1'b1; bi <= 5'd0;
			bx <= blit_x; brow <= blit_row; bcolor <= blit_color; bpri <= blit_pri; bhflip <= blit_hflip;
		end else if (bactive) begin
			if (bi == 5'd15) bactive <= 1'b0;
			bi <= bi + 5'd1;
		end

		// ---- unconditional 1V/inverse-1V bank parity (SP-320 sheet 13) ----
		if (line_swap) wsel <= ~wsel;

		if (reset) begin wsel <= 1'b0; bactive <= 1'b0; bi <= 5'd0; end
	end

	assign disp_pen = front1 ? dq1 : dq0;

	// buffers power up transparent (0xFFFF)
	initial begin
		for (int i=0;i<512;i++) begin b0[i]=16'hFFFF; b1[i]=16'hFFFF; end
	end

endmodule
