// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' YM2151 wrapper: jt51 core + the fast-6502 -> slow-YM write bridge.
//
// The 6502 writes the YM at bus speed but jt51 captures `write = !cs_n & !wr_n`
// on cen_p1 (the register clock).  So latch each 6502 YM write (a0 + data) into a
// pending register and hold cs_n/wr_n asserted until a cen_p1 pulse consumes it.
// Reads return jt51's status (dout) directly.  Audio = jt51 full-resolution out.

module toobin_ym
(
	input  logic        clk,
	input  logic        reset,
	input  logic        cen,        // YM2151 clock enable (~3.579545 MHz)
	input  logic        cen_p1,     // half-rate enable (register capture)
	input  logic        ym_reset_n, // WRIO bit0 (/RESET, active low)

	// bus side (from toobin_jsa_bus)
	input  logic        ym_cs,      // access this cycle
	input  logic        ym_a0,      // register select
	input  logic        ym_we,      // write strobe (one bus cycle)
	input  logic  [7:0] ym_dout,    // 6502 -> YM data
	output logic  [7:0] ym_din,     // YM status -> 6502

	// audio + peripheral
	output logic        sample,
	output logic signed [15:0] aud_left,
	output logic signed [15:0] aud_right,
	output logic signed [15:0] aud_left_lo,
	output logic signed [15:0] aud_right_lo,
	output logic        ct1,
	output logic        ct2,
	output logic        ym_irq      // active-high YM timer IRQ (JSA wires /IRQ into the shared
	                                // 6502 IRQ net -- sheet p104)
);

	// ---- write-pending bridge ----
	logic       wr_pend, wr_a0;
	logic [7:0] wr_d;
	always_ff @(posedge clk) begin
		if (reset) wr_pend <= 1'b0;
		else if (ym_cs & ym_we) begin      // capture the 6502 write
			wr_pend <= 1'b1; wr_a0 <= ym_a0; wr_d <= ym_dout;
		end else if (wr_pend & cen_p1) begin
			wr_pend <= 1'b0;               // jt51 consumed it on cen_p1
		end
	end

	wire irq_n;
	assign ym_irq = ~irq_n;

	jt51 u_jt51 (
		.rst    (reset | ~ym_reset_n),
		.clk    (clk),
		.cen    (cen),
		.cen_p1 (cen_p1),
		.cs_n   (~wr_pend),
		.wr_n   (~wr_pend),
		.a0     (wr_a0),
		.din    (wr_d),
		.dout   (ym_din),
		.ct1    (ct1),
		.ct2    (ct2),
		.irq_n  (irq_n),
		.sample (sample),
		.left   (aud_left_lo),
		.right  (aud_right_lo),
		.xleft  (aud_left),
		.xright (aud_right)
	);

endmodule
