// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' JSA-I sound board — complete: 6502 (T65) + toobin_jsa_bus (decode/mem/io/
// mailbox) + YM2151 (jt51) + POKEY + the /MIX audio mixer.  One instantiable module
// for the top level.  Clock enables: ce_6502 (1.789 MHz), ce_ym/ce_ym_p1 (jt51),
// ce_pokey (POKEY).  T65 is instantiated through the T65_wrap VHDL wrapper.

module toobin_jsa
(
	input  logic        clk,
	input  logic        reset,
	// clock enables
	input  logic        ce_6502,
	input  logic        ce_ym,
	input  logic        ce_ym_p1,
	input  logic        ce_pokey,
	// sound ROM loader (64 KB)
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,
	// main-CPU mailbox
	input  logic        main_cmd_wr,
	input  logic  [7:0] main_cmd_data,
	input  logic        main_resp_rd,
	input  logic        main_sndrst_wr,
	output logic  [7:0] main_resp_data,
	output logic        main_irq,
	output logic        main_to_sound_ready,   // FF9000 status D13
	// board inputs
	input  logic        coin1,
	input  logic        coin2,
	input  logic        self_test,
	// audio options
	input  logic        lpf_bypass,    // 1 = skip the sheet-21 output low-pass
	// audio
	output logic signed [15:0] aud_left,
	output logic signed [15:0] aud_right
);

	// ---- 6502 <-> bus ----
	wire [15:0] cpu_a; wire [7:0] cpu_do, cpu_di; wire cpu_rwn;
	wire cpu_irq, cpu_nmi, cpu_reset;
	wire [7:0] t65_a_nc, t65_x_nc, t65_y_nc, t65_s_nc, t65_p_nc; wire cpu_sync_nc;
	T65_wrap u_cpu (
		.Mode(2'b00), .Res_n(~(reset | cpu_reset)), .Clk(clk), .Enable(ce_6502), .Rdy(1'b1),
		.IRQ_n(~cpu_irq), .NMI_n(~cpu_nmi), .DI(cpu_di),
		.A(cpu_a), .DO(cpu_do), .R_W_n(cpu_rwn), .Sync(cpu_sync_nc),
		.dbg_A(t65_a_nc), .dbg_X(t65_x_nc), .dbg_Y(t65_y_nc), .dbg_S(t65_s_nc), .dbg_P(t65_p_nc) );

	// ---- bus (decode + mem + io + mailbox) ----
	wire ym_reset_n, coin_ctr1_nc, coin_ctr2_nc; wire [1:0] cpu_bank_nc;
	wire ym_cs, ym_a0, ym_we, ym_rd; wire [7:0] ym_dout, ym_din;
	wire pk_cs; wire [3:0] pk_addr; wire pk_we, pk_rd; wire [7:0] pk_dout, pk_din;
	wire mix_wr; wire [7:0] mix_data;
	wire ym_irq_w;
	toobin_jsa_bus u_bus (
		// ce_jsa = the IRQ-divider enable.  IRQ_DIV=14336 counts MASTER-CRYSTAL ticks
		// (3.579545 MHz /4/16/16/14 = 249.689 Hz); ce_ym is the exact-average
		// fractional master-rate enable from toobin_jsa_cen.
		// (Driving it from ce_6502, at half rate, gives ~124 Hz -- audibly wrong.)
		.clk(clk), .reset(reset), .ce(ce_6502), .ce_jsa(ce_ym),
		.cpu_addr(cpu_a), .cpu_dout(cpu_do), .cpu_rnw(cpu_rwn), .cpu_din(cpu_di),
		.cpu_irq(cpu_irq), .ym_irq(ym_irq_w), .cpu_nmi(cpu_nmi), .cpu_reset(cpu_reset),
		.rom_wr(rom_wr), .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data),
		.main_cmd_wr(main_cmd_wr), .main_cmd_data(main_cmd_data), .main_resp_rd(main_resp_rd),
		.main_sndrst_wr(main_sndrst_wr), .main_resp_data(main_resp_data), .main_irq(main_irq),
		.main_to_sound_ready(main_to_sound_ready),
		.coin1(coin1), .coin2(coin2), .self_test(self_test),
		.ym_reset_n(ym_reset_n), .coin_ctr1(coin_ctr1_nc), .coin_ctr2(coin_ctr2_nc), .cpu_bank(cpu_bank_nc),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we), .ym_rd(ym_rd), .ym_dout(ym_dout), .ym_din(ym_din),
		.pk_cs(pk_cs), .pk_addr(pk_addr), .pk_we(pk_we), .pk_rd(pk_rd), .pk_dout(pk_dout), .pk_din(pk_din),
		.mix_wr(mix_wr), .mix_data(mix_data) );

	// ---- YM2151 (jt51) ----
	wire signed [15:0] ym_l, ym_r, ym_l_lo_nc, ym_r_lo_nc; wire ym_sample_nc, ym_ct1, ym_ct2;
	toobin_ym u_ym (
		.clk(clk), .reset(reset), .cen(ce_ym), .cen_p1(ce_ym_p1), .ym_reset_n(ym_reset_n),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we), .ym_dout(ym_dout), .ym_din(ym_din),
		.sample(ym_sample_nc), .aud_left(ym_l), .aud_right(ym_r),
		.aud_left_lo(ym_l_lo_nc), .aud_right_lo(ym_r_lo_nc), .ct1(ym_ct1), .ct2(ym_ct2),
		.ym_irq(ym_irq_w) );
	// ym_rd / cpu_bank / coin counters / T65 register taps / lo-res audio are unused here
	wire _unused_jsa = &{1'b0, ym_rd, cpu_bank_nc, coin_ctr1_nc, coin_ctr2_nc, cpu_sync_nc,
		t65_a_nc, t65_x_nc, t65_y_nc, t65_s_nc, t65_p_nc, ym_sample_nc,
		ym_l_lo_nc, ym_r_lo_nc};

	// ---- POKEY ----
	wire signed [10:0] pk_audio;
	toobin_pokey u_pokey (
		.clk(clk), .reset(reset), .ena(ce_pokey),
		.pk_cs(pk_cs), .pk_addr(pk_addr), .pk_we(pk_we), .pk_rd(pk_rd),
		.pk_dout(pk_dout), .pk_din(pk_din), .audio_out(pk_audio) );

	// ---- POKEY analog output stage (SP-320 sheet 21) ----
	// LM324 2B transimpedance pole (R34 470 || C37 .047, 7.2 kHz) + C47 DC block.
	wire signed [15:0] pk_filt;
	toobin_pokey_out u_pk_out (
		.clk(clk), .reset(reset), .ce(ce_pokey), .bypass(lpf_bypass),
		.pk_dac(pk_audio), .pk_out(pk_filt) );

	// ---- /MIX audio mixer ----
	wire signed [15:0] mix_l, mix_r; wire lpf_engage;
	toobin_jsa_mix u_mix (
		.clk(clk), .reset(reset), .mix_wr(mix_wr), .mix_data(mix_data), .ym_ct1(ym_ct1), .ym_ct2(ym_ct2),
		.ym_left(ym_l), .ym_right(ym_r), .pk_audio(pk_filt),
		.out_left(mix_l), .out_right(mix_r), .lpf_engage(lpf_engage) );

	// ---- output low-pass (SP-320 sheet 21) ----
	// LM324 4A Sallen-Key on each channel, with Q5/Q6 switching C54/C56 in.
	toobin_jsa_lpf u_lpf_l (
		.clk(clk), .reset(reset), .ce(ce_pokey), .engage(lpf_engage), .bypass(lpf_bypass),
		.in(mix_l), .out(aud_left) );
	toobin_jsa_lpf u_lpf_r (
		.clk(clk), .reset(reset), .ce(ce_pokey), .engage(lpf_engage), .bypass(lpf_bypass),
		.in(mix_r), .out(aud_right) );

endmodule
