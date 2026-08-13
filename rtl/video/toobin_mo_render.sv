// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' motion-object render orchestrator — the complete sprite engine.
//
// Ties together: toobin_mo_list (active-list build from the MO linked list),
// toobin_mo_pos (per-object scanline intersection / placement math),
// toobin_mo_gfx (16x16 4bpp row decode), toobin_mo_linebuf (double-buffered
// sprite line buffer).  Faithful to MAME atarimo render_object (swapxy, forward
// order, transpen 0, pen base 0x100).
//
// Usage: per scanline pulse line_start with render_line.  The renderer walks the
// LIVE linked list from start_link, renders that line, waits for the last blit, and
// pulses line_done.  A once-per-FRAME snapshot is wrong: Toobin rewrites MO links
// during a frame (the waterfall/title scene selects different object chains for
// different raster bands), so a snapshot locks in only part of the scene.  The walk
// is therefore driven by CHANGE, not by the frame: it re-runs whenever MO RAM is
// written or start_link moves, and is skipped otherwise (see the active-list cache
// below).  That is exact -- the list the walk produces does not depend on the
// scanline or the scroll -- and it is what keeps a long chain off the per-line
// critical path.
// Pulse line_swap at the raster line boundary and display the front buffer via
// disp_ce/disp_x.  frame_start remains in the port list for integration compatibility
// but no longer snapshots the list.
// A line_start that arrives while the engine is still busy is LATCHED and consumed
// when the engine goes idle (late render beats a silently dropped line).
//
// Sprite ROM (2 MB, SDRAM, load-time repacked): ONE burst-4 read per 16px column row
// -- sprb_addr = {code[13:0], gfxrow[3:0]}, the four words return in order on
// consecutive sprb_valid pulses (word 0/1 = first half F0F1/F2F3, word 2/3 = second
// half S0S1/S2S3).  One burst (~16 clk) replaces the old 4 single-word round trips
// (~50 clk, worse under playfield/CPU contention), and the line-buffer blit runs in
// PARALLEL with the next column's fetch -- together these keep MO-heavy scanlines
// (title screen: ~25-30 columns) inside the one-line render budget that the old
// per-word engine blew, which showed on hardware as flashing / vanishing sprites.

module toobin_mo_render
(
	input  logic        clk,
	input  logic        reset,
	// MO RAM CPU port (16-bit words, 1024); read-back valid 1 clk after addr
	input  logic        mo_wr,
	input  logic  [9:0] mo_wr_addr,
	input  logic [15:0] mo_wr_data,
	input  logic  [1:0] mo_wr_be,
	output logic [15:0] mo_rdata,
	// scroll (pixels; MAME feeds reg>>6)
	input  logic  [9:0] xscroll,
	input  logic  [8:0] yscroll,
	// frame / line control
	input  logic        frame_start,
	input  logic  [7:0] start_link,
	input  logic        line_start,
	input  logic  [8:0] render_line,
	input  logic        line_swap,
	output logic        line_done,
	output logic        busy,
	// sprite ROM column read: one burst-4 request per 16px row; the 4 words arrive in
	// order on (possibly consecutive-cycle) sprb_valid pulses while sprb_req is held.
	output logic [17:0] sprb_addr,   // {code[13:0], gfxrow[3:0]}
	output logic        sprb_req,    // held until the 4th word
	input  logic        sprb_valid,
	input  logic [15:0] sprb_word,   // {odd-byte[15:8], even-byte[7:0]}
	// display read (front buffer)
	input  logic        disp_ce,
	input  logic  [9:0] disp_x,
	output logic [15:0] disp_pen
);

	// ---- active list (owns MO RAM) ----
	logic  [7:0] al_index;
	logic [47:0] al_entry;
	logic  [8:0] al_count;
	logic        al_busy;
	logic        list_start;
	toobin_mo_list u_list (
		.clk(clk), .reset(reset), .mo_wr(mo_wr), .mo_wr_addr(mo_wr_addr), .mo_wr_data(mo_wr_data), .mo_wr_be(mo_wr_be),
		.mo_rdata(mo_rdata),
		.start(list_start), .start_link(start_link),
		.rd_index(al_index), .rd_entry(al_entry), .count(al_count), .busy(al_busy) );

	// ---- unpack the active entry currently addressed ----
	wire [13:0] e_code  = al_entry[13:0];
	wire  [3:0] e_color = al_entry[17:14];
	wire  [9:0] e_xraw  = al_entry[27:18];
	wire  [8:0] e_yraw  = al_entry[36:28];
	wire  [2:0] e_wid   = al_entry[39:37];
	wire  [2:0] e_hgt   = al_entry[42:40];
	wire        e_hflip = al_entry[43];
	wire        e_vflip = al_entry[44];
	wire        e_abs   = al_entry[45];
	wire  [1:0] e_pri   = al_entry[47:46];

	// ---- position / intersection unit (combinational) ----
	wire        p_hit;
	wire  [3:0] p_W, p_H;
	wire signed [10:0] p_xadj;
	wire  [2:0] p_ty0;
	wire  [3:0] p_gfxrow;
	toobin_mo_pos u_pos (
		.xraw(e_xraw), .yraw(e_yraw), .wfield(e_wid), .hfield(e_hgt),
		.hflip(e_hflip), .vflip(e_vflip), .absolute(e_abs),
		.xscroll(xscroll), .yscroll(yscroll), .scanline(cur_y),
		.hit(p_hit), .W(p_W), .H(p_H), .xpos_adj(p_xadj), .ty0(p_ty0), .gfx_row(p_gfxrow) );

	// ---- gfx decode (combinational) ----
	logic [31:0] fh_row, sh_row;
	wire  [63:0] g_pixrow;
	toobin_mo_gfx u_gfx (.fh_row(fh_row), .sh_row(sh_row), .pixrow(g_pixrow));

	// ---- line buffer ----
	logic        lb_blit_req;
	logic signed [10:0] lb_blit_x;
	logic  [3:0] lb_blit_color;
	logic        lb_blit_hflip;
	logic  [1:0] lb_blit_pri;
	wire         lb_busy;
	toobin_mo_linebuf u_lb (
		.clk(clk), .reset(reset), .blit_req(lb_blit_req), .blit_x(lb_blit_x),
		.blit_row(g_pixrow), .blit_color(lb_blit_color), .blit_pri(lb_blit_pri), .blit_hflip(lb_blit_hflip),
		.blit_busy(lb_busy), .line_swap(line_swap), .disp_ce(disp_ce), .disp_x(disp_x),
		.disp_pen(disp_pen) );

	// ---- per-object latched state ----
	logic  [8:0] cur_y;
	logic  [7:0] obj;
	logic  [3:0] o_W, o_H;
	logic  [2:0] o_ty0;
	logic  [3:0] o_gfxrow;
	logic signed [10:0] o_xadj;
	logic  [3:0] o_color;
	logic  [1:0] o_pri;
	logic        o_hflip;
	logic [13:0] o_base;
	logic  [2:0] tx;

	// current column code + screen-x
	wire [13:0] tx_h     = {11'b0, tx} * {10'b0, o_H};       // tx*H (<=56)
	wire [13:0] col_code = o_base + tx_h + {11'b0, o_ty0};
	wire signed [11:0] col_dx = o_hflip ? -($signed({5'b0, tx}) <<< 4) : ($signed({5'b0, tx}) <<< 4);
	wire signed [11:0] col_sx = {o_xadj[10], o_xadj} + col_dx;   // signed screen x of column

	// sprite-fetch bookkeeping
	logic  [1:0] fc;                       // burst word counter (0..3)
	logic  [7:0] F0,F1,F2,F3,S0,S1,S2,S3;

	// pending line_start (engine was busy when the pulse arrived)
	logic        ls_pend;
	logic  [8:0] rl_pend;

	// ---- active-list cache ----
	// The list walk is the DOMINANT per-line cost, not the sprite fetch: measured at
	// ~16.7 clk per chain entry under full contention, so Toobin's longest observed
	// chain (65 objects, measured over 36k frames) spends ~1085 of the 2548-clk
	// line budget before a single sprite pixel is fetched -- on every line, including
	// lines with no sprite on them at all.
	//
	// That rebuild is only actually needed when the walk's INPUTS change.  What it
	// produces is scanline- and scroll-independent: the active entry holds the raw
	// object fields and toobin_mo_pos applies cur_y / xscroll / yscroll at render
	// time.  So the list is stale only after a write to MO RAM (which can change an
	// entry or a link) or a new start_link (a SLIP write mid-frame).  Toobin writes
	// MO RAM 27-51 times a frame against 384 lines (measured from captured gameplay),
	// so the walk is skipped on the large majority of lines and the worst case is
	// unchanged -- this can never be slower than always rebuilding.
	//
	// mo_dirty is SET by a write and cleared only when a rebuild BEGINS, so a write
	// landing during the walk, or on the same edge as its start, re-arms it instead
	// of being swallowed: that line renders from the list it actually built, and the
	// next line rebuilds.
	logic       list_built;
	logic       mo_dirty;
	logic [7:0] built_link;
	wire        list_stale = ~list_built | mo_dirty | (start_link != built_link);

	// ---- FSM ----
	typedef enum logic [3:0] {
		S_IDLE, S_LSTART, S_LWAIT, S_OREAD, S_OWAIT, S_POS, S_COL, S_FADDR,
		S_FDATA, S_BLIT, S_NCOL, S_NOBJ, S_WDONE, S_DONE
	} st_t;
	st_t st;
	assign list_start = (st == S_LSTART);
	assign busy = (st != S_IDLE) || al_busy;   // list-walk or line-render in progress
	assign line_done = (st == S_DONE);
	wire unused_frame_start = &{1'b0, frame_start};

	always_comb begin
		fh_row = {F3, F2, F1, F0};
		sh_row = {S3, S2, S1, S0};
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			list_built <= 1'b0; mo_dirty <= 1'b0; built_link <= 8'd0;
		end else begin
			if (mo_wr && |mo_wr_be) mo_dirty <= 1'b1;   // write wins the same edge
			else if (list_start)    mo_dirty <= 1'b0;
			if (list_start) built_link <= start_link;   // the link this build walked
			if (st == S_LWAIT && !al_busy) list_built <= 1'b1;
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= S_IDLE; lb_blit_req <= 1'b0; sprb_req <= 1'b0; ls_pend <= 1'b0;
		end else begin
			lb_blit_req <= 1'b0;
			// latch a line_start that lands while we're busy (consumed in S_IDLE below)
			if (line_start) begin ls_pend <= 1'b1; rl_pend <= render_line; end
			case (st)
				S_IDLE: if (line_start || ls_pend) begin
					cur_y <= line_start ? render_line : rl_pend;
					ls_pend <= 1'b0;
					obj    <= 8'd0;                  // S_LWAIT sets it too; harmless
					st <= list_stale ? S_LSTART : S_OREAD;
				end
				// Rebuild from live MO RAM for this scanline.  list_start is combinational
				// from S_LSTART, so u_list sees the pulse on this edge; S_LWAIT then
				// observes al_busy until the final active entry has been committed.
				S_LSTART: st <= S_LWAIT;
				S_LWAIT: if (!al_busy) begin obj <= 8'd0; st <= S_OREAD; end
				// present active-list index; entry valid after the list RAM's 1-clk read
				S_OREAD: begin
					al_index <= obj;
					if ({1'b0, obj} >= al_count) st <= S_WDONE;
					else                         st <= S_OWAIT;
				end
				S_OWAIT: st <= S_POS;
				// mo_pos is combinational off al_entry+cur_y; latch results
				S_POS: begin
					if (!p_hit) st <= S_NOBJ;
					else begin
						o_W <= p_W; o_H <= p_H; o_ty0 <= p_ty0; o_gfxrow <= p_gfxrow;
						o_xadj <= p_xadj; o_color <= e_color; o_pri <= e_pri; o_hflip <= e_hflip; o_base <= e_code;
						tx <= 3'd0; st <= S_COL;
					end
				end
				// evaluate the current column (MAME swapxy clip: break right, skip left)
				S_COL: begin
					if (col_sx > 12'sd511)        st <= S_NOBJ;   // off right => stop this object
					else if (col_sx <= -12'sd16)  st <= S_NCOL;    // off left  => skip this column
					else begin
						fc <= 2'd0; st <= S_FADDR;
					end
				end
				// issue ONE burst-4 request for this column's 16px row
				S_FADDR: begin
					sprb_addr <= {col_code, o_gfxrow};
					sprb_req  <= 1'b1;
					st <= S_FDATA;
				end
				// collect the 4 words (in order, possibly on consecutive cycles): word 0/1 =
				// first-half bytes F0..F3, word 2/3 = second-half S0..S3 (even byte = [7:0],
				// odd = [15:8] -- same order the per-byte fetch produced, so fh_row/sh_row
				// are bit-identical).
				S_FDATA: begin
					if (sprb_valid) begin
						case (fc)
							2'd0: begin F0 <= sprb_word[7:0]; F1 <= sprb_word[15:8]; end
							2'd1: begin F2 <= sprb_word[7:0]; F3 <= sprb_word[15:8]; end
							2'd2: begin S0 <= sprb_word[7:0]; S1 <= sprb_word[15:8]; end
							default: begin S2 <= sprb_word[7:0]; S3 <= sprb_word[15:8]; end
						endcase
						fc <= fc + 2'd1;
						if (fc == 2'd3) begin sprb_req <= 1'b0; st <= S_BLIT; end
					end
				end
				// kick the blit as soon as the PREVIOUS one has drained, then move straight
				// on -- the 17-clk blit runs in parallel with the next column's burst fetch
				// (the linebuf latches blit_row on accept, so F/S are free to be reloaded).
				S_BLIT: begin
					if (!lb_busy && !lb_blit_req) begin
						lb_blit_req <= 1'b1; lb_blit_x <= col_sx[10:0];
						lb_blit_color <= o_color; lb_blit_pri <= o_pri; lb_blit_hflip <= o_hflip;
						st <= S_NCOL;
					end
				end
				S_NCOL: begin
					if ({1'b0, tx} + 1'b1 >= {1'b0, o_W}) st <= S_NOBJ;
					else begin tx <= tx + 3'd1; st <= S_COL; end
				end
				S_NOBJ: begin obj <= obj + 8'd1; st <= S_OREAD; end
				// let the final blit drain before declaring the line done
				S_WDONE: if (!lb_busy && !lb_blit_req) st <= S_DONE;
				S_DONE: st <= S_IDLE;
				default: st <= S_IDLE;
			endcase
		end
	end

endmodule
