// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// Toobin' CPU-program-ROM SDRAM adapter.
//
// Bridges the main-bus ROM read (held `rom_req` with a byte address + a level
// `rom_ready`/`rom_rdata` that gates DTACK) to the toobin_gfx_mem CPU read client
// (req/valid, 16-bit word).  The 68010 program ROM occupies 0x000000-0x07FFFF
// (512 KB = 256 K words), so the word index is cpu byte-addr[18:1].
//
// The main bus holds `rom_req` for the whole access and its DTACK is
// `cpu_req & rom_ready`, so this adapter issues ONE gfx_mem read per access, latches
// the word, raises `rom_ready`, and holds it until the access ends (`rom_req` drops).
// Variable SDRAM latency + video contention just stretch the DTACK wait -- exactly
// what the async TG68K bus tolerates.

module toobin_cpurom_sdram
(
	input  logic        clk,
	input  logic        reset,

	// ---- main-bus side ----
	input  logic        rom_req,        // cpu_req & (rd_region==REG_ROM) & cpu_rw
	input  logic [18:0] rom_byte_addr,  // cpu_addr[18:0] within the ROM region
	output logic [15:0] rom_rdata,
	output logic        rom_ready,

	// ---- gfx_mem CPU client ----
	output logic        cpu_req,
	output logic [17:0] cpu_addr,
	input  logic        cpu_valid,
	input  logic [15:0] cpu_data
);

	typedef enum logic [1:0] { C_IDLE, C_REQ, C_DONE } cstate_t;
	cstate_t st;

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= C_IDLE; cpu_req <= 1'b0; rom_ready <= 1'b0;
		end else begin
			case (st)
				C_IDLE: begin
					rom_ready <= 1'b0;
					if (rom_req) begin
						cpu_addr <= rom_byte_addr[18:1];   // byte -> word index
						cpu_req  <= 1'b1;
						st       <= C_REQ;
					end
				end
				C_REQ: begin
					if (cpu_valid) begin
						rom_rdata <= cpu_data;
						cpu_req   <= 1'b0;
						rom_ready <= 1'b1;
						st        <= C_DONE;
					end
				end
				// hold rom_ready (DTACK) until the CPU ends the access
				C_DONE: begin
					if (!rom_req) begin rom_ready <= 1'b0; st <= C_IDLE; end
				end
				default: st <= C_IDLE;
			endcase
		end
	end

	wire unused = &{1'b0, rom_byte_addr[0]};   // A0 comes from UDS/LDS, not the word index

endmodule
