// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' video subsystem — frame compositor.
//
// Self-times the 640x416 raster (pixel-clocked; one clk = one pixel), drives the
// per-pixel playfield + alpha renderers, runs the motion-object engine one line
// ahead into a double-buffered sprite line buffer, aligns the three layer
// pipelines, and merges them through toobin_priority + the 1024-entry color RAM +
// toobin_palette into 24-bit RGB.  Layer order/merge exactly per MAME screen_update.
//
// MO line pipeline: each line, walk the LIVE list selected by SLINKPTR and render
// the NEXT display line into the back buffer, swap at line end, and display/clear
// the front buffer during active.  The per-line walk is essential because the game
// changes SLINKPTR between raster bands (notably the waterfall/title scene).  The
// renderer fetches one
// burst-4 sprite word group per 16px column (load-time repacked ROM) and overlaps
// the blit with the next fetch, so worst-case MO lines fit the one-line budget
// alongside the PF prefetch + CPU ROM traffic on the shared SDRAM port; a
// line_start that catches the engine busy is latched, not lost.

module toobin_video
(
	input  logic        clk,           // clk_sys (single game clock)
	input  logic        ce,            // 16 MHz pixel enable (tie 1 for one pixel per clock)
	input  logic        reset,

	// ---- loader / CPU write ports ----
	input  logic        char_wr,  input logic [13:0] char_wr_addr, input logic [7:0]  char_wr_data,
	// playfield tile ROM fetch (reorganized 32-bit {D,C,B,A}; via SDRAM arbiter)
	output logic        tile_req, output logic [16:0] tile_addr,
	input  logic        tile_valid, input logic [31:0] tile_data,
	input  logic        pf_wr,    input logic [12:0] pf_wr_addr,    input logic [31:0] pf_wr_data,  input logic [3:0] pf_wr_be,
	input  logic        a_wr,     input logic [11:0] a_wr_addr,     input logic [15:0] a_wr_data,   input logic [1:0] a_wr_be,
	input  logic        mo_wr,    input logic  [9:0] mo_wr_addr,    input logic [15:0] mo_wr_data,  input logic [1:0] mo_wr_be,
	input  logic        pal_wr,   input logic  [9:0] pal_wr_addr,   input logic [15:0] pal_wr_data, input logic [1:0] pal_wr_be,

	// ---- registers ----
	input  logic  [9:0] scrollx,        // playfield/MO X scroll (reg>>6)
	input  logic  [9:0] scrolly,        // playfield Y scroll (reg>>6); MO uses [8:0]
	input  logic        vscroll_restart,// FF8700 D0=0 write accepted during HBLANK
	input  logic  [4:0] intensity,      // FF8300 brightness
	input  logic  [7:0] start_link,     // slipram[0] & 0xff

	// ---- sprite ROM column read (2 MB, SDRAM, load-time repacked): one burst-4 per
	//      16px row; sprb_addr = {code[13:0], gfxrow[3:0]}, 4 words per request ----
	output logic [17:0] sprb_addr,
	output logic        sprb_req,
	input  logic        sprb_valid,
	input  logic [15:0] sprb_word,

	// ---- video out ----
	output logic  [7:0] vga_r, vga_g, vga_b,
	output logic        hsync, vsync, hblank, vblank,
	output logic        ce_pix,

	// ---- CPU read-back of the video RAMs (valid 1 clk after the CPU addr) ----
	output logic [31:0] pf_rdata,       // pfram[pf_wr_addr]
	output logic [15:0] a_rdata,        // aram[a_wr_addr]
	output logic [15:0] mo_rdata,       // moram[mo_wr_addr]
	output logic [15:0] pal_rdata,      // palram[pal_wr_addr]

	// ---- raster events for the main CPU (single raster source) ----
	input  logic  [8:0] irq_scanline,   // FF8340 programmable line compare
	output logic        scanline_match, // 1-clk pulse at pixel 0 of irq_scanline
	output logic        vblank_start,   // 1-clk pulse at pixel 0 of line 384
	output logic        vsync_start     // 1-clk pulse at /VSYNC assertion (line 388)
);

	assign ce_pix = ce;                // pixel enable pass-through for the output stage

	// ================= raster counter (0..639 x 0..415) =================
	localparam [9:0] H_LAST = 10'd639, H_ACT = 10'd512, HS_B = 10'd544, HS_E = 10'd608;
	localparam [8:0] V_LAST = 9'd415,  V_ACT = 9'd384,  VS_B = 9'd388,  VS_E = 9'd392;
	logic [9:0] hc; logic [8:0] vc;
	wire raw_hblank, raw_hsync, raw_vblank, raw_vsync, raster_frame_nc;
	toobin_raster u_raster (
		.clk(clk), .reset(reset), .ce(ce), .irq_scanline(irq_scanline),
		.h_count(hc), .v_count(vc),
		.hblank(raw_hblank), .hsync(raw_hsync), .vblank(raw_vblank), .vsync(raw_vsync),
		.scanline_match(scanline_match), .vblank_start(vblank_start),
		.vsync_start(vsync_start), .frame_start(raster_frame_nc) );

	// Sheet-14 VSCROLL counter.  The raw latch remains the motion-object scroll;
	// the playfield consumes a frame/restart-relative offset.
	logic [8:0] pf_yoffset;
	wire vscroll_frame_load = ce && (hc == H_LAST) && (vc == V_LAST);
	toobin_vscroll_ctrl u_vscroll (
		.clk(clk), .reset(reset), .frame_start(vscroll_frame_load),
		.restart(vscroll_restart), .vpos(vc), .scroll_latch(scrolly[8:0]),
		.effective_offset(pf_yoffset) );

	// fetch-ahead raster: LEAD pixels ahead of (hc,vc), for the PF tile prefetch
	localparam int LEAD = 16;
	logic [9:0] fhc; logic [8:0] fvc;
	always_ff @(posedge clk) begin
		if (reset) begin fhc <= 10'(LEAD); fvc <= 9'd0; end
		else if (ce) begin
			if (fhc == H_LAST) begin fhc <= 10'd0; fvc <= (fvc == V_LAST) ? 9'd0 : fvc + 9'd1; end
			else fhc <= fhc + 10'd1;
		end
	end

	// ================= playfield + alpha per-pixel renderers =================
	wire [9:0] pf_pen, al_pen, pf_ho, pf_vo;
	wire       pf_pen3, al_opaque; wire [1:0] pf_cat;
	wire [9:0] al_ho_nc, al_vo_nc;               // alpha coord outputs unused (matches pf)
	wire       mo_ld_nc, mo_busy_nc;
	wire       unused_v = &{1'b0, pf_vo[9], al_ho_nc, al_vo_nc, mo_ld_nc, mo_busy_nc,
		raw_hblank, raw_hsync, raw_vblank, raw_vsync, raster_frame_nc};
	toobin_pf_render u_pf (
		.clk(clk), .ce(ce), .reset(reset),
		.pf_wr(pf_wr), .pf_wr_addr(pf_wr_addr), .pf_wr_data(pf_wr_data), .pf_wr_be(pf_wr_be),
		.pf_rdata(pf_rdata),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_valid(tile_valid), .tile_data(tile_data),
		.scrollx(scrollx),
		// During raster line 415 the back buffer is fetching frame line 0, whose
		// sheet-14 counter load is the raw VS latch (not the prior frame offset).
		.scrolly((vc == V_LAST) ? scrolly : {1'b0,pf_yoffset}),
		.hpos(hc), .vpos({1'b0, vc}), .fhpos(fhc), .fvpos({1'b0, fvc}),
		.pen(pf_pen), .pen3(pf_pen3), .category(pf_cat), .hpos_out(pf_ho), .vpos_out(pf_vo) );
	toobin_alpha_render u_alpha (
		.clk(clk), .ce(ce), .char_wr(char_wr), .char_wr_addr(char_wr_addr), .char_wr_data(char_wr_data),
		.a_wr(a_wr), .a_wr_addr(a_wr_addr), .a_wr_data(a_wr_data), .a_wr_be(a_wr_be),
		.a_rdata(a_rdata),
		.hpos(hc), .vpos({1'b0, vc}), .pen(al_pen), .opaque(al_opaque),
		.hpos_out(al_ho_nc), .vpos_out(al_vo_nc) );

	// ================= motion-object engine (line-synced) =================
	// MO engine runs at full clk_sys (handshakes with the full-rate SDRAM); its trigger
	// pulses/enables are qualified with `ce` so they are 1-clk_sys wide per pixel.
	wire        mo_line_start = ce && (hc == 10'd2)  && ((vc < V_ACT) || (vc == V_LAST));
	wire  [8:0] mo_render_line = (vc == V_LAST) ? 9'd0 : (vc + 9'd1);
	// SP-320 sheet 13 selects the two line-buffer banks directly from 1V//1V, and the
	// displayed bank's chip select is gated only by 16MHZD and that parity -- there is
	// no BLANK/active-display term, and R107-R114 pull the data bus to the transparent
	// 0xF so every location read is simultaneously rewritten.  The read+clear sweep and
	// the bank swap therefore run on EVERY scanline, vblank included.  (Corroborated by
	// Atari SP-284's LINEBUF.vhd, whose address counter increments on every master clock
	// with no active-display qualifier.)
	//
	// These were previously qualified with `vc < V_ACT`, which had two consequences:
	// the front bank was never swept during vblank, so anything blitted for a line at
	// or past V_ACT survived uncleared; and the swap fired on an ODD 385 of 416 lines,
	// so bank parity inverted every frame instead of tracking 1V.  Together those put a
	// stale motion-object row on display line 1 -- the frame-CRC gate's y=1 residual.
	wire        mo_line_swap   = ce && (hc == H_LAST);
	wire        mo_disp_ce     = ce && (hc < H_ACT);
	wire [15:0] mo_disp_pen;
	toobin_mo_render u_mo (
		.clk(clk), .reset(reset), .mo_wr(mo_wr), .mo_wr_addr(mo_wr_addr), .mo_wr_data(mo_wr_data), .mo_wr_be(mo_wr_be),
		.mo_rdata(mo_rdata),
		.xscroll(scrollx), .yscroll(scrolly[8:0]),
		.frame_start(1'b0), .start_link(start_link),
		.line_start(mo_line_start), .render_line(mo_render_line), .line_swap(mo_line_swap),
		.line_done(mo_ld_nc), .busy(mo_busy_nc), .sprb_addr(sprb_addr),
		.sprb_req(sprb_req), .sprb_valid(sprb_valid), .sprb_word(sprb_word),
		.disp_ce(mo_disp_ce), .disp_x(hc), .disp_pen(mo_disp_pen) );

	// align MO readout (1-clk) to the pf/alpha 3-clk pipeline: delay 2 more (per pixel)
	logic [15:0] mo_pen_s2, mo_pen_s3;
	always_ff @(posedge clk) if (ce) begin mo_pen_s2 <= mo_disp_pen; mo_pen_s3 <= mo_pen_s2; end
	wire        mo_opaque = (mo_pen_s3 != 16'hFFFF);
	wire  [1:0] mo_pri = mo_pen_s3[15:14];

	// ================= priority merge (stage 3) =================
	wire [9:0] pen_s3;
	toobin_priority u_pri (
		.pf_idx(pf_pen), .pf_cat(pf_cat), .pf_pen3(pf_pen3),
		.mo_idx(mo_pen_s3[9:0]), .mo_pri(mo_pri), .mo_opaque(mo_opaque),
		.al_idx(al_pen), .al_opaque(al_opaque), .pen(pen_s3) );

	// ================= color RAM -> palette -> RGB =================
	logic  [9:0] pen_s4; logic [9:0] ho_s4, ho_s5; logic [8:0] vo_s4, vo_s5;
	logic [15:0] color_s5;
	// Color RAM is the same byte-enabled CPU/read-only-video shape as the other
	// VRAMs.  The shared wrapper is required for Quartus 17 M10K inference; direct
	// slice writes to palram expanded this 16K-bit array into 16K registers.
	toobin_dpram #(.DW(16), .AW(10)) u_palram (
		.clk(clk),
		.a_addr(pal_wr_addr), .a_din(pal_wr_data), .a_we(pal_wr ? pal_wr_be : 2'b00), .a_dout(pal_rdata),
		.b_addr(pen_s4),      .b_din(16'b0),       .b_we(2'b00), .b_re(ce),          .b_dout(color_s5) );
	always_ff @(posedge clk) begin
		if (ce) begin
			// stage 3 -> 4: latch merged pen + coordinate
			pen_s4 <= pen_s3; ho_s4 <= pf_ho; vo_s4 <= pf_vo[8:0];
			// stage 4 -> 5: color RAM read + coordinate  (port B)
			ho_s5 <= ho_s4; vo_s5 <= vo_s4;
		end
	end

	wire [7:0] rr, gg, bb;
	toobin_palette u_pal (.color(color_s5), .intensity(intensity), .r(rr), .g(gg), .b(bb));

	// ================= output (stage 5): blank RGB, derive sync from coord =================
	wire out_hblank = (ho_s5 >= H_ACT);
	wire out_vblank = (vo_s5 >= V_ACT);
	always_ff @(posedge clk) if (ce) begin
		hblank <= out_hblank;
		vblank <= out_vblank;
		hsync  <= (ho_s5 >= HS_B) && (ho_s5 < HS_E);
		vsync  <= (vo_s5 >= VS_B) && (vo_s5 < VS_E);
		vga_r  <= (out_hblank || out_vblank) ? 8'd0 : rr;
		vga_g  <= (out_hblank || out_vblank) ? 8'd0 : gg;
		vga_b  <= (out_hblank || out_vblank) ? 8'd0 : bb;
	end

endmodule
