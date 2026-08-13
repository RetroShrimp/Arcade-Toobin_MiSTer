// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' JSA-I sound-board I/O: output latch (/WRIO), input port (/RDIO),
// ROM banking, and the periodic sound IRQ.  Per MAME atarijsa.cpp
// atari_jsa_i_device (Toobin has no TMS5220, so its strobes are ignored).
//
// /WRIO (0x2A04) write:  [7:6]=cpubank  [5]=coin ctr2  [4]=coin ctr1
//                        [3:1]=TMS5220 (N/C)  [0]=YM2151 /RESET (active low)
// /RDIO (0x2804) read:   [7]=self-test  [6]=NMI asserted (active high)
//                        [5]=sound output full  [4]=TMS ready (0, no TMS)
//                        [3:2]=unused coin 4/3 (inactive 0)
//                        [1]=coin2  [0]=coin1
// Sound IRQ: periodic at JSA_MASTER_CLOCK/4/16/16/14 (=14336 master ticks),
//            level-latched, cleared by the /IRQACK strobe (0x2806).

module toobin_jsa_io #(parameter int IRQ_DIV = 14336)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_jsa,        // JSA master-clock enable (3.579545 MHz)

	// /WRIO write (0x2A04)
	input  logic        wrio_wr,
	input  logic  [7:0] wrio_data,
	// /IRQACK write (0x2806) clears the periodic IRQ
	input  logic        irqack,

	// input-port sources
	input  logic        self_test,     // -> bit 7
	input  logic        nmi_line_n,    // physical /NMI before sheet-22 LS240 inversion
	input  logic        resp_full,     // sound output full -> bit 5
	input  logic        coin1,         // -> bit 0
	input  logic        coin2,         // -> bit 1

	// outputs
	output logic  [1:0] cpu_bank,      // cpubank entry (0..3)
	output logic        coin_ctr1,
	output logic        coin_ctr2,
	output logic        ym_reset_n,    // YM2151 /RESET (active low: 1=run,0=reset)
	output logic  [7:0] rdio_data,     // assembled /RDIO byte
	output logic        sound_irq      // level, to 6502 IRQ
);

	// bits [3:1] drive the (depopulated) TMS5220 strobes — unused on Toobin
	wire unused_tms = &{1'b0, wrio_data[3:1]};

	// ---- output latch ----
	always_ff @(posedge clk) begin
		if (reset) begin
			cpu_bank <= 2'd0; coin_ctr1 <= 1'b0; coin_ctr2 <= 1'b0; ym_reset_n <= 1'b0;
		end else if (wrio_wr) begin
			cpu_bank   <= wrio_data[7:6];
			coin_ctr2  <= wrio_data[5];
			coin_ctr1  <= wrio_data[4];
			ym_reset_n <= wrio_data[0];   // /RESET line (active low)
		end
	end

	// ---- input port assembly ----
	// Sheet 22 feeds four active-low cabinet coin lines through an LS240.  The
	// Toobin harness (sheet 18) populates only COIN1/COIN2; the two open inputs
	// are pulled high at the LS240 inputs and therefore read low on SD3/SD2.
	// D5 is already the post-inverter logical "response full" level.  Sheet 22
	// explicitly routes physical /NMI through LS240 5J onto SD6, hence the CPU
	// reads 1 while NMI is asserted (/NMI=0).  MAME JSA-I labels this lane
	// active-low, but that contradicts the electrical path; the rev-3 ROM does
	// not poll D6, so the schematic is decisive here.
	assign rdio_data = { self_test, ~nmi_line_n, resp_full, 1'b0, 1'b0, 1'b0, coin2, coin1 };

	// ---- periodic sound IRQ ----
	localparam int CW = $clog2(IRQ_DIV);
	logic [CW-1:0] irq_cnt;
	always_ff @(posedge clk) begin
		if (reset) begin irq_cnt <= '0; sound_irq <= 1'b0; end
		else begin
			if (irqack) sound_irq <= 1'b0;
			if (ce_jsa) begin
				if (irq_cnt == CW'(IRQ_DIV-1)) begin irq_cnt <= '0; sound_irq <= 1'b1; end
				else irq_cnt <= irq_cnt + 1'b1;
			end
		end
	end

endmodule
