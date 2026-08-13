// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Shared Toobin' raster counter/event generator.
//
// SP-320 sheets 5-6: 640x416 total, 512x384 visible, HSYNC 544-607,
// VSYNC 388-391.  One shared counter/event source, so every consumer sees
// identical timing edges.

module toobin_raster #(
	parameter bit RESET_AT_LAST = 1'b0
)(
	input  logic       clk,
	input  logic       reset,
	input  logic       ce,
	input  logic [8:0] irq_scanline,
	output logic [9:0] h_count,
	output logic [8:0] v_count,
	output logic       hblank,
	output logic       hsync,
	output logic       vblank,
	output logic       vsync,
	output logic       scanline_match,
	output logic       vblank_start,
	output logic       vsync_start,
	output logic       frame_start
);
	localparam logic [9:0] H_ACTIVE = 10'd512, H_LAST = 10'd639;
	localparam logic [9:0] H_SYNC_BEG = 10'd544, H_SYNC_END = 10'd608;
	localparam logic [8:0] V_ACTIVE = 9'd384, V_LAST = 9'd415;
	localparam logic [8:0] V_SYNC_BEG = 9'd388, V_SYNC_END = 9'd392;

	logic [8:0] next_v;
	always_comb begin
		hblank = h_count >= H_ACTIVE;
		hsync  = (h_count >= H_SYNC_BEG) && (h_count < H_SYNC_END);
		vblank = v_count >= V_ACTIVE;
		vsync  = (v_count >= V_SYNC_BEG) && (v_count < V_SYNC_END);
		next_v = (v_count == V_LAST) ? 9'd0 : v_count + 9'd1;
	end

	always_ff @(posedge clk) begin
		scanline_match <= 1'b0;
		vblank_start   <= 1'b0;
		vsync_start    <= 1'b0;
		frame_start    <= 1'b0;
		if (reset) begin
			h_count <= RESET_AT_LAST ? H_LAST : 10'd0;
			v_count <= RESET_AT_LAST ? V_LAST : 9'd0;
		end else if (ce) begin
			if (h_count == H_LAST) begin
				h_count <= 10'd0;
				v_count <= next_v;
				scanline_match <= next_v == irq_scanline;
				vblank_start   <= next_v == V_ACTIVE;
				vsync_start    <= next_v == V_SYNC_BEG;
				frame_start    <= next_v == 9'd0;
			end else begin
				h_count <= h_count + 10'd1;
			end
		end
	end
endmodule
