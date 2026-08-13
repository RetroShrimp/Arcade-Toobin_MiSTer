// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' analog-output alignment stage: CRT H-Size / H-Position and analog VGA
// H-Shift / V-Shift, following the approach in rmonic79's Arcade-Raiden_MiSTer.
//
// Sits between toobin_core and arcade_video, so everything downstream (mixer,
// scandoubler, gamma, video_freak) sees the adjusted raster and the adjusted
// pixel enable.  None of it touches the core's own timing: the pixel clock and
// the native sync rates are untouched, so there is no jitter and nothing the
// game can observe.
//
//   H-Shift / V-Shift  move the SYNC relative to the picture, by tapping a
//                      delayed copy of HSync (per pixel) or VSync (per line).
//                      This is what re-centres the image on an analog display.
//   H-Position         moves the PICTURE inside an untouched HSync, so it can
//                      never desync a monitor.
//   H-Size             resamples the line at a slightly different rate, making
//                      every pixel wider or narrower by the same exact integer
//                      number of clocks (see analog_hsize.sv).
//
// All four OSD fields are plain two's complement, so the config string just
// lists 0,+1..+max then -min..-1 and the decode is a $signed() -- no bespoke
// mapping to get out of step with the menu text.
//
// NOTE on H-Size and the read rate.  Upstream's accumulator counts quarter
// clocks because Raiden's pixel period is 16 clk_sys cycles.  Ours is 4
// (ce_pix = clk_sys/4 at 64 MHz), so counting quarters would make one OSD step
// 6.25% instead of 1.56%.  The accumulator below counts 1/CLK_PER_PIX-th of a
// clock instead, which keeps the same 1/64 = 1.56% step per OSD click:
//
//     period = 64 + hsize   units, where 64 units == CLK_PER_PIX clocks
//     acc   += 64/CLK_PER_PIX  per clock
//
// so hsize spans 48..79 units = 3.00..4.94 clocks per pixel at CLK_PER_PIX=4.

module toobin_analog_adjust #(
	parameter int H_TOTAL     = 640,   // ce_pix ticks per line (toobin_raster H_LAST+1)
	parameter int V_TOTAL     = 416,   // lines per frame       (toobin_raster V_LAST+1)
	parameter int CLK_PER_PIX = 4      // clk_sys cycles per ce_pix
) (
	input  logic       clk,
	input  logic       ce_pix,

	// OSD, all two's complement
	input  logic [4:0] osd_hsize,      // CRT H-Size        +15 / -16
	input  logic [6:0] osd_hpos,       // CRT H-Position    +63 / -64
	input  logic [5:0] osd_hshift,     // Analog VGA H-Shift +31 / -32
	input  logic [5:0] osd_vshift,     // Analog VGA V-Shift +31 / -32

	input  logic [7:0] r_in, g_in, b_in,
	input  logic       hs_in, vs_in, hb_in, vb_in,

	output logic [7:0] r_out, g_out, b_out,
	output logic       hs_out, vs_out, hb_out, vb_out,
	output logic       ce_out
);

	localparam [7:0]  ACC_STEP = 64 / CLK_PER_PIX;
	localparam [15:0] HT       = H_TOTAL;
	localparam [15:0] VT       = V_TOTAL;
	localparam int    HTW      = $clog2(H_TOTAL);   // 10 bits for 640
	localparam int    VTW      = $clog2(V_TOTAL);   //  9 bits for 416

	// ---------------- H-Shift: delay HSync by N pixels ----------------
	// A negative shift is a delay of H_TOTAL-|N|, i.e. the sync from the previous
	// line, which is why the shift register has to span a whole line.
	logic [5:0] hshift_d;
	always_ff @(posedge clk) if (ce_pix) hshift_d <= osd_hshift;
	wire        hsh_neg = hshift_d[5];
	wire  [5:0] hsh_mag = hsh_neg ? (6'd0 - hshift_d) : hshift_d;
	wire [15:0] hshift_wide = hsh_neg ? (HT - {10'd0, hsh_mag}) : {10'd0, hsh_mag};
	wire [HTW-1:0] hshift_tap = hshift_wide[HTW-1:0];   // < H_TOTAL by construction

	logic [H_TOTAL-1:0] hs_shreg;
	logic               hs_shifted;
	always_ff @(posedge clk) if (ce_pix) begin
		hs_shreg   <= {hs_shreg[H_TOTAL-2:0], hs_in};
		hs_shifted <= (hshift_tap == '0) ? hs_in : hs_shreg[hshift_tap - 1'b1];
	end

	// ---------------- V-Shift: delay VSync by N lines ----------------
	logic hs_in_d;
	always_ff @(posedge clk) if (ce_pix) hs_in_d <= hs_in;
	wire  line_tick = ce_pix & hs_in & ~hs_in_d;

	logic [5:0] vshift_d;
	always_ff @(posedge clk) if (line_tick) vshift_d <= osd_vshift;
	wire        vsh_neg = vshift_d[5];
	wire  [5:0] vsh_mag = vsh_neg ? (6'd0 - vshift_d) : vshift_d;
	wire [15:0] vshift_wide = vsh_neg ? (VT - {10'd0, vsh_mag}) : {10'd0, vsh_mag};
	wire [VTW-1:0] vshift_tap = vshift_wide[VTW-1:0];   // < V_TOTAL by construction

	logic [V_TOTAL-1:0] vs_shreg;
	logic               vs_shifted;
	always_ff @(posedge clk) if (line_tick) begin
		vs_shreg   <= {vs_shreg[V_TOTAL-2:0], vs_in};
		vs_shifted <= (vshift_tap == '0) ? vs_in : vs_shreg[vshift_tap - 1'b1];
	end

	// ---------------- H-Size: read-rate accumulator ----------------
	logic signed [4:0] hsize_s;
	always_ff @(posedge clk) if (ce_pix) hsize_s <= osd_hsize;
	wire hsize_active = (hsize_s != 5'sd0);

	wire  [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};   // 48..79
	logic [7:0] rd_acc;
	wire        rd_tick = (rd_acc + ACC_STEP) >= rd_period;

	// Re-phase the read on the sync we actually emit, so H-Shift and H-Size stay
	// consistent with each other rather than drifting apart.
	logic hs_shifted_d;
	always_ff @(posedge clk) hs_shifted_d <= hs_shifted;
	wire  shifted_hs_rise = hs_shifted & ~hs_shifted_d;

	always_ff @(posedge clk) begin
		if      (shifted_hs_rise) rd_acc <= 8'd0;
		else if (rd_tick)         rd_acc <= rd_acc + ACC_STEP - rd_period;
		else                      rd_acc <= rd_acc + ACC_STEP;
	end

	wire rd_ce = hsize_active ? rd_tick : ce_pix;

	// ---------------- H-Position ----------------
	logic signed [8:0] hoffset;
	always_ff @(posedge clk) if (ce_pix) hoffset <= {{2{osd_hpos[6]}}, osd_hpos};

	// ---------------- resampler ----------------
	// Fed the SHIFTED syncs, so its bypass path carries H/V-Shift through
	// unchanged and there is only one output path to reason about.
	analog_hsize #(.AW(11)) u_hsize (
		.clk      (clk),
		.pxl_cen  (ce_pix),
		.pxl2_cen (rd_ce),
		.hsize    (hsize_s),
		.hoffset  (hoffset),
		.r_in     (r_in), .g_in (g_in), .b_in (b_in),
		.hs_in    (hs_shifted),
		.vs_in    (vs_shifted),
		.hb_in    (hb_in | vb_in),
		.vb_in    (vb_in),
		.r_out    (r_out), .g_out (g_out), .b_out (b_out),
		.hs_out   (hs_out), .vs_out (vs_out),
		.hb_out   (hb_out), .vb_out (vb_out)
	);

	assign ce_out = rd_ce;

endmodule
