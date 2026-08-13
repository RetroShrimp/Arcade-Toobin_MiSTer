// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' JSA-I sound-CPU memory: 8 KB work RAM + 64 KB program ROM with the
// cpubank paging.  Per MAME atarijsa.cpp: 0x0000-0x1FFF RAM; 0x3000-0x3FFF =
// cpubank (4 x 0x1000 entries mapping the ROM's bottom 16 KB); 0x4000-0xFFFF =
// fixed ROM (top 48 KB).  ROM offset:
//   sel_bank -> {bank, addr[11:0]}   (0x0000-0x3FFF)
//   sel_rom  -> addr                 (0x4000-0xFFFF)
//
// Registered (BRAM) read: dout valid one clk after addr/selects.  Each array has its OWN
// dedicated registered-output read (ram_q / rom_q) so both infer as M10K.  A single shared
// 'dout' output register muxed across the two arrays defeats inference ("asynchronous read
// logic"): the M10K's output register can't be shared, so the 64 KB ROM would fall back to
// ~512K flip-flops and overflow the device (Quartus err 276003).

module toobin_jsa_mem
(
	input  logic        clk,
	// loader (byte writes over the whole 64 KB ROM image)
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,
	// 6502 access
	input  logic [15:0] addr,
	input  logic  [7:0] din,
	input  logic        we,          // 6502 write (RAM only)
	input  logic        sel_ram,
	input  logic        sel_bank,
	input  logic        sel_rom,
	input  logic  [1:0] bank,
	output logic  [7:0] dout
);

	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] ram [0:8191];    // 8 KB work RAM
	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] rom [0:65535];   // 64 KB program ROM
`ifndef ALTERA_RESERVED_QIS
	initial begin for (int i=0;i<8192;i++) ram[i]=8'h00; end   // sim-only; M10K powers to 0
`endif

	wire [15:0] rom_off = sel_bank ? {2'b00, bank, addr[11:0]} : addr;

	// Per-array registered-output reads (each infers its own M10K) + the write ports.
	logic [7:0] ram_q, rom_q;
	logic       sel_ram_q, sel_romish_q;
	always_ff @(posedge clk) begin
		if (rom_wr) rom[rom_wr_addr] <= rom_wr_data;
		if (we && sel_ram) ram[addr[12:0]] <= din;
		ram_q        <= ram[addr[12:0]];
		rom_q        <= rom[rom_off];
		sel_ram_q    <= sel_ram;
		sel_romish_q <= sel_bank | sel_rom;
	end

	// Combinational output mux over the registered BRAM outputs == the original 1-clk
	// latency, selected by the select that was valid at address time (sel_*_q = sel_* d1).
	always_comb begin
		if      (sel_ram_q)    dout = ram_q;
		else if (sel_romish_q) dout = rom_q;
		else                   dout = 8'hFF;
	end

endmodule
