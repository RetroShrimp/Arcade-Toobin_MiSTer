// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' inter-CPU sound communication mailbox (Atari "atariscom").
//
// Faithful to MAME's atariscom.cpp:
//   main_command_w  (main FF8100 write): latch main->sound data, set
//                    main_to_sound_ready, assert the 6502 NMI.
//   sound_command_r (6502 /RDP 0x2802 read): clear main_to_sound_ready + NMI.
//   sound_response_w(6502 /WRP 0x2A02 write): latch sound->main data, set
//                    sound_to_main_ready, assert the main IPL1 interrupt.
//   main_response_r (main FF9800 read): clear sound_to_main_ready + IPL1.
//   sound reset     (main FF8400 write): reset the 6502, clear the response
//                    side (sound_to_main_ready + main IPL1).
//
// The two CPUs run in one FPGA fabric on clock enables, so MAME's zero-delay
// synchronization timers collapse to synchronous set/clear here. On a same-cycle
// set+clear of a ready flag, the set (new datum) wins — a command/response is
// never silently dropped.

module toobin_sound_comm
(
	input  logic       clk,
	input  logic       reset,           // global/power-on reset

	// ---- main-CPU (68010) side ----
	input  logic       main_cmd_wr,     // pulse: main wrote FF8100
	input  logic [7:0] main_cmd_data,
	input  logic       main_resp_rd,    // pulse: main read  FF9800
	input  logic       main_sndrst_wr,  // pulse: main wrote FF8400 (sound reset)
	output logic [7:0] main_resp_data,  // data returned to the main read
	output logic       main_irq,        // -> 68010 IPL1 (level)
	output logic       main_to_sound_ready,
	output logic       sound_to_main_ready,

	// ---- sound-CPU (6502) side ----
	input  logic       snd_cmd_rd,      // pulse: 6502 read  0x2802 (/RDP)
	input  logic       snd_resp_wr,     // pulse: 6502 wrote 0x2A02 (/WRP)
	input  logic [7:0] snd_resp_data,
	output logic [7:0] snd_cmd_data,    // data returned to the 6502 command read
	output logic       snd_nmi,         // -> 6502 NMI (level; asserted while a command is pending)
	output logic       snd_reset        // -> 6502 reset (level; asserted on FF8400 write, held 1 cycle)
);

	logic [7:0] m2s_data, s2m_data;
	logic       m2s_ready, s2m_ready;

	assign main_to_sound_ready = m2s_ready;
	assign sound_to_main_ready = s2m_ready;
	assign snd_cmd_data        = m2s_data;
	assign main_resp_data      = s2m_data;
	assign snd_nmi             = m2s_ready;   // edge on assert triggers the 6502 NMI
	assign main_irq            = s2m_ready;   // level to IPL1

	always_ff @(posedge clk) begin
		if (reset) begin
			m2s_data  <= 8'h00;
			s2m_data  <= 8'h00;
			m2s_ready <= 1'b0;
			s2m_ready <= 1'b0;
			snd_reset <= 1'b0;
		end else begin
			snd_reset <= 1'b0;

			// main -> sound command latch
			if (main_cmd_wr) begin
				m2s_data  <= main_cmd_data;
				m2s_ready <= 1'b1;          // set wins over a coincident 6502 read
			end else if (snd_cmd_rd) begin
				m2s_ready <= 1'b0;
			end

			// sound -> main response latch
			if (snd_resp_wr) begin
				s2m_data  <= snd_resp_data;
				s2m_ready <= 1'b1;          // set wins over a coincident main read
			end else if (main_resp_rd || main_sndrst_wr) begin
				s2m_ready <= 1'b0;          // main read OR sound-reset clears the response side
			end

			// sound-reset strobe (also unhalts/resets the 6502 externally)
			if (main_sndrst_wr)
				snd_reset <= 1'b1;
		end
	end

endmodule
