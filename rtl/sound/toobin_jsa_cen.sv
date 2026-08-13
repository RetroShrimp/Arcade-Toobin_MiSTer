// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' JSA-I synchronous clock-enable generator.
//
// The audio PCB has an independent 3.579545 MHz crystal. The FPGA keeps one
// fabric clock domain and reproduces that crystal's exact average rate with a
// fractional enable: 315/88 MHz. At a 32 MHz fabric clock this is 315/2816;
// at the hardware 64 MHz fabric clock it is 315/5632. The 6502, POKEY, and
// jt51 cen_p1 enables are every other YM tick, matching the PCB divide-by-two
// chain and jt51's cen_p1 contract.
//
// This follows the fractional-enable method proven on the author's Atari
// System 2 (Paperboy) core.  It does not claim a physically independent FPGA
// clock phase; the mailbox remains the observable crossing point.

module toobin_jsa_cen #(
	parameter int CLK_MHZ = 32
) (
	input  logic clk,
	input  logic reset,
	output logic ce_ym,
	output logic ce_ym_p1,
	output logic ce_6502,
	output logic ce_pokey
);

	localparam int NUM = 315;
	localparam int DEN = 88 * CLK_MHZ;
	localparam int W   = $clog2(DEN + NUM);

	logic [W-1:0] count;
	logic [W-1:0] next_count;
	logic         ym_half;

	assign next_count = count + W'(NUM);
	assign ce_ym      = (next_count >= W'(DEN));
	assign ce_ym_p1   = ce_ym & ~ym_half;
	assign ce_6502    = ce_ym & ~ym_half;
	assign ce_pokey   = ce_ym & ~ym_half;

	always_ff @(posedge clk) begin
		if (reset) begin
			count   <= '0;
			ym_half <= 1'b0;
		end else begin
			if (ce_ym) begin
				count   <= next_count - W'(DEN);
				ym_half <= ~ym_half;
			end else begin
				count <= next_count;
			end
		end
	end

endmodule
