// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' 68010 main-bus address decoder.
//
// Faithful reproduction of MAME toobin.cpp `main_map` semantics:
//   1. global_mask 0xC7FFFF  (A21..A19 are don't-care)
//   2. per-entry .mirror() bits are don't-care (collapsed before the range test)
//   3. range test start<=addr<=end
//   4. install order = priority: a later map entry wins where two overlap
//      (only happens at mirror aliases; canonical addresses are disjoint)
//
// Read and write handlers are decoded SEPARATELY, matching MAME's independent
// .r()/.w() installs: a read of a write-only register (or vice-versa) yields
// REG_NONE (open bus). Purely combinational; `a` is the 24-bit byte address.
//
// Source: Atari SP-320 schematics (main CPU decode); MAME's toobin.cpp.

module toobin_addr_decode
(
	input  logic [23:0] a,          // 68010 byte address
	output logic [4:0]  rd_region,  // region driving the read data (REG_NONE = open bus)
	output logic [4:0]  wr_region   // region selected for a write   (REG_NONE = ignored)
);

`include "toobin_regions.vh"

	// match(a, start, end, mirror): MAME global-mask + mirror-collapse + range.
	function automatic logic hit(input logic [23:0] addr,
	                             input logic [23:0] lo,
	                             input logic [23:0] hi,
	                             input logic [23:0] mirror);
		logic [23:0] amm;
		begin
			amm = (addr & 24'hC7FFFF) & ~mirror;
			hit = (amm >= lo) && (amm <= hi);
		end
	endfunction

	// Per-entry hits (start, end, mirror straight from toobin.cpp).
	wire h_rom    = hit(a, 24'h000000, 24'h07FFFF, 24'h000000);
	wire h_pf     = hit(a, 24'hC00000, 24'hC07FFF, 24'h000000);
	wire h_alpha  = hit(a, 24'hC08000, 24'hC097FF, 24'h046000);
	wire h_mob    = hit(a, 24'hC09800, 24'hC09FFF, 24'h046000);
	wire h_pal    = hit(a, 24'hC10000, 24'hC107FF, 24'h047800);
	wire h_nopr   = hit(a, 24'h826000, 24'h826001, 24'h4500FE);
	wire h_wd     = hit(a, 24'h828000, 24'h828001, 24'h4500FE);
	// Sound command/response are ODD-BYTE registers (D7:0 lane), but the game accesses
	// them with WORD ops (`move.w Dn,$8100.w` @0x4912/0x494C, `move.w $9800.w,Dn`
	// @0x4A1E are the ONLY sites in the 512KB ROM, confirmed by disassembly).  A word
	// access reconstructs A0=0, so an exact odd-address match never hits: sound + the
	// JSA coin path were unreachable.  Real hardware has no A0 — it decodes the word
	// address and the byte lane comes from /LDS.  Model that: match the even/odd PAIR
	// here; toobin_main_bus qualifies the actual strobes with ~cpu_lds_n (low lane).
	wire h_sndcmd = hit(a, 24'h828100, 24'h828101, 24'h4500FE);
	wire h_intens = hit(a, 24'h828300, 24'h828301, 24'h45003E);
	wire h_irqscn = hit(a, 24'h828340, 24'h828341, 24'h45003E);
	wire h_slip   = hit(a, 24'h828380, 24'h828381, 24'h45003E);
	wire h_irqack = hit(a, 24'h8283C0, 24'h8283C1, 24'h45003E);
	wire h_sndrst = hit(a, 24'h828400, 24'h828401, 24'h4500FE);
	wire h_eeunlk = hit(a, 24'h828500, 24'h828501, 24'h4500FE);
	wire h_hscrl  = hit(a, 24'h828600, 24'h828601, 24'h4500FE);
	wire h_vscrl  = hit(a, 24'h828700, 24'h828701, 24'h4500FE);
	wire h_sw     = hit(a, 24'h828800, 24'h828801, 24'h4507FE);
	wire h_inp    = hit(a, 24'h829000, 24'h829001, 24'h4507FE);
	wire h_sndrsp = hit(a, 24'h829800, 24'h829801, 24'h4507FE);  // even/odd pair, see h_sndcmd note
	wire h_eeprom = hit(a, 24'h82A000, 24'h82A3FF, 24'h451C00);
	wire h_wram   = hit(a, 24'h82C000, 24'h82FFFF, 24'h450000);

	// READ decode — read-capable entries only, highest install index first.
	always_comb begin
		if      (h_wram)   rd_region = REG_WRAM;
		else if (h_eeprom) rd_region = REG_EEPROM;
		else if (h_sndrsp) rd_region = REG_SNDRESP;
		else if (h_inp)    rd_region = REG_INP;
		else if (h_sw)     rd_region = REG_SW;
		else if (h_slip)   rd_region = REG_SLIP;   // 0x828380 is .ram().w() = readable
		else if (h_nopr)   rd_region = REG_NOPR;
		else if (h_pal)    rd_region = REG_PAL;
		else if (h_mob)    rd_region = REG_MOB;
		else if (h_alpha)  rd_region = REG_ALPHA;
		else if (h_pf)     rd_region = REG_PF;
		else if (h_rom)    rd_region = REG_ROM;
		else               rd_region = REG_NONE;
	end

	// WRITE decode — write-capable entries only, highest install index first.
	always_comb begin
		if      (h_wram)   wr_region = REG_WRAM;
		else if (h_eeprom) wr_region = REG_EEPROM;
		else if (h_vscrl)  wr_region = REG_VSCRL;
		else if (h_hscrl)  wr_region = REG_HSCRL;
		else if (h_eeunlk) wr_region = REG_EEUNLK;
		else if (h_sndrst) wr_region = REG_SNDRST;
		else if (h_irqack) wr_region = REG_IRQACK;
		else if (h_slip)   wr_region = REG_SLIP;
		else if (h_irqscn) wr_region = REG_IRQSCAN;
		else if (h_intens) wr_region = REG_INTENS;
		else if (h_sndcmd) wr_region = REG_SNDCMD;
		else if (h_wd)     wr_region = REG_WD;
		else if (h_pal)    wr_region = REG_PAL;
		else if (h_mob)    wr_region = REG_MOB;
		else if (h_alpha)  wr_region = REG_ALPHA;
		else if (h_pf)     wr_region = REG_PF;
		else               wr_region = REG_NONE;
	end

endmodule
