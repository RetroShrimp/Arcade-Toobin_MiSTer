// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// Toobin' graphics/CPU-ROM memory subsystem: arbitrates the SDRAM read clients plus
// the loader write port onto the single-port toobin_sdram controller, and adapts each
// client's data width to the controller's 16-bit word.
//
//   * MO column : four consecutive 16-bit words (one 16px sprite row, load-time
//                 repacked)                     -> ONE burst-4 read, 4 valid pulses.
//   * PF tiles  : 32-bit reorganized {D,C,B,A} row -> ONE burst-2 read
//                 (low word {B,A} at 2*idx, high word {D,C} at 2*idx+1) assembled.
//   * MO byte   : one byte from the 2 MB ROM       -> ONE 16-bit read + byte select
//                 (unused by the game path, which uses the column client above).
//   * CPU ROM   : one 16-bit word                  -> ONE read, 1:1.
//   * Loader    : one 16-bit word write            -> ONE write (word address already
//                 region-offset + reorganized by the loader-writer upstream).
//
// Fixed priority write > MO column > tile > MO byte > CPU.  The MO column client is
// above tiles because the sprite line renderer has a hard per-scanline deadline, while
// the playfield line prefetch only needs its 68 fetches to complete somewhere within
// the whole line (it fills a full-line buffer displayed one line later) -- it tolerates
// interleaving.  The CPU sits last: its async DTACK stretches harmlessly.
//
// Controller contract (toobin_sdram): when `ready` is high, pulse `req` for one cycle
// with addr/we/blen(/wdata); read data returns on `rdata` with one `valid` pulse per
// word (consecutive cycles for a burst); `ready` returns high when the access
// completes.  The controller latches a coincident-refresh request internally, so a
// single-cycle req pulse after observing `ready` is safe.

module toobin_gfx_mem #(
	parameter int AW = 24,
	parameter logic [AW-1:0] CPU_BASE  = 24'h000000,   // 256K words (512 KB)
	parameter logic [AW-1:0] TILE_BASE = 24'h040000,   // 256K words (512 KB, 2 words/tile-row)
	parameter logic [AW-1:0] SPR_BASE  = 24'h080000    // 1M   words (2 MB)
)(
	input  logic          clk,
	input  logic          reset,

	// ---- MO sprite-column client (burst-4: one 16px row per request) ----
	input  logic          sprb_req,
	input  logic [17:0]   sprb_addr,     // {code[13:0], gfxrow[3:0]} -> 4 words at SPR_BASE + addr*4
	output logic          sprb_valid,    // 4 pulses per request, words in order
	output logic [15:0]   sprb_word,

	// ---- PF tile client (32-bit reorganized row) ----
	input  logic          tile_req,
	input  logic [16:0]   tile_addr,     // {code[13:0], row[2:0]}
	output logic          tile_valid,
	output logic [31:0]   tile_data,

	// ---- MO sprite byte client (unused by the game path) ----
	input  logic          spr_req,
	input  logic [20:0]   spr_addr,      // byte address into 2 MB
	output logic          spr_valid,
	output logic [7:0]    spr_data,      // selected byte (spr_addr[0])
	output logic [15:0]   spr_word,      // full 16-bit word

	// ---- CPU ROM client (16-bit word) ----
	input  logic          cpu_req,
	input  logic [17:0]   cpu_addr,      // word address into 512 KB
	output logic          cpu_valid,
	output logic [15:0]   cpu_data,

	// ---- loader write port (16-bit word; addr already in SDRAM word space) ----
	input  logic          dl_wr,
	input  logic [AW-1:0] dl_waddr,
	input  logic [15:0]   dl_wdata,
	output logic          dl_ack,

	// ---- SDRAM controller port ----
	output logic          sd_req,
	output logic [AW-1:0] sd_addr,
	output logic          sd_we,
	output logic [1:0]    sd_blen,
	output logic [15:0]   sd_wdata,
	input  logic          sd_ready,
	input  logic          sd_valid,
	input  logic [15:0]   sd_rdata
);

	typedef enum logic [1:0] { G_IDLE, G_REQ, G_WAIT, G_HOLD } gstate_t;
	gstate_t st;

	typedef enum logic [2:0] { OP_WR, OP_SPRB, OP_TILE, OP_SPR, OP_CPU } op_t;
	op_t op;

	logic [1:0]  wcnt;       // burst word counter (sprb: 0..3, tile: 0..1)
	logic        sbyte;      // sprite byte select (spr_addr[0])
	logic [15:0] tlo;        // captured tile low word

	// word addresses: base + field.  tile row = 2 consecutive words at base + (idx<<1);
	// sprite column row = 4 consecutive words at base + (addr<<2) (loader repack).
	wire [AW-1:0] sprb_wa  = SPR_BASE  + {{(AW-20){1'b0}}, sprb_addr, 2'b00};
	wire [AW-1:0] tile_wa0 = TILE_BASE + {{(AW-18){1'b0}}, tile_addr, 1'b0};
	wire [AW-1:0] spr_wa   = SPR_BASE  + {{(AW-20){1'b0}}, spr_addr[20:1]};
	wire [AW-1:0] cpu_wa   = CPU_BASE  + {{(AW-18){1'b0}}, cpu_addr};

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= G_IDLE; sd_req <= 1'b0; sd_we <= 1'b0; sd_blen <= 2'd0;
			sprb_valid <= 1'b0; tile_valid <= 1'b0; spr_valid <= 1'b0; cpu_valid <= 1'b0; dl_ack <= 1'b0;
		end else begin
			sprb_valid <= 1'b0; tile_valid <= 1'b0; spr_valid <= 1'b0; cpu_valid <= 1'b0; dl_ack <= 1'b0;
			sd_req <= 1'b0;
			case (st)
				// -------- pick a client (write > MO column > tile > MO byte > CPU) --------
				G_IDLE: begin
					wcnt <= 2'd0;
					if (dl_wr) begin
						op <= OP_WR;  sd_addr <= dl_waddr; sd_we <= 1'b1; sd_blen <= 2'd0; sd_wdata <= dl_wdata;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (sprb_req) begin
						op <= OP_SPRB; sd_addr <= sprb_wa; sd_we <= 1'b0; sd_blen <= 2'd3;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (tile_req) begin
						op <= OP_TILE; sd_addr <= tile_wa0; sd_we <= 1'b0; sd_blen <= 2'd1;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (spr_req) begin
						op <= OP_SPR; sbyte <= spr_addr[0]; sd_addr <= spr_wa; sd_we <= 1'b0; sd_blen <= 2'd0;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (cpu_req) begin
						op <= OP_CPU; sd_addr <= cpu_wa; sd_we <= 1'b0; sd_blen <= 2'd0;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end
				end
				// -------- req asserted for exactly this cycle; controller captures it --------
				G_REQ: begin
					sd_req <= 1'b0; sd_we <= 1'b0;
					st <= G_WAIT;
				end
				// -------- await completion (burst words arrive on consecutive sd_valid) --------
				G_WAIT: begin
					if (op == OP_WR) begin
						if (sd_ready) begin dl_ack <= 1'b1; st <= G_HOLD; end
					end else if (sd_valid) begin
						case (op)
							OP_SPRB: begin
								sprb_word  <= sd_rdata; sprb_valid <= 1'b1;
								wcnt <= wcnt + 2'd1;
								if (wcnt == 2'd3) st <= G_HOLD;
							end
							OP_TILE: begin
								if (wcnt == 2'd0) begin tlo <= sd_rdata; wcnt <= 2'd1; end
								else begin tile_data <= {sd_rdata, tlo}; tile_valid <= 1'b1; st <= G_HOLD; end
							end
							OP_SPR: begin
								spr_data  <= sbyte ? sd_rdata[15:8] : sd_rdata[7:0];
								spr_word  <= sd_rdata;
								spr_valid <= 1'b1; st <= G_HOLD;
							end
							default: begin // OP_CPU
								cpu_data <= sd_rdata; cpu_valid <= 1'b1; st <= G_HOLD;
							end
						endcase
					end
				end
				// -------- one transaction per request: wait for the served client to drop req --------
				G_HOLD: begin
					case (op)
						OP_WR:   if (!dl_wr)     st <= G_IDLE;
						OP_SPRB: if (!sprb_req)  st <= G_IDLE;
						OP_TILE: if (!tile_req)  st <= G_IDLE;
						OP_SPR:  if (!spr_req)   st <= G_IDLE;
						default: if (!cpu_req)   st <= G_IDLE;   // OP_CPU
					endcase
				end
				default: st <= G_IDLE;
			endcase
		end
	end

endmodule
