// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' CPU <-> video-RAM adapter.  Converts the 68010's 16-bit region accesses
// (from toobin_main_bus: per-region write strobes + cpu addr/data/byte-enables) into
// the toobin_video RAM ports, and presents the 16-bit region read-back the main bus
// muxes into cpu_rdata.  Faithful to the RAM widths/packing:
//   PF     0xC00000  32-bit/tile (8192 words): addr[14:2]=word, addr[1]=half.
//          Per MAME get_playfield_tile_info the 32-bit word is {hi16, lo16} where
//          hi16 (color/flip/cat, bits31:16) is the addr[1]=0 access and lo16 (code,
//          bits15:0) is addr[1]=1 (big-endian).
//   alpha  0xC08000  16-bit (3072): addr[12:1]=word.
//   MO     0xC09800  16-bit (1024): addr[10:1]=word, independent byte lanes.
//   pal    0xC10000  16-bit (1024): addr[10:1]=word.

module toobin_vram_cpu
(
	// from main bus
	input  logic [23:0] cpu_addr,
	input  logic [15:0] cpu_wdata,
	input  logic        be_hi,       // D15:8 lane
	input  logic        be_lo,       // D7:0  lane
	input  logic        pf_we,
	input  logic        alpha_we,
	input  logic        mob_we,
	input  logic        pal_we,
	// video RAM read-backs
	input  logic [31:0] pf_rdata32,
	input  logic [15:0] a_rdata16,
	input  logic [15:0] mo_rdata16,
	input  logic [15:0] pal_rdata16,

	// to toobin_video write ports
	output logic        pf_wr,
	output logic [12:0] pf_wr_addr,
	output logic [31:0] pf_wr_data,
	output logic  [3:0] pf_wr_be,
	output logic        a_wr,
	output logic [11:0] a_wr_addr,
	output logic [15:0] a_wr_data,
	output logic  [1:0] a_wr_be,
	output logic        mo_wr,
	output logic  [9:0] mo_wr_addr,
	output logic [15:0] mo_wr_data,
	output logic  [1:0] mo_wr_be,
	output logic        pal_wr,
	output logic  [9:0] pal_wr_addr,
	output logic [15:0] pal_wr_data,
	output logic  [1:0] pal_wr_be,
	// video-RAM CPU read addresses (drive the RAM read ports)
	output logic [12:0] pf_cpu_addr,
	output logic [11:0] a_cpu_addr,
	output logic  [9:0] mo_cpu_addr,
	output logic  [9:0] pal_cpu_addr,
	// 16-bit region read-back to the main bus
	output logic [15:0] pf_rdata,
	output logic [15:0] alpha_rdata,
	output logic [15:0] mob_rdata,
	output logic [15:0] pal_rdata
);

	wire [1:0] be = {be_hi, be_lo};
	// addr[23:15] = region select (decoded upstream by the main bus); addr[0] = byte
	// within the 16-bit word (handled by be_hi/be_lo).  Not used for word addressing.
	wire unused = &{1'b0, cpu_addr[23:15], cpu_addr[0]};

	// ---- playfield (32-bit, half select on addr[1]) ----
	assign pf_cpu_addr = cpu_addr[14:2];
	assign pf_wr_addr  = cpu_addr[14:2];
	assign pf_wr       = pf_we;
	assign pf_wr_data  = {cpu_wdata, cpu_wdata};       // replicate; byte-enables pick the half
	assign pf_wr_be    = cpu_addr[1] ? {2'b00, be} : {be, 2'b00};
	assign pf_rdata    = cpu_addr[1] ? pf_rdata32[15:0] : pf_rdata32[31:16];

	// ---- alpha (16-bit) ----
	assign a_cpu_addr  = cpu_addr[12:1];
	assign a_wr_addr   = cpu_addr[12:1];
	assign a_wr        = alpha_we;
	assign a_wr_data   = cpu_wdata;
	assign a_wr_be     = be;
	assign alpha_rdata = a_rdata16;

	// ---- motion objects (16-bit, independent UDS/LDS byte lanes) ----
	assign mo_cpu_addr = cpu_addr[10:1];
	assign mo_wr_addr  = cpu_addr[10:1];
	assign mo_wr       = mob_we & (be_hi | be_lo);
	assign mo_wr_data  = cpu_wdata;
	assign mo_wr_be    = be;
	assign mob_rdata   = mo_rdata16;

	// ---- palette (16-bit) ----
	assign pal_cpu_addr = cpu_addr[10:1];
	assign pal_wr_addr  = cpu_addr[10:1];
	assign pal_wr       = pal_we & (be_hi | be_lo);
	assign pal_wr_data  = cpu_wdata;
	assign pal_wr_be    = be;
	assign pal_rdata    = pal_rdata16;

endmodule
