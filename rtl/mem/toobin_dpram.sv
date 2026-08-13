// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' generic dual-port RAM with per-byte write enables.
//
// Inferred true dual-port block RAM (Quartus M10K), single clock (the whole core
// is one clock domain with enables; no separate CPU/video clocks).
// Two ports share one memory:
//   port A = CPU side, byte-lane writes via `a_we` (one bit per byte) so a
//            68010 UDS/LDS byte write never clobbers the sibling byte,
//   port B = video / second master (read, plus `b_we` for RAMs the video side
//            also writes).
// Both writes + both reads live in ONE clocked block (Verilator-clean true
// dual-port). Same-address same-cycle A+B write: port B wins (never exercised —
// CPU and video address different regions/lanes).
//
// DW must be a multiple of 8; the write-enable vector is one bit per byte.

module toobin_dpram #(
	parameter int DW = 16,          // data width (multiple of 8)
	parameter int AW = 13           // address width (words)
)(
	input  logic                 clk,
	// port A (CPU)
	input  logic [AW-1:0]        a_addr,
	input  logic [DW-1:0]        a_din,
	input  logic [DW/8-1:0]      a_we,
	output logic [DW-1:0]        a_dout,
	// port B (video / second master)
	input  logic [AW-1:0]        b_addr,
	input  logic [DW-1:0]        b_din,
	input  logic [DW/8-1:0]      b_we,
	input  logic                 b_re,      // port-B read clock-enable (1 = full-rate; use a
	                                        //   pixel-enable for a display read that must have
	                                        //   1-CE latency, not 1-clk). Still infers M10K (rden).
	output logic [DW-1:0]        b_dout
);

	localparam int NB = DW/8;
	logic [DW-1:0] mem [0:(1<<AW)-1];

	// Power-up to 0.  In Quartus the M10K powers to 0 on config; the explicit loop is
	// sim-only (keeps iverilog/verilator free of X) and is skipped during synthesis
	// (>5000 iterations exceed Quartus's loop-unroll limit).
`ifndef ALTERA_RESERVED_QIS
	initial begin
		for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
	end
`endif

	always_ff @(posedge clk) begin
		for (int i = 0; i < NB; i++) begin
			if (a_we[i]) mem[a_addr][i*8 +: 8] <= a_din[i*8 +: 8];
			if (b_we[i]) mem[b_addr][i*8 +: 8] <= b_din[i*8 +: 8];
		end
		a_dout <= mem[a_addr];
		if (b_re) b_dout <= mem[b_addr];
	end

endmodule
