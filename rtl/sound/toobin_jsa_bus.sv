// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' JSA-I sound board bus — composes toobin_jsa_decode + toobin_jsa_mem +
// toobin_jsa_io + toobin_sound_comm into the 6502's bus, and exposes YM2151 +
// POKEY ports for the external cores.  This is the whole JSA-I board minus the
// 6502, YM2151, and POKEY cores (which attach at the edges).
//
// Bus timing: `ce` marks a valid 6502 bus cycle; reads mux combinationally, the
// RAM/ROM read is registered (present addr one ce early, as for a sync memory).

module toobin_jsa_bus
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,             // 6502 bus-cycle enable
	input  logic        ce_jsa,         // JSA master enable (sound-IRQ divider)

	// ---- 6502 ----
	input  logic [15:0] cpu_addr,
	input  logic  [7:0] cpu_dout,       // 6502 write data
	input  logic        cpu_rnw,        // 1 = read
	output logic  [7:0] cpu_din,        // read data to 6502
	output logic        cpu_irq,        // 6502 IRQ = periodic timer OR YM2151 (shared /IRQ net, p104)
	input  logic        ym_irq,         // YM2151 timer IRQ (active-high)
	output logic        cpu_nmi,        // command-pending NMI
	output logic        cpu_reset,      // sound reset from main CPU

	// ---- ROM loader ----
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,

	// ---- main-CPU mailbox side ----
	input  logic        main_cmd_wr,
	input  logic  [7:0] main_cmd_data,
	input  logic        main_resp_rd,
	input  logic        main_sndrst_wr,
	output logic  [7:0] main_resp_data,
	output logic        main_irq,
	output logic        main_to_sound_ready,  // FF9000 status D13 (main->sound mailbox full)

	// ---- board inputs / outputs ----
	input  logic        coin1,
	input  logic        coin2,
	input  logic        self_test,
	output logic        ym_reset_n,
	output logic        coin_ctr1,
	output logic        coin_ctr2,
	output logic  [1:0] cpu_bank,

	// ---- YM2151 external core ----
	output logic        ym_cs,          // access strobe (this cycle)
	output logic        ym_a0,          // register select
	output logic        ym_we,          // write strobe (ce-gated)
	output logic        ym_rd,          // read strobe  (ce-gated)
	output logic  [7:0] ym_dout,        // 6502 -> YM data
	input  logic  [7:0] ym_din,         // YM -> 6502 data

	// ---- POKEY external core ----
	output logic        pk_cs,
	output logic  [3:0] pk_addr,
	output logic        pk_we,
	output logic        pk_rd,
	output logic  [7:0] pk_dout,
	input  logic  [7:0] pk_din,

	// ---- /MIX write (to the audio mixer) ----
	output logic        mix_wr,
	output logic  [7:0] mix_data
);

	// ---- decode ----
	wire sel_ram, sel_ym, sel_rdp, sel_rdio, sel_irqack, sel_voice,
	     sel_wrp, sel_wrio, sel_mix, sel_pokey, sel_bank, sel_rom, ym_reg;
	wire [3:0] pokey_reg;
	toobin_jsa_decode u_dec (
		.addr(cpu_addr), .sel_ram(sel_ram), .sel_ym(sel_ym), .sel_rdp(sel_rdp),
		.sel_rdio(sel_rdio), .sel_irqack(sel_irqack), .sel_voice(sel_voice),
		.sel_wrp(sel_wrp), .sel_wrio(sel_wrio), .sel_mix(sel_mix), .sel_pokey(sel_pokey),
		.sel_bank(sel_bank), .sel_rom(sel_rom), .ym_reg(ym_reg), .pokey_reg(pokey_reg) );

	wire wr_stb = ce & ~cpu_rnw;
	wire rd_stb = ce &  cpu_rnw;
	wire unused = &{1'b0, sel_voice};            // /VOICE (TMS5220) depopulated on Toobin
	assign mix_wr   = sel_mix & wr_stb;          // /MIX (0x2A06) -> audio mixer
	assign mix_data = cpu_dout;

	// ---- memory ----
	wire [7:0] mem_dout;
	toobin_jsa_mem u_mem (
		.clk(clk), .rom_wr(rom_wr), .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data),
		.addr(cpu_addr), .din(cpu_dout), .we(wr_stb & sel_ram),
		.sel_ram(sel_ram), .sel_bank(sel_bank), .sel_rom(sel_rom), .bank(cpu_bank),
		.dout(mem_dout) );

	// ---- sound comm mailbox ----
	wire [7:0] snd_cmd_data;
	wire       snd_nmi, snd_reset, snd2main_ready;
	toobin_sound_comm u_comm (
		.clk(clk), .reset(reset),
		.main_cmd_wr(main_cmd_wr), .main_cmd_data(main_cmd_data), .main_resp_rd(main_resp_rd),
		.main_sndrst_wr(main_sndrst_wr), .main_resp_data(main_resp_data), .main_irq(main_irq),
		.main_to_sound_ready(main_to_sound_ready), .sound_to_main_ready(snd2main_ready),
		.snd_cmd_rd(sel_rdp & rd_stb), .snd_resp_wr(sel_wrp & wr_stb), .snd_resp_data(cpu_dout),
		.snd_cmd_data(snd_cmd_data), .snd_nmi(snd_nmi), .snd_reset(snd_reset) );

	// ---- I/O + banking + sound IRQ ----
	wire [7:0] rdio_data;
	wire       sound_irq;
	toobin_jsa_io u_io (
		.clk(clk), .reset(reset), .ce_jsa(ce_jsa),
		.wrio_wr(sel_wrio & wr_stb), .wrio_data(cpu_dout),
		.irqack((sel_irqack) & ce),   // /IRQACK on read or write to 0x2806
		.self_test(self_test), .nmi_line_n(~snd_nmi), .resp_full(snd2main_ready),
		.coin1(coin1), .coin2(coin2),
		.cpu_bank(cpu_bank), .coin_ctr1(coin_ctr1), .coin_ctr2(coin_ctr2),
		.ym_reset_n(ym_reset_n), .rdio_data(rdio_data), .sound_irq(sound_irq) );

	// ---- YM / POKEY external strobes ----
	assign ym_cs   = sel_ym;
	assign ym_a0   = ym_reg;
	assign ym_we   = sel_ym & wr_stb;
	assign ym_rd   = sel_ym & rd_stb;
	assign ym_dout = cpu_dout;
	assign pk_cs   = sel_pokey;
	assign pk_addr = pokey_reg;
	assign pk_we   = sel_pokey & wr_stb;
	assign pk_rd   = sel_pokey & rd_stb;
	assign pk_dout = cpu_dout;

	// ---- 6502 read mux ----
	always_comb begin
		if      (sel_ram || sel_bank || sel_rom) cpu_din = mem_dout;
		else if (sel_ym)                         cpu_din = ym_din;
		else if (sel_rdp)                        cpu_din = snd_cmd_data;
		else if (sel_rdio)                       cpu_din = rdio_data;
		else if (sel_pokey)                      cpu_din = pk_din;
		else                                     cpu_din = 8'hFF;   // irqack/voice/mix/gaps
	end

	assign cpu_irq   = sound_irq | ym_irq;   // wired-OR of the periodic timer + YM /IRQ (p104/p106-107)
	assign cpu_nmi   = snd_nmi;
	assign cpu_reset = snd_reset;

endmodule
