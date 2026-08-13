// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// Atari/Xicor 2804-family parallel EEPROM used by Toobin'.
//
// Board behavior (SP-320 sheet 3): /UNLOCK presets 14M (74LS74).  Its D input
// is tied low and its clock is the global low-byte write strobe /HL, so the next
// low-byte write consumes the unlock, whether or not that write addresses the
// EEPROM.  An EEPROM byte is accepted only while this latch is armed.
//
// Device behavior (Xicor X2804A data sheet): a byte write starts a self-timed
// programming cycle, typically 5 ms and at most 10 ms.  The I/O pins are high-Z
// throughout programming and the part cannot accept another write.  This model
// uses the guaranteed 10 ms bound by default; the cycle count is parameterized
// so focused tests need not simulate hundreds of thousands of clocks.

module toobin_eeprom_2804 #(
	parameter int CLK_HZ       = 32_000_000,
	parameter int WRITE_CYCLES = CLK_HZ / 100       // 10 ms
)(
	input  logic       clk,
	input  logic       init_reset,      // power/PLL initialization; clears busy state
	input  logic       reset,           // board reset; locks writes, does not erase memory

	input  logic       unlock,          // decoded FF8500 /UNLOCK pulse
	input  logic       low_write,       // any decoded low-byte write pulse (/HL)
	input  logic       cpu_we,           // decoded EEPROM low-byte write pulse
	input  logic [8:0] cpu_addr,
	input  logic [7:0] cpu_wdata,
	output logic [7:0] cpu_rdata,
	output logic       busy,
	output logic       write_accepted,

	// Out-of-band MiSTer ROM/NVRAM restore and save-back ports.
	input  logic       load_we,
	input  logic [8:0] load_addr,
	input  logic [7:0] load_data,
	input  logic [8:0] dump_addr,
	output logic [7:0] dump_data
);

	localparam int BUSY_W = (WRITE_CYCLES <= 1) ? 1 : $clog2(WRITE_CYCLES + 1);
	logic [BUSY_W-1:0] busy_ctr;
	logic unlocked;
	logic [7:0] mem [0:511];

	assign busy           = |busy_ctr;
	assign write_accepted = cpu_we & unlocked & ~busy;
	assign dump_data      = mem[dump_addr];

	// The board latch is asynchronously cleared by /RESET.  Give /UNLOCK
	// priority over the same write's /HL edge, matching the LS74 preset input.
	always_ff @(posedge clk) begin
		if (init_reset || reset) unlocked <= 1'b0;
		else if (unlock)         unlocked <= 1'b1;
		else if (low_write)      unlocked <= 1'b0;
	end

	// Programming continues across board reset because the physical EEPROM has
	// no reset pin.  Loader writes are an out-of-band power-up restore and win.
	always_ff @(posedge clk) begin
		if (init_reset) busy_ctr <= '0;
		else begin
			if (busy) busy_ctr <= busy_ctr - 1'b1;
			if (load_we) begin
				mem[load_addr] <= load_data;
				busy_ctr <= '0;
			end else if (write_accepted) begin
				mem[cpu_addr] <= cpu_wdata;
				busy_ctr <= BUSY_W'(WRITE_CYCLES);
			end
		end

		// During programming the X2804A I/O pins float; the PCB bus pull-ups/open
		// bus presentation are modeled as FF.  Otherwise reads are synchronous.
		if (busy) cpu_rdata <= 8'hFF;
		else      cpu_rdata <= mem[cpu_addr];
	end

endmodule
