// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' playfield renderer with a DOUBLE-BUFFERED full-line SDRAM tile prefetch.
//
// The tile ROM is in SDRAM (variable, ~20-clk latency), so tiles can't be fetched per
// pixel.  A design that races a per-column 8-entry buffer just ahead of the beam
// stalls/skips columns at the real pixel rate + read latency + refresh (garbage on
// hardware).  This version instead PING-PONGS two full-line buffers:
// a self-timed sequential fetch fills the BACK buffer for the NEXT display line (all needed
// tile columns) while the display reads the FRONT buffer for the current line; they swap at
// each line boundary.  It fetches the 68 tile columns needed for the visible line plus
// asymmetric horizontal-scroll margins.  A scroll jump outside that retained
// window restarts only the 68-column back-buffer fetch; rev-3's two large jumps
// occur early enough in the line for that bounded refetch.  CPU writes to an already-prefetched tile in
// the following display row set a dirty-column bit; after the base fetch, that one tile
// row is fetched again before it reaches the beam.  Expanding this to all 128 world columns was measured to
// starve the real-ROM CPU and trip the hardware watchdog, so that approach is forbidden.
//
// PF RAM: port A = 68010 r/w + read-back; port B = fetch read.  Line buffer: a 2x128 dpram
// (buffer-select MSB), port A = fetch write, port B = display read (1-ce latency).

module toobin_pf_render #(
	parameter [9:0] V_LAST = 10'd415        // last raster line (for the fetch-line frame wrap)
)(
	input  logic        clk,
	input  logic        ce,         // pixel enable (display pipeline); fetch runs full-rate
	input  logic        reset,
	// playfield RAM CPU port (32-bit, byte enables) + read-back
	input  logic        pf_wr,
	input  logic [12:0] pf_wr_addr,
	input  logic [31:0] pf_wr_data,
	input  logic  [3:0] pf_wr_be,
	output logic [31:0] pf_rdata,
	// tile ROM fetch (reorganized 32-bit {D,C,B,A}, index code*8+row; req/valid)
	output logic        tile_req,
	output logic [16:0] tile_addr,
	input  logic        tile_valid,
	input  logic [31:0] tile_data,
	// scroll (pixels, reg>>6)
	input  logic  [9:0] scrollx,
	input  logic  [9:0] scrolly,
	// display raster + fetch-ahead raster (fhpos/fvpos kept for port compatibility, unused now)
	input  logic  [9:0] hpos,
	input  logic  [9:0] vpos,
	input  logic  [9:0] fhpos,
	input  logic  [9:0] fvpos,
	// output (valid 3 clks after the matching hpos/vpos)
	output logic  [9:0] pen,
	output logic        pen3,
	output logic  [1:0] category,
	output logic  [9:0] hpos_out,
	output logic  [9:0] vpos_out
);

	// 512 visible pixels = 64 tiles; four margin columns cover fine-scroll and
	// pipeline look-ahead without consuming the CPU's SDRAM service window.
	localparam int NCOL = 68;

	// ================= line boundary =================
	// swap buffers + restart the fetch at the start of each display line (hpos wraps to 0)
	logic [9:0] hpos_d;
	always_ff @(posedge clk) begin
		if (reset) hpos_d <= 10'd0;
		else if (ce) hpos_d <= hpos;
	end
	wire line_start = ce && (hpos == 10'd0) && (hpos_d != 10'd0);

	// Sheet 14 clocks HSCROLL on the following scanline.  Keep writes pending for
	// the rest of the current line and switch the display counter at hpos 0.
	logic [9:0] scrollx_pending, scrollx_active;
	always_ff @(posedge clk) begin
		if (reset) begin
			scrollx_pending <= 10'd0;
			scrollx_active  <= 10'd0;
		end else begin
			if (scrollx != scrollx_pending) scrollx_pending <= scrollx;
			if (line_start)                 scrollx_active  <= scrollx_pending;
		end
	end
	wire [9:0] display_scrollx = line_start ? scrollx_pending : scrollx_active;
	// ================= PF RAM (fetch reads port B; CPU r/w + read-back port A) =================
	logic wrbuf;                       // buffer being filled (back); front = ~wrbuf
	logic [6:0] fcol;                  // sequential fetch column counter (0..NCOL-1)
	logic [6:0] fbase_col;             // captured, fixed base for this line fetch
	logic [10:0] frow_sy;              // scrolled fetch row = fetch_line + scrolly (captured @line_start)
	logic fdone;
	typedef enum logic [1:0] { F_IDLE, F_PF, F_GFX } fstate_t;
	fstate_t fst;

	// Two columns behind + one ahead cover the 65 columns a fine-scrolled
	// 512-pixel line can expose.  One-pixel late writes, including a tile-boundary
	// crossing, remain in the already-fetched window without extra SDRAM traffic.
	localparam logic [6:0] LEFT_MARGIN = 7'd2;
	wire [6:0] main_FC = fbase_col + fcol;
	// If a write jumps farther than the retained [fbase..fbase+67] window can
	// display, restart the bounded back-buffer fetch at the new base.  Never abort
	// an accepted SDRAM request: hold it through tile_valid, discard that stale
	// row, then restart.  This preserves gfx_mem's req/drop handshake.
	logic       scroll_refetch_pending;
	logic [6:0] scroll_refetch_base;
	wire [6:0] scroll_window_delta = scrollx[9:3] - fbase_col;
	wire       large_scroll_change = (scrollx != scrollx_pending) && (scroll_window_delta > 7'd3);
	wire [6:0] requested_refetch_base = large_scroll_change
	                                      ? (scrollx[9:3] - LEFT_MARGIN)
	                                      : scroll_refetch_base;
	wire       need_scroll_refetch = large_scroll_change | scroll_refetch_pending;
	wire [6:0] dirty_window_base = need_scroll_refetch ? requested_refetch_base : fbase_col;
	wire [6:0] pf_wr_window_delta = pf_wr_addr[6:0] - dirty_window_base;
	wire       pf_wr_in_window = pf_wr_window_delta < 7'(NCOL);

	// Dirty columns repair PF RAM writes that land after their base prefetch.
	// A priority encoder chooses one world column at a time once the 68-column
	// fetch is complete.  Both 16-bit halves of a tile simply leave/set the same bit.
	logic [127:0] dirty_col_bits;
	logic [6:0] dirty_col;
	integer di;
	always_comb begin
		dirty_col = 7'd0;
		for (di = 127; di >= 0; di = di - 1)
			if (dirty_col_bits[di]) dirty_col = 7'(di);
	end
	wire service_dirty = fdone && (|dirty_col_bits);
	wire [6:0] candidate_col = service_dirty ? dirty_col : main_FC;
	logic [6:0] active_col;
	logic       active_repair;
	logic       active_buf;
	wire [12:0] pf_faddr = {frow_sy[8:3], (fst == F_IDLE) ? candidate_col : active_col};
	logic [31:0] pf_q;
	toobin_dpram #(.DW(32), .AW(13)) u_pfram (
		.clk(clk),
		.a_addr(pf_wr_addr), .a_din(pf_wr_data), .a_we(pf_wr ? pf_wr_be : 4'b0), .a_dout(pf_rdata),
		.b_addr(pf_faddr),   .b_din(32'b0),      .b_we(4'b0), .b_re(1'b1),       .b_dout(pf_q) );

	// ================= tile decode + line buffer (2 x 128 x {cat,flipx,color,pixrow}) =========
	logic [31:0] dec_pixrow;
	toobin_tile_dec u_tile (
		.A(tile_data[7:0]),   .B(tile_data[15:8]),
		.C(tile_data[23:16]), .D(tile_data[31:24]), .pixrow(dec_pixrow) );

	logic  [3:0] f_color; logic f_flipx; logic [1:0] f_cat;   // captured from pf_q for the tile in flight
	logic        lb_wr;   logic [7:0] lb_waddr; logic [39:0] lb_wdata;
	wire  [10:0] dsx  = {1'b0, hpos} + {1'b0, display_scrollx};
	wire  [39:0] lb_rdata;
	// display reads the FRONT buffer (~wrbuf).  On the swap cycle (line_start) wrbuf is about
	// to toggle, so the new front is the current wrbuf value -> select it directly, else the
	// hpos=0 pixel would read the previous line's buffer.
	wire  disp_sel = line_start ? wrbuf : ~wrbuf;
	wire [39:0] lb_adout_nc;   // port-A read-back unused (fetch write only)
	toobin_dpram #(.DW(40), .AW(8)) u_linebuf (
		.clk(clk),
		.a_addr(lb_waddr), .a_din(lb_wdata), .a_we(lb_wr ? 5'h1F : 5'h00), .a_dout(lb_adout_nc),
		.b_addr({disp_sel, dsx[9:3]}), .b_din(40'b0), .b_we(5'h00), .b_re(ce), .b_dout(lb_rdata) );

	// ================= fetch FSM (sequential, self-timed) =================
	wire  [9:0] fetch_line = (vpos == V_LAST) ? 10'd0 : vpos + 10'd1;   // next display line (wrapped)
	wire  [2:0] frow_flip  = pf_q[15] ? ~frow_sy[2:0] : frow_sy[2:0];   // flip-Y

	always_ff @(posedge clk) begin
		if (reset) begin
			fst <= F_IDLE; tile_req <= 1'b0; wrbuf <= 1'b0; fcol <= 7'd0; fdone <= 1'b1; lb_wr <= 1'b0;
			fbase_col <= 7'd0; dirty_col_bits <= 128'd0;
			active_col <= 7'd0; active_repair <= 1'b0; active_buf <= 1'b0;
			scroll_refetch_pending <= 1'b0; scroll_refetch_base <= 7'd0;
		end else begin
			lb_wr <= 1'b0;
			if (line_start) begin
				wrbuf   <= ~wrbuf;                                   // ping-pong: filled buffer -> display
				fcol    <= 7'd0; fdone <= 1'b0; fst <= F_IDLE; tile_req <= 1'b0;
				frow_sy <= {1'b0, fetch_line} + {1'b0, scrolly};    // scrolled row of the line to fetch
				fbase_col <= scrollx_pending[9:3] - LEFT_MARGIN;
				dirty_col_bits <= 128'd0;
				scroll_refetch_pending <= 1'b0;
			end else begin
				if (pf_wr && (pf_wr_addr[12:7] == frow_sy[8:3]) && pf_wr_in_window)
					dirty_col_bits[pf_wr_addr[6:0]] <= 1'b1;

				if (need_scroll_refetch && fst != F_GFX) begin
					fbase_col <= requested_refetch_base;
					fcol <= 7'd0; fdone <= 1'b0; fst <= F_IDLE; tile_req <= 1'b0;
					scroll_refetch_pending <= 1'b0;
				end else if (need_scroll_refetch) begin
					// F_GFX owns an accepted request.  Keep req asserted until its
					// response, but remember the newest requested base meanwhile.
					if (large_scroll_change) begin
						scroll_refetch_pending <= 1'b1;
						scroll_refetch_base <= requested_refetch_base;
					end
					if (tile_valid) begin
						tile_req <= 1'b0; fst <= F_IDLE; fcol <= 7'd0; fdone <= 1'b0;
						fbase_col <= requested_refetch_base;
						scroll_refetch_pending <= 1'b0;
					end
				end else begin
					// Consuming a queued repair clears it.  A simultaneous CPU write
					// is applied above and therefore wins, causing a final refetch.
					if (fst == F_IDLE && service_dirty)
						dirty_col_bits[dirty_col] <= 1'b0;

				case (fst)
					F_IDLE: if (!fdone || service_dirty) begin
						active_col    <= candidate_col;
						active_repair <= service_dirty;
						active_buf    <= wrbuf;
						fst <= F_PF;                                   // pf_q arrives next clk
					end
					F_PF: begin
						f_color   <= pf_q[19:16];
						f_flipx   <= pf_q[14];
						f_cat     <= pf_q[21:20];
						tile_addr <= {pf_q[13:0], frow_flip};      // code*8 + row
						tile_req  <= 1'b1;
						fst <= F_GFX;
					end
					F_GFX: if (tile_valid) begin
						lb_wr    <= 1'b1;                             // write the decoded row into the back buffer
						lb_waddr <= {active_buf, active_col};
						lb_wdata <= {1'b0, f_cat, f_flipx, f_color, dec_pixrow};
						tile_req <= 1'b0;
						if (active_repair) fst <= F_IDLE;
						else if (fcol == 7'(NCOL-1)) begin fdone <= 1'b1; fst <= F_IDLE; end
						else begin fcol <= fcol + 7'd1; fst <= F_IDLE; end
					end
					default: fst <= F_IDLE;
				endcase
				end
			end
		end
	end

	// ================= display pipeline (3-ce, matches alpha) =================
	// s0: present line-buffer read {front, dsx[9:3]}, carry sub-tile x + coords
	logic [2:0] cx0; logic [9:0] h0, v0;
	always_ff @(posedge clk) if (ce) begin cx0 <= dsx[2:0]; h0 <= hpos; v0 <= vpos; end
	// s1: line-buffer data valid -> unpack, resolve flipx, register
	wire [31:0] r_pixrow = lb_rdata[31:0];
	wire  [3:0] r_color  = lb_rdata[35:32];
	wire        r_flipx  = lb_rdata[36];
	wire  [1:0] r_cat    = lb_rdata[38:37];
	logic [31:0] pr2; logic [3:0] col2; logic [1:0] cat2; logic [2:0] cxe2; logic [9:0] h2, v2;
	always_ff @(posedge clk) if (ce) begin
		pr2 <= r_pixrow; col2 <= r_color; cat2 <= r_cat;
		cxe2 <= r_flipx ? ~cx0 : cx0; h2 <= h0; v2 <= v0;
	end
	// s2: pixel select -> pen
	wire [3:0] pixv = pr2[cxe2*4 +: 4];
	always_ff @(posedge clk) if (ce) begin
		pen      <= {2'b00, col2, pixv};
		pen3     <= pixv[3];
		category <= cat2;
		hpos_out <= h2;
		vpos_out <= v2;
	end

	// deliberately-unused legacy fetch-raster inputs (fetch now owns its own counter)
	wire unused = &{1'b0, fhpos, fvpos, dsx[10], lb_adout_nc, frow_sy[10:9], pf_q[31:22], lb_rdata[39]};

endmodule
