// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' ROM download router (MiSTer index-0 ioctl stream -> region writes).
//
// The MRA emits the five regions concatenated in manifest order, each already
// fully assembled (68010 even/odd LOAD16_BYTE interleave and the sprite
// ROM_RELOAD mirroring are done by the MRA), so this router is a pure address
// decode into per-region byte write strobes + local byte offsets:
//
//   region     bytes      download offset       destination
//   maincpu   0x080000    0x000000-0x07FFFF     68010 program ROM
//   jsa:cpu   0x010000    0x080000-0x08FFFF     6502 sound ROM
//   tiles     0x080000    0x090000-0x10FFFF     playfield gfx ROM
//   sprites   0x200000    0x110000-0x30FFFF     motion-object gfx ROM
//   chars     0x004000    0x310000-0x313FFF     alpha gfx ROM
//   total     0x314000
//
// Region sizes and order match MAME's ROM_START(toobin); the download itself
// arrives over the MiSTer ioctl interface (sys/hps_io.sv).

module toobin_rom_loader
(
	input  logic        clk,
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,     // byte offset into the index-0 stream
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,

	output logic  [7:0] data,           // = ioctl_dout (registered passthrough)
	output logic        maincpu_wr,  output logic [18:0] maincpu_addr,  // 0x80000
	output logic        sndcpu_wr,   output logic [15:0] sndcpu_addr,   // 0x10000
	output logic        tiles_wr,    output logic [18:0] tiles_addr,    // 0x80000
	output logic        sprites_wr,  output logic [20:0] sprites_addr,  // 0x200000
	output logic        chars_wr,    output logic [13:0] chars_addr,    // 0x04000
	output logic        rom_loaded
);

	// region base offsets in the concatenated download stream
	localparam [26:0] BASE_MAINCPU = 27'h000000;
	localparam [26:0] BASE_SNDCPU  = 27'h080000;
	localparam [26:0] BASE_TILES   = 27'h090000;
	localparam [26:0] BASE_SPRITES = 27'h110000;
	localparam [26:0] BASE_CHARS   = 27'h310000;
	localparam [26:0] END_STREAM   = 27'h314000;

	wire is_idx0 = (ioctl_index == 16'd0);
	wire wr      = ioctl_download & ioctl_wr & is_idx0;

	wire in_maincpu = wr && (ioctl_addr < BASE_SNDCPU);   // BASE_MAINCPU = 0
	wire in_sndcpu  = wr && (ioctl_addr >= BASE_SNDCPU)  && (ioctl_addr < BASE_TILES);
	wire in_tiles   = wr && (ioctl_addr >= BASE_TILES)   && (ioctl_addr < BASE_SPRITES);
	wire in_sprites = wr && (ioctl_addr >= BASE_SPRITES) && (ioctl_addr < BASE_CHARS);
	wire in_chars   = wr && (ioctl_addr >= BASE_CHARS)   && (ioctl_addr < END_STREAM);

	always_ff @(posedge clk) begin
		data         <= ioctl_dout;
		maincpu_wr   <= in_maincpu;
		sndcpu_wr    <= in_sndcpu;
		tiles_wr     <= in_tiles;
		sprites_wr   <= in_sprites;
		chars_wr     <= in_chars;
		maincpu_addr <= 19'(ioctl_addr - BASE_MAINCPU);
		sndcpu_addr  <= 16'(ioctl_addr - BASE_SNDCPU);
		tiles_addr   <= 19'(ioctl_addr - BASE_TILES);
		sprites_addr <= 21'(ioctl_addr - BASE_SPRITES);
		chars_addr   <= 14'(ioctl_addr - BASE_CHARS);
	end

	// rom_loaded latches at the end of the index-0 download
	logic dl_d;
	always_ff @(posedge clk) begin
		dl_d <= ioctl_download;
		if (ioctl_download & is_idx0) rom_loaded <= 1'b0;
		else if (dl_d & ~ioctl_download) rom_loaded <= 1'b1;   // falling edge of download
	end

endmodule
