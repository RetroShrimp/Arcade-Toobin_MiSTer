// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' motion-object position/scanline-intersection unit (combinational).
//
// Implements MAME atarimo render_object's coordinate math for ONE object against
// ONE render scanline Y (0..383), in closed form.  Constants for Toobin:
// MO bitmap 1024x512 (xmask 0x3FF, ymask 0x1FF), visible 512x384, tiles 16x16,
// swapxy render order, xoffset 0.
//
//   W = wfield+1, H = hfield+1  (tiles across / down)
//   xpos = xraw - (abs?0:xscroll);  wrap &0x3FF, if >=512 -=1024   => signed [-512,511]
//   ypos = -yraw - (abs?0:yscroll) - H*16; wrap &0x1FF, if >=384 -=512 => signed [-128,383]
//   (ypos here is the band TOP, before the vflip placement adjust)
//   hit  = 0 <= (Y-ypos) < H*16 ; r = Y-ypos
//   tin = r>>4, pin = r&15
//   ty0 (tile-in-column, shared by all columns) = vflip ? H-1-tin : tin
//   gfx_row (row within that 16x16 tile)        = vflip ? 15-pin  : pin
//   xpos_adj = hflip ? xpos+(W-1)*16 : xpos     (column-0 left edge; xadv = -/+16)
// The orchestrator loops tx: code = base + tx*H + ty0; sx = xpos_adj +/- tx*16.

module toobin_mo_pos
(
	input  logic  [9:0] xraw,
	input  logic  [8:0] yraw,
	input  logic  [2:0] wfield,
	input  logic  [2:0] hfield,
	input  logic        hflip,
	input  logic        vflip,
	input  logic        absolute,
	input  logic  [9:0] xscroll,
	input  logic  [8:0] yscroll,
	input  logic  [8:0] scanline,     // Y, 0..383
	output logic        hit,
	output logic  [3:0] W,            // 1..8
	output logic  [3:0] H,            // 1..8
	output logic signed [10:0] xpos_adj,
	output logic  [2:0] ty0,
	output logic  [3:0] gfx_row
);

	assign W = {1'b0, wfield} + 4'd1;
	assign H = {1'b0, hfield} + 4'd1;

	// ---- vertical: band top (ypos before vflip adjust) ----
	// ypos_pre = -yraw - (abs?0:yscroll) - H*16, then wrap &0x1FF / >=384 -=512
	wire signed [12:0] ysc   = absolute ? 13'sd0 : $signed({4'b0, yscroll});
	wire signed [12:0] hpx   = $signed({5'b0, H, 4'b0});                 // H*16
	wire signed [12:0] ypre  = -$signed({4'b0, yraw}) - ysc - hpx;
	wire        [8:0]  ymask = ypre[8:0];                                // & 0x1FF
	wire        unused_ypre  = &{1'b0, ypre[12:9]};                      // high bits = wrap discard
	// compute the signed wrap one bit wider (so 512 is representable, no Quartus
	// constant overflow) then slice to the 10-bit result (explicit, no truncation warn).
	wire signed [10:0] ytop_w = (ymask >= 9'd384) ? ($signed({2'b0, ymask}) - 11'sd512)
	                                              : $signed({2'b0, ymask});
	wire signed [9:0]  ytop   = ytop_w[9:0];
	wire signed [10:0] r_s   = $signed({2'b0, scanline}) - {ytop[9], ytop};
	wire signed [10:0] hpx16 = $signed({3'b0, H, 4'b0});                 // H*16
	assign hit = (r_s >= 0) && (r_s < hpx16);
	wire [6:0] r   = r_s[6:0];
	wire [2:0] tin = r[6:4];
	wire [3:0] pin = r[3:0];
	assign ty0     = vflip ? 3'((H - 4'd1) - {1'b0, tin}) : tin;
	assign gfx_row = vflip ? (4'd15 - pin) : pin;

	// ---- horizontal: column-0 left edge ----
	wire signed [11:0] xsc  = absolute ? 12'sd0 : $signed({2'b0, xscroll});
	wire signed [11:0] xpre = $signed({2'b0, xraw}) - xsc;
	wire        [9:0]  xmask = xpre[9:0];                                // & 0x3FF
	wire        unused_xpre = &{1'b0, xpre[11:10]};                      // high bits = wrap discard
	wire signed [11:0] xwrap_w = (xmask >= 10'd512) ? ($signed({2'b0, xmask}) - 12'sd1024)
	                                               : $signed({2'b0, xmask});
	wire signed [10:0] xwrap   = xwrap_w[10:0];
	wire unused_wrap = &{1'b0, ytop_w[10], xwrap_w[11]};                 // sign bit, sliced off
	wire signed [10:0] wadj = $signed({3'b0, (W - 4'd1), 4'b0});         // (W-1)*16
	assign xpos_adj = hflip ? (xwrap + wadj) : xwrap;

endmodule
