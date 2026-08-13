// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// MiSTer transport and save-request controller for Toobin's 512-byte X2804A.
//
// Index 0 is the MRA ROM stream; its final 0x200 bytes at EEP_BASE provide the
// erased factory image. Index 2 is the <nvram> restore/save channel. The actual
// EEPROM cell/unlock/busy behavior remains in toobin_eeprom_2804.
//
// Dirty state deliberately survives a board/game soft reset. The physical
// EEPROM also survives that reset, so clearing the pending-save metadata there
// could lose a newly programmed setting or high score. FPGA initialization or
// an out-of-band factory/NVRAM load establishes a clean image. If an EEPROM
// write and upload-start ever coincide, the write wins and is requested again.

module toobin_nvram_io #(
	parameter int unsigned SETTLE_CYCLES = 67_108_863,
	parameter logic [26:0] EEP_BASE = 27'h314000
)(
	input  logic        clk,
	input  logic        init_reset,

	input  logic        write_accepted,

	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_upload,

	output logic        load_we,
	output logic  [8:0] load_addr,
	output logic  [7:0] load_data,
	output logic  [8:0] dump_addr,
	input  logic  [7:0] dump_data,

	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din
);

	wire index0_eeprom = (ioctl_index == 16'd0) &&
	                     (ioctl_addr >= EEP_BASE) &&
	                     (ioctl_addr < EEP_BASE + 27'h200);
	wire index2_nvram  = (ioctl_index == 16'd2);

	assign load_we   = ioctl_download & ioctl_wr & (index0_eeprom | index2_nvram);
	assign load_addr = index2_nvram ? ioctl_addr[8:0] : 9'(ioctl_addr - EEP_BASE);
	assign load_data = ioctl_dout;
	assign dump_addr = ioctl_addr[8:0];

	localparam int SETTLE_W = (SETTLE_CYCLES <= 1) ? 1 : $clog2(SETTLE_CYCLES + 1);
	logic [SETTLE_W-1:0] settle;
	logic dirty;
	wire settled = (settle == SETTLE_W'(SETTLE_CYCLES));
	wire upload_start = ioctl_upload & index2_nvram;

	always_ff @(posedge clk) begin
		if (init_reset) begin
			dirty  <= 1'b0;
			settle <= '0;
		end else if (write_accepted) begin
			// Highest priority: an upload concurrent with a new byte cannot clean it.
			dirty  <= 1'b1;
			settle <= '0;
		end else if (load_we || upload_start) begin
			// A restored image or an HPS upload start establishes a clean baseline.
			dirty  <= 1'b0;
			settle <= '0;
		end else if (dirty && !settled) begin
			settle <= settle + 1'b1;
		end
	end

	assign ioctl_upload_req   = dirty & settled;
	assign ioctl_upload_index = 8'd2;
	assign ioctl_din          = dump_data;

endmodule
