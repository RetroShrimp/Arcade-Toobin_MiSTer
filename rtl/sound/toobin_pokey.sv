// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' POKEY wrapper: the POKEY core (rtl/lib/POKEY) + the 6502 write
// bridge.  Per MAME atarijsa.cpp the JSA-I POKEY sits at 0x2C00-0x2C0F.  Wiring
// mirrors the System-1 AUDIO.vhd instantiation (CS='1', CS_L=select, RW_L=r/w,
// ENA=clock enable, PIN=0).  Writes are latched and held (CS_L=0, RW_L=0) until an
// ENA pulse consumes them; reads present the address directly (DOUT is the reg).

module toobin_pokey
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ena,          // POKEY clock enable (~1.789 MHz)
	// bus side (from toobin_jsa_bus)
	input  logic        pk_cs,
	input  logic  [3:0] pk_addr,
	input  logic        pk_we,
	input  logic        pk_rd,
	input  logic  [7:0] pk_dout,      // 6502 -> POKEY
	output logic  [7:0] pk_din,       // POKEY -> 6502
	// audio
	output logic signed [10:0] audio_out
);

	// ---- write-pending bridge ----
	logic       wr_pend;
	logic [3:0] wr_a;
	logic [7:0] wr_d;
	always_ff @(posedge clk) begin
		if (reset) wr_pend <= 1'b0;
		else if (pk_cs & pk_we) begin wr_pend <= 1'b1; wr_a <= pk_addr; wr_d <= pk_dout; end
		else if (wr_pend & ena)  wr_pend <= 1'b0;
	end

	wire        rd_active = pk_cs & pk_rd;
	wire        cs_l = ~(wr_pend | rd_active);   // active-low select
	wire        rw_l = wr_pend ? 1'b0 : 1'b1;    // write while pending, else read
	wire  [3:0] addr = wr_pend ? wr_a : pk_addr;

	POKEY u_pokey (
		.ADDR      (addr),
		.DIN       (wr_d),
		.DOUT      (pk_din),
		.DOUT_OE_L (),
		.RW_L      (rw_l),
		.CS        (1'b1),
		.CS_L      (cs_l),
		.AUDIO_OUT (audio_out),
		.PIN       (8'h00),
		.ENA       (ena),
		.RESET_L   (~reset),
		.CLK       (clk)
	);

endmodule
