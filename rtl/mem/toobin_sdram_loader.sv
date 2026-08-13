// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// Toobin' SDRAM loader-writer: packs the byte download stream into 16-bit words and
// writes them to the three SDRAM ROM regions via the single toobin_gfx_mem write port
// (dl_wr/dl_ack).  Fed by toobin_rom_loader's per-region byte strobes + local offsets.
//
//   region     src strobe/addr        SDRAM word addr             byte convention
//   maincpu    maincpu_wr / [18:0]    CPU_BASE  + addr[18:1]      even->high, odd->low
//   tiles      tiles_wr   / [18:0]    TILE_BASE + reorg[18:1]     even->low,  odd->high
//   sprites    sprites_wr / [20:0]    SPR_BASE  + sprperm(addr[20:1])   even->low, odd->high
//
// maincpu packs big-endian for the 68010 (even byte = D15:8); tiles/sprites match the
// toobin_gfx_mem read side (spr byte = addr[0]?[15:8]:[7:0]; tile low word {B,A},
// high {D,C}).  The tile region is reorganized at load time (toobin_tile_reorg) so the
// two words of each tile row land exactly where the tile client reads them:
//   reorg[18:1] = {tile,row,half} == the client's TILE_BASE + 2*(tile*8+row) + half.
//
// The sprite region is likewise REPACKED at load time so the four words of one 16px
// sprite row (code, gfxrow) are CONSECUTIVE and the MO renderer fetches them with a
// single burst-4 read (the per-line sprite render has a hard scanline budget; four
// separate reads starved it on MO-heavy scenes).  Linear ROM layout: first-half words
// 0/1 of (code,row) at code*32+row*2+{0,1}, second-half words at +0x80000.  Repacked:
//   dest = {code[13:0], row[3:0], half, w}  ( = code*64 + row*4 + half*2 + w )
// which for linear word index L = {half, code, row, w} is the pure bit permutation
//   sprperm(L) = {L[18:5], L[4:1], L[19], L[0]}.
// The gfx_mem column client reads 4 words at SPR_BASE + {code,row}*4; its byte client
// is layout-agnostic and unused by the game path.
//
// Even/odd bytes of a word are always consecutive in the download (within a region and,
// for tiles, within each reorg half), so we latch the even (first) byte and emit the
// word on the odd (second) byte.  `wr_busy` is asserted while a write is outstanding
// (drive the loader's ioctl_wait with it) so the byte stream never outruns the SDRAM.
//
// Single write path through the shared gfx_mem controller port -- NOT a separate
// arbiter write client (Quartus prunes a second write-only client on this port).

module toobin_sdram_loader #(
	parameter int AW = 24,
	parameter logic [AW-1:0] CPU_BASE  = 24'h000000,
	parameter logic [AW-1:0] TILE_BASE = 24'h040000,
	parameter logic [AW-1:0] SPR_BASE  = 24'h080000
)(
	input  logic          clk,
	input  logic          reset,

	// ---- byte strobes from toobin_rom_loader (SDRAM regions only) ----
	input  logic          maincpu_wr,  input logic [18:0] maincpu_addr,
	input  logic          tiles_wr,    input logic [18:0] tiles_addr,
	input  logic          sprites_wr,  input logic [20:0] sprites_addr,
	input  logic  [7:0]   ld_data,
	output logic          wr_busy,     // -> ioctl_wait (backpressure)

	// ---- gfx_mem write port ----
	output logic          dl_wr,
	output logic [AW-1:0] dl_waddr,
	output logic [15:0]   dl_wdata,
	input  logic          dl_ack
);

	// tile reorganizer: download byte offset -> reorganized 32-bit-ROM byte address.
	// We use reorg_addr[18:1] as the SDRAM word address; reorg_addr[0] (= the byte
	// lane) is instead taken from tiles_addr[0] via tile_od, so sink it.
	logic [18:0] reorg_addr;
	toobin_tile_reorg u_reorg (.off(tiles_addr), .reorg_addr(reorg_addr));
	wire unused_reorg = &{1'b0, reorg_addr[0]};

	// sprite repack: linear word index -> burst-4 column layout (see header)
	wire [19:0] spr_lin  = sprites_addr[20:1];
	wire [19:0] spr_perm = {spr_lin[18:5], spr_lin[4:1], spr_lin[19], spr_lin[0]};

	// ---- current byte: is it even (first/low-index) or word-completing (odd)? ----
	wire main_ev = maincpu_wr && !maincpu_addr[0];
	wire main_od = maincpu_wr &&  maincpu_addr[0];
	wire tile_ev = tiles_wr   && !tiles_addr[0];
	wire tile_od = tiles_wr   &&  tiles_addr[0];
	wire spr_ev  = sprites_wr && !sprites_addr[0];
	wire spr_od  = sprites_wr &&  sprites_addr[0];

	wire any_ev = main_ev | tile_ev | spr_ev;
	wire any_od = main_od | tile_od | spr_od;   // word-completing

	// word address + assembled data for the completing (odd) byte.  lo_buf holds the
	// even byte; maincpu puts the even byte in the high lane, tiles/sprites in the low.
	logic [7:0] lo_buf;
	wire [AW-1:0] word_addr =
		main_od ? (CPU_BASE  + {{(AW-18){1'b0}}, maincpu_addr[18:1]}) :
		tile_od ? (TILE_BASE + {{(AW-18){1'b0}}, reorg_addr[18:1]})   :
		          (SPR_BASE  + {{(AW-20){1'b0}}, spr_perm});
	wire [15:0] word_data = main_od ? {lo_buf, ld_data}    // even=high, odd=low
	                                : {ld_data, lo_buf};   // odd=high,  even=low

	typedef enum logic [0:0] { L_IDLE, L_WR } lstate_t;
	lstate_t st;

	// combinational backpressure: busy while writing, or the cycle a word completes.
	assign wr_busy = (st == L_WR) || (st == L_IDLE && any_od);

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= L_IDLE; dl_wr <= 1'b0;
		end else begin
			case (st)
				L_IDLE: begin
					dl_wr <= 1'b0;
					if (any_ev)      lo_buf <= ld_data;          // latch the even (first) byte
					else if (any_od) begin
						dl_waddr <= word_addr;
						dl_wdata <= word_data;
						dl_wr    <= 1'b1;
						st       <= L_WR;
					end
				end
				L_WR: begin
					if (dl_ack) begin dl_wr <= 1'b0; st <= L_IDLE; end
				end
				default: st <= L_IDLE;
			endcase
		end
	end

endmodule
