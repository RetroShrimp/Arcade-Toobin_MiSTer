// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// Toobin' core — game logic below the MiSTer `emu` framework glue.
//
// Single clk_sys domain with clock enables (the accurate model: the real main board
// derives CPU/8 MHz and pixel/16 MHz from one 32 MHz master by synchronous division).
//   ce_pix = clk_sys/PIX_DIV (16 MHz pixel enable)   ce_cpu = clk_sys/CPU_DIV (8 MHz 68010)
//   (the MiSTer top runs clk_sys = 64 MHz with PIX_DIV=4, CPU_DIV=8)
//   sound enables reproduce the independent JSA 3.579545 MHz crystal's exact average
//   rate; the mailbox (toobin_sound_comm) is the observable crossing point.
//
// ROM regions: maincpu(512K)+tiles(512K)+sprites(2M) -> SDRAM (toobin_sdram_loader ->
// toobin_gfx_mem -> toobin_sdram); sound ROM(64K) -> BRAM in toobin_jsa; char ROM(16K)
// -> BRAM in toobin_video; work/slip/eeprom RAM -> BRAM here; PF/alpha/MO/palette RAM ->
// BRAM in toobin_video (CPU port via toobin_vram_cpu).
//
// CPU program ROM is served from SDRAM via toobin_cpurom_sdram (rom_ready gates DTACK).

module toobin_core #(
	parameter int SDRAM_CLK_MHZ = 32,  // = clk_sys frequency (controller real-time timing)
	parameter int PIX_DIV = 2,         // clk_sys / PIX_DIV = 16 MHz pixel enable (power of 2)
	parameter int CPU_DIV = 4          // clk_sys / CPU_DIV = 8 MHz 68010 enable (mult of PIX_DIV)
)(
	input  logic        clk_sys,
	input  logic        reset,          // active-high system reset (CPU/video/sound/bus)
	// SDRAM/loader init reset — MUST be ~pll_locked ONLY, never the game reset.  The game reset
	// (RESET|status|buttons) can pulse DURING the ROM download; if the SDRAM controller sees it,
	// SDRAM_CKE drops and it re-enters its 200us init mid-download, so the loader's writes are
	// lost/corrupted (a confirmed black-screen cause on the author's Atari System 2 core).
	// This inits the chip ONCE at PLL lock and holds it up (CKE high) through download + gameplay.
	input  logic        init_reset,

	// ---- HPS ioctl ROM download (index 0) ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	output logic        ioctl_wait,

	// ---- NVRAM (EEPROM) save-back to HPS (index 2) ----
	input  logic        ioctl_upload,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ---- controls ----
	input  logic [15:0] sw_ff8800,      // FF8800 paddles/throws (active-low), from emu
	input  logic        self_test,
	input  logic        coin1,
	input  logic        coin2,

	// ---- video out (single clk_sys, qualified by ce_pix) ----
	output logic        ce_pix,
	output logic  [7:0] vga_r, vga_g, vga_b,
	output logic        hsync, vsync, hblank, vblank,

	// ---- audio ----
	output logic signed [15:0] aud_l, aud_r,

	// ---- SDRAM chip ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CLK,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

	// ===================== clock enables =====================
	// pcnt runs 0..CPU_DIV-1: ce_cpu at 0 (=clk_sys/CPU_DIV), ce_pix every PIX_DIV
	// (PIX_DIV | CPU_DIV, power of 2) so ce_cpu is a subset of ce_pix.
	localparam int PCW = (CPU_DIV <= 1) ? 1 : $clog2(CPU_DIV);
	logic [PCW-1:0] pcnt;
	always_ff @(posedge clk_sys) pcnt <= (reset || pcnt == PCW'(CPU_DIV-1)) ? '0 : pcnt + 1'b1;
	assign ce_pix   = (pcnt & PCW'(PIX_DIV-1)) == '0;
	wire   ce_cpu   = (pcnt == '0);

	// Exact JSA-I crystal chain. YM = 315/88 MHz; 6502/POKEY and jt51 cen_p1
	// are every other YM tick. The hardware top uses CLK_MHZ=64; focused and
	// whole-core simulations use the same module at their configured clock rate.
	wire ce_6502, ce_pokey, ce_ym, ce_ym_p1;
	toobin_jsa_cen #(.CLK_MHZ(SDRAM_CLK_MHZ)) u_jsa_cen (
		.clk(clk_sys), .reset(reset), .ce_ym(ce_ym), .ce_ym_p1(ce_ym_p1),
		.ce_6502(ce_6502), .ce_pokey(ce_pokey) );

	// ===================== ROM download router =====================
	wire  [7:0] ld_data;
	wire        maincpu_wr;  wire [18:0] maincpu_addr;
	wire        sndcpu_wr;   wire [15:0] sndcpu_addr;
	wire        tiles_wr;    wire [18:0] tiles_addr;
	wire        sprites_wr;  wire [20:0] sprites_addr;
	wire        chars_wr;    wire [13:0] chars_addr;
	wire        rom_loaded;
	toobin_rom_loader u_loader (
		.clk(clk_sys), .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index),
		.data(ld_data),
		.maincpu_wr(maincpu_wr), .maincpu_addr(maincpu_addr),
		.sndcpu_wr(sndcpu_wr),   .sndcpu_addr(sndcpu_addr),
		.tiles_wr(tiles_wr),     .tiles_addr(tiles_addr),
		.sprites_wr(sprites_wr), .sprites_addr(sprites_addr),
		.chars_wr(chars_wr),     .chars_addr(chars_addr),
		.rom_loaded(rom_loaded) );

	wire watchdog_reset;
	wire vid_reset = reset | ~rom_loaded;   // watchdog does not stop the PCB raster counters
	wire cpu_reset = reset | ~rom_loaded | watchdog_reset;

	// ===================== SDRAM datapath =====================
	// loader-writer -> gfx_mem dl port
	wire        dl_wr;   wire [23:0] dl_waddr; wire [15:0] dl_wdata; wire dl_ack;
	toobin_sdram_loader u_sdload (
		.clk(clk_sys), .reset(init_reset),   // run during download regardless of game reset
		.maincpu_wr(maincpu_wr), .maincpu_addr(maincpu_addr),
		.tiles_wr(tiles_wr),     .tiles_addr(tiles_addr),
		.sprites_wr(sprites_wr), .sprites_addr(sprites_addr),
		.ld_data(ld_data), .wr_busy(ioctl_wait),
		.dl_wr(dl_wr), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .dl_ack(dl_ack) );

	// gfx_mem clients: sprite column (video, burst-4), tile (video), and CPU ROM
	// (via adapter).
	wire        sprb_req;  wire [17:0] sprb_addr;   wire sprb_valid; wire [15:0] sprb_word;
	wire        tile_req;  wire [16:0] tile_addr;  wire tile_valid; wire [31:0] tile_data;
	wire        gcpu_req;  wire [17:0] gcpu_addr;   wire gcpu_valid; wire [15:0] gcpu_data;
	wire        sd_req;    wire [23:0] sd_addr;     wire sd_we; wire [1:0] sd_blen; wire [15:0] sd_wdata;
	wire        sd_ready, sd_valid; wire [15:0] sd_rdata;

	toobin_gfx_mem #(.AW(24), .CPU_BASE(24'h000000), .TILE_BASE(24'h040000), .SPR_BASE(24'h080000)) u_gfx (
		.clk(clk_sys), .reset(init_reset),   // arbiter stays up across game reset (holds ROMs)
		.sprb_req(sprb_req),
		.sprb_addr(sprb_addr), .sprb_valid(sprb_valid), .sprb_word(sprb_word),
		.tile_req(tile_req),
		.tile_addr(tile_addr), .tile_valid(tile_valid), .tile_data(tile_data),
		.spr_req(1'b0), .spr_addr('0), .spr_valid(), .spr_data(), .spr_word(),
		.cpu_req(gcpu_req), .cpu_addr(gcpu_addr), .cpu_valid(gcpu_valid), .cpu_data(gcpu_data),
		.dl_wr(dl_wr), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .dl_ack(dl_ack),
		.sd_req(sd_req), .sd_addr(sd_addr), .sd_we(sd_we), .sd_blen(sd_blen), .sd_wdata(sd_wdata),
		.sd_ready(sd_ready), .sd_valid(sd_valid), .sd_rdata(sd_rdata) );

	toobin_sdram #(.CLK_MHZ(SDRAM_CLK_MHZ), .ROW_BITS(13), .COL_BITS(9)) u_sdram (
		.clk(clk_sys), .reset(init_reset), .addr(sd_addr), .wdata(sd_wdata), .we(sd_we), .blen(sd_blen), .req(sd_req),
		.rdata(sd_rdata), .valid(sd_valid), .ready(sd_ready),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE) );

	// ===================== CPU + main bus =====================
	wire [23:0] cpu_addr; wire [15:0] cpu_wdata, cpu_rdata;
	wire cpu_uds_n, cpu_lds_n, cpu_rw, cpu_req, cpu_dtack; wire [2:0] cpu_ipl, cpu_fc;

	toobin_cpu u_cpu (
		.clk(clk_sys), .cen(ce_cpu), .reset(cpu_reset), .ipl(cpu_ipl),
		.addr(cpu_addr), .wdata(cpu_wdata), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n),
		.rw(cpu_rw), .req(cpu_req), .rdata(cpu_rdata), .dtack(cpu_dtack), .fc(cpu_fc) );

	// region read-back + write strobes
	wire [15:0] rom_q, pf_q, alpha_q, mob_q, pal_q, slip_q, wram_q; wire [7:0] eep_q;
	wire        rom_ready;
	wire be_hi, be_lo; wire [15:0] wdo;
	wire pf_we, alpha_we, mob_we, pal_we, slip_we, wram_we, eep_we, low_write;
	wire [4:0] intensity; wire [15:0] hscroll, vscroll; wire vscroll_restart;
	wire eeprom_unlock;
	// main-side sound mailbox (mailbox lives in toobin_jsa)
	wire        snd_cmd_wr, snd_resp_rd, snd_reset;   // main_bus -> jsa
	wire  [7:0] snd_cmd_data;
	wire  [7:0] snd_resp_data;                        // jsa -> main_bus
	wire        snd_irq, snd_m2s_ready;
	wire scanline_match, vblank_start, vsync_start; wire [8:0] irq_scanline;

	toobin_main_bus u_bus (
		.clk(clk_sys), .reset(reset),
		.cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
		.cpu_rw(cpu_rw), .cpu_req(cpu_req), .rom_ready(rom_ready),
		.cpu_rdata(cpu_rdata), .cpu_dtack(cpu_dtack),
		.hblank(hblank), .vblank(vblank), .scanline_match(scanline_match), .vsync_start(vsync_start),
		.switches(sw_ff8800), .self_test(self_test),
		.rom_rdata(rom_q), .pf_rdata(pf_q), .alpha_rdata(alpha_q), .mob_rdata(mob_q),
		.pal_rdata(pal_q), .slip_rdata(slip_q), .wram_rdata(wram_q), .eeprom_rdata(eep_q),
		.be_hi(be_hi), .be_lo(be_lo), .cpu_wdata_o(wdo),
		.pf_we(pf_we), .alpha_we(alpha_we), .mob_we(mob_we), .pal_we(pal_we),
		.slip_we(slip_we), .wram_we(wram_we), .eeprom_we(eep_we), .low_write(low_write),
		.intensity(intensity), .hscroll(hscroll), .vscroll(vscroll),
		.vscroll_restart(vscroll_restart), .irq_scanline(irq_scanline),
		.ipl(cpu_ipl), .watchdog_reset(watchdog_reset), .eeprom_unlock(eeprom_unlock),
		.snd_cmd_wr(snd_cmd_wr), .snd_cmd_data(snd_cmd_data), .snd_resp_rd(snd_resp_rd), .snd_reset(snd_reset),
		.snd_resp_data(snd_resp_data), .snd_irq(snd_irq), .snd_m2s_ready(snd_m2s_ready) );

	// ROM region read predicate (same decode the bus uses)
	wire [4:0] rd_region, wr_region_nc;
	toobin_addr_decode u_dec (.a(cpu_addr), .rd_region(rd_region), .wr_region(wr_region_nc));
	/* verilator lint_off UNUSEDPARAM */
	`include "toobin_regions.vh"
	/* verilator lint_on UNUSEDPARAM */
	wire rom_req = cpu_req & cpu_rw & (rd_region == REG_ROM);

	toobin_cpurom_sdram u_cpurom (
		.clk(clk_sys), .reset(reset),
		.rom_req(rom_req), .rom_byte_addr(cpu_addr[18:0]), .rom_rdata(rom_q), .rom_ready(rom_ready),
		.cpu_req(gcpu_req), .cpu_addr(gcpu_addr), .cpu_valid(gcpu_valid), .cpu_data(gcpu_data) );

	// ===================== CPU-side BRAM RAMs =====================
	toobin_dpram #(.DW(16),.AW(13)) u_wram (.clk(clk_sys),
		.a_addr(cpu_addr[13:1]), .a_din(wdo), .a_we({wram_we&be_hi, wram_we&be_lo}), .a_dout(wram_q),
		.b_addr('0), .b_din('0), .b_we('0), .b_re(1'b1), .b_dout());
	// SLINKPTR: a SINGLE latch, not a RAM (schematic p075: 15F latches BD7:0 on /SLINKPTR).
	// The old 256-word RAM wrote at cpu_addr[8:1] (canonical FF8380 -> entry 0xC0) while the
	// renderer read hardwired entry 0 -- the game's start-link NEVER reached the MO walker
	// at all.  A single latch is written by every decoded FF8380 alias and
	// read back (MAME models it readable); the renderer consumes [7:0].  High byte stored
	// for read-back compatibility only (the physical 15F latches BD7:0).
	logic [15:0] slip_latch;
	always_ff @(posedge clk_sys) begin
		if (reset) slip_latch <= 16'h0000;
		else if (slip_we) begin
			if (be_lo) slip_latch[7:0]  <= wdo[7:0];
			if (be_hi) slip_latch[15:8] <= wdo[15:8];
		end
	end
	assign slip_q = slip_latch;
	wire [15:0] slip0 = slip_latch;
	// ---- 2804 EEPROM (68010 main bus, byte lane D7:0) ---------------------------------
	// NO ROM/NVRAM DATA IS EMBEDDED IN RTL.  Standard MiSTer practice (matches the System1
	// reference cores): the EEPROM contents come from the DOWNLOAD -- the MRA appends a 512-byte
	// region at the index-0 stream tail (EEP_BASE 0x314000-0x3141FF; shipped erased = 0xFF, like
	// the System1 MRAs' `<part repeat="512">FF</part>` fill), and any previously-saved settings
	// are RESTORED from NVRAM (index 2) on top of it.  A load write always wins -- the 68010 is
	// held in reset for the whole download (cpu_reset), so it can never collide with a CPU write.
	// Only an unlocked, non-busy accepted write marks NVRAM dirty for save-back;
	// eep_dump_data is an independent combinational readback for HPS upload (index 2).
	wire        eep_ld_we;
	wire  [8:0] eep_ld_addr;
	wire  [7:0] eep_ld_data;
	wire        eep_cpu_we  = eep_we & be_lo;
	wire        eep_write_accepted, eep_busy;
	wire  [8:0] eep_dump_addr;
	wire  [7:0] eep_dump_data;
	toobin_eeprom_2804 #(
		.CLK_HZ(SDRAM_CLK_MHZ * 1_000_000)
	) u_eeprom (
		.clk(clk_sys), .init_reset(init_reset), .reset(cpu_reset),
		.unlock(eeprom_unlock), .low_write(low_write),
		.cpu_we(eep_cpu_we), .cpu_addr(cpu_addr[9:1]), .cpu_wdata(wdo[7:0]),
		.cpu_rdata(eep_q), .busy(eep_busy), .write_accepted(eep_write_accepted),
		.load_we(eep_ld_we), .load_addr(eep_ld_addr), .load_data(eep_ld_data),
		.dump_addr(eep_dump_addr), .dump_data(eep_dump_data) );

	// ---- NVRAM transport/save-back to HPS index 2. HPS paces ioctl_addr[8:0]
	//      and samples ioctl_din = eep_dump_data during upload.
	// Request a save only AFTER the EEPROM has been QUIESCENT for ~1 s.  Each CPU EEPROM
	// write re-arms the settle counter, so a game HUNG in a routine that writes the EEPROM
	// continuously (the blank-EEPROM write-defaults loop) NEVER settles -> never requests a
	// save -> the HPS "Saving..." dialog can never be flooded / the OSD can never be blocked.
	// A normally-running game writes settings/scores occasionally, settles, and saves once.
	// Dirty metadata follows the nonvolatile cells across board/game reset; only
	// FPGA initialization, image restore, or an actual index-2 upload clears it.
	toobin_nvram_io u_nvram_io (
		.clk(clk_sys), .init_reset(init_reset), .write_accepted(eep_write_accepted),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
		.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .ioctl_upload(ioctl_upload),
		.load_we(eep_ld_we), .load_addr(eep_ld_addr), .load_data(eep_ld_data),
		.dump_addr(eep_dump_addr), .dump_data(eep_dump_data),
		.ioctl_upload_req(ioctl_upload_req), .ioctl_upload_index(ioctl_upload_index),
		.ioctl_din(ioctl_din) );

	// ===================== CPU <-> video-RAM adapter =====================
	wire        pf_wr;  wire [12:0] pf_wr_addr; wire [31:0] pf_wr_data; wire [3:0] pf_wr_be;
	wire        a_wr;   wire [11:0] a_wr_addr;  wire [15:0] a_wr_data;  wire [1:0] a_wr_be;
	wire        mo_wr;  wire  [9:0] mo_wr_addr; wire [15:0] mo_wr_data;  wire [1:0] mo_wr_be;
	wire        pal_wr; wire  [9:0] pal_wr_addr; wire [15:0] pal_wr_data; wire [1:0] pal_wr_be;
	wire [31:0] pf_rdata32; wire [15:0] a_rdata16, mo_rdata16, pal_rdata16;
	wire [12:0] pf_cpu_addr_nc; wire [11:0] a_cpu_addr_nc; wire [9:0] mo_cpu_addr_nc, pal_cpu_addr_nc;

	toobin_vram_cpu u_vram (
		.cpu_addr(cpu_addr), .cpu_wdata(wdo), .be_hi(be_hi), .be_lo(be_lo),
		.pf_we(pf_we), .alpha_we(alpha_we), .mob_we(mob_we), .pal_we(pal_we),
		.pf_rdata32(pf_rdata32), .a_rdata16(a_rdata16), .mo_rdata16(mo_rdata16), .pal_rdata16(pal_rdata16),
		.pf_wr(pf_wr), .pf_wr_addr(pf_wr_addr), .pf_wr_data(pf_wr_data), .pf_wr_be(pf_wr_be),
		.a_wr(a_wr), .a_wr_addr(a_wr_addr), .a_wr_data(a_wr_data), .a_wr_be(a_wr_be),
		.mo_wr(mo_wr), .mo_wr_addr(mo_wr_addr), .mo_wr_data(mo_wr_data), .mo_wr_be(mo_wr_be),
		.pal_wr(pal_wr), .pal_wr_addr(pal_wr_addr), .pal_wr_data(pal_wr_data), .pal_wr_be(pal_wr_be),
		.pf_cpu_addr(pf_cpu_addr_nc), .a_cpu_addr(a_cpu_addr_nc),
		.mo_cpu_addr(mo_cpu_addr_nc), .pal_cpu_addr(pal_cpu_addr_nc),
		.pf_rdata(pf_q), .alpha_rdata(alpha_q), .mob_rdata(mob_q), .pal_rdata(pal_q) );

	// ===================== video =====================
	wire [9:0] scrollx = hscroll[15:6];   // reg >> 6
	wire [9:0] scrolly = vscroll[15:6];

	toobin_video u_video (
		.clk(clk_sys), .ce(ce_pix), .reset(vid_reset),
		.char_wr(chars_wr), .char_wr_addr(chars_addr), .char_wr_data(ld_data),
		.tile_req(tile_req), .tile_addr(tile_addr), .tile_valid(tile_valid), .tile_data(tile_data),
		.pf_wr(pf_wr), .pf_wr_addr(pf_wr_addr), .pf_wr_data(pf_wr_data), .pf_wr_be(pf_wr_be),
		.a_wr(a_wr), .a_wr_addr(a_wr_addr), .a_wr_data(a_wr_data), .a_wr_be(a_wr_be),
		.mo_wr(mo_wr), .mo_wr_addr(mo_wr_addr), .mo_wr_data(mo_wr_data), .mo_wr_be(mo_wr_be),
		.pal_wr(pal_wr), .pal_wr_addr(pal_wr_addr), .pal_wr_data(pal_wr_data), .pal_wr_be(pal_wr_be),
		.scrollx(scrollx), .scrolly(scrolly), .vscroll_restart(vscroll_restart),
		.intensity(intensity), .start_link(slip0[7:0]),
		.sprb_addr(sprb_addr), .sprb_req(sprb_req), .sprb_valid(sprb_valid), .sprb_word(sprb_word),
		.vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
		.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .ce_pix(),
		.pf_rdata(pf_rdata32), .a_rdata(a_rdata16), .mo_rdata(mo_rdata16), .pal_rdata(pal_rdata16),
		.irq_scanline(irq_scanline), .scanline_match(scanline_match),
		.vblank_start(vblank_start), .vsync_start(vsync_start) );

	// ===================== sound (JSA I) =====================
	// toobin_jsa owns the sound mailbox; main_bus drives its main side.
	toobin_jsa u_jsa (
		.clk(clk_sys), .reset(reset),
		.ce_6502(ce_6502), .ce_ym(ce_ym), .ce_ym_p1(ce_ym_p1), .ce_pokey(ce_pokey),
		.rom_wr(sndcpu_wr), .rom_wr_addr(sndcpu_addr), .rom_wr_data(ld_data),
		.main_cmd_wr(snd_cmd_wr), .main_cmd_data(snd_cmd_data), .main_resp_rd(snd_resp_rd),
		.main_sndrst_wr(snd_reset), .main_resp_data(snd_resp_data), .main_irq(snd_irq),
		.main_to_sound_ready(snd_m2s_ready),
		.coin1(coin1), .coin2(coin2), .self_test(self_test),
		// Sheet-21 output low-pass modelled; 0 = hardware-accurate. Hook this to an
		// OSD option if the always-on 8.9 kHz corner is ever worth A/B-ing.
		.lpf_bypass(1'b0),
		.aud_left(aud_l), .aud_right(aud_r) );

	// tie unused (sub-tile scroll bits, write-region tap, 68k function code, slip high byte)
	wire unused = &{1'b0, eep_busy, cpu_fc,
		wr_region_nc, hscroll[5:0], vscroll[5:0],
		pf_cpu_addr_nc, a_cpu_addr_nc, mo_cpu_addr_nc, pal_cpu_addr_nc, slip0[15:8]};

endmodule
