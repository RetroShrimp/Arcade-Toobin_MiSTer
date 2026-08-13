// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' 68010 main bus.
//
// Composes the tested sub-blocks (toobin_addr_decode, toobin_irq_wd,
// toobin_sound_comm) with the write-registers, the status/switch read mux, the
// video-RAM read-data mux, and the per-region write strobes. Presents a simple
// synchronous CPU bus (a TG68K async-bus wrapper drives cpu_req/uds/lds/rw and
// consumes cpu_dtack; external BRAM/SDRAM provide the *_rdata and take the write
// strobes). Zero-wait for all local/RAM accesses; ROM may extend via rom_ready.
//
// Source: Atari SP-320 schematics (main CPU decode).

module toobin_main_bus
(
	input  logic        clk,
	input  logic        reset,

	// ---- CPU bus (from the TG68K wrapper) ----
	input  logic [23:0] cpu_addr,
	input  logic [15:0] cpu_wdata,
	input  logic        cpu_uds_n,   // D15:8 strobe (active low)
	input  logic        cpu_lds_n,   // D7:0  strobe (active low)
	input  logic        cpu_rw,      // 1=read 0=write
	input  logic        cpu_req,     // access request (from AS)
	input  logic        rom_ready,   // ROM read-data valid (1 for zero-wait BRAM)
	output logic [15:0] cpu_rdata,
	output logic        cpu_dtack,

	// ---- video timing ----
	input  logic        hblank,
	input  logic        vblank,
	input  logic        scanline_match,
	input  logic        vsync_start,

	// ---- board inputs ----
	input  logic [15:0] switches,    // FF8800, active-low (paddles + throws + unused=1)
	input  logic        self_test,   // 1 = self-test switch ON

	// ---- region read data (external memories) ----
	input  logic [15:0] rom_rdata,
	input  logic [15:0] pf_rdata,
	input  logic [15:0] alpha_rdata,
	input  logic [15:0] mob_rdata,
	input  logic [15:0] pal_rdata,
	input  logic [15:0] slip_rdata,
	input  logic [15:0] wram_rdata,
	input  logic  [7:0] eeprom_rdata,

	// ---- region write strobes + data (to external memories) ----
	output logic        be_hi,       // D15:8 lane enabled this access
	output logic        be_lo,       // D7:0  lane enabled this access
	output logic [15:0] cpu_wdata_o, // = cpu_wdata (convenience)
	output logic        pf_we,
	output logic        alpha_we,
	output logic        mob_we,
	output logic        pal_we,
	output logic        slip_we,
	output logic        wram_we,
	output logic        eeprom_we,
	output logic        low_write,   // any decoded /WL write; consumes EEPROM unlock latch

	// ---- control registers ----
	output logic  [4:0] intensity,
	output logic [15:0] hscroll,
	output logic [15:0] vscroll,
	output logic        vscroll_restart,
	output logic  [8:0] irq_scanline,

	// ---- interrupts / watchdog ----
	output logic  [2:0] ipl,
	output logic        watchdog_reset,
	output logic        eeprom_unlock,

	// ---- main-side of the JSA sound mailbox (the mailbox lives in toobin_jsa) ----
	output logic        snd_cmd_wr,     // -> jsa.main_cmd_wr   (main wrote FF8100)
	output logic  [7:0] snd_cmd_data,   // -> jsa.main_cmd_data (= cpu_wdata[7:0])
	output logic        snd_resp_rd,    // -> jsa.main_resp_rd  (main read  FF9800)
	output logic        snd_reset,      // -> jsa.main_sndrst_wr(main wrote FF8400)
	input  logic  [7:0] snd_resp_data,  // = jsa.main_resp_data (FF9800 read data)
	input  logic        snd_irq,        // = jsa.main_irq       (-> IPL1)
	input  logic        snd_m2s_ready   // = jsa.main_to_sound_ready (FF9000 D13)
);

/* verilator lint_off UNUSEDPARAM */
`include "toobin_regions.vh"
/* verilator lint_on UNUSEDPARAM */

	// Intentionally-unused taps kept for clarity / future use.
	/* verilator lint_off UNUSEDSIGNAL */
	wire scanline_pending_nc;    // irq_wd observability output, unused at this level
	/* verilator lint_on UNUSEDSIGNAL */

	wire [4:0] rd_region, wr_region;
	toobin_addr_decode u_dec (.a(cpu_addr), .rd_region(rd_region), .wr_region(wr_region));

	// one write/strobe per rising edge of cpu_req (AS assert); held-level DTACK.
	// The async TG68K (paced by a /4 clock-enable) samples DTACK several clk_sys
	// after AS, so DTACK must be a level held while the access is valid, not a
	// pulse. All CPU-visible memory is single-cycle BRAM => a valid access
	// acknowledges immediately; only a ROM read may wait on rom_ready.
	logic ds_d;
	wire  read_ready = (rd_region == REG_ROM) ? rom_ready : 1'b1;
	assign be_hi       = cpu_req & ~cpu_uds_n;
	assign be_lo       = cpu_req & ~cpu_lds_n;
	assign cpu_wdata_o = cpu_wdata;

	// The 68010 asserts AS before UDS/LDS, so at the AS edge the byte strobes are
	// not yet valid. Fire the WRITE one-shot on the data-strobe assertion instead,
	// when UDS/LDS (be_hi/be_lo) AND the write data are stable.
	wire ds = cpu_req & ~cpu_rw & (be_hi | be_lo);
	always_ff @(posedge clk) begin
		if (reset) ds_d <= 1'b0;
		else       ds_d <= ds;
	end
	wire read_valid = cpu_req & (cpu_rw ? read_ready : 1'b1);

	wire wr = ds & ~ds_d;                  // one-shot write at data-strobe assertion
	// (read side-effect strobe: rd_lo one-shot below, LDS-qualified -- the only
	//  read with a side effect is the sound-response read)

	// ---- per-region write strobes ----
	// RAM regions (pf/alpha/mob/pal/wram/eeprom) take true byte-lane writes.  CONTROL
	// registers hang off the board's write decoder, which is gated by /WL = the 68010
	// LOW-byte write strobe (sheet p068) -- a high-byte-only write must NOT service the
	// watchdog / ack the IRQ / reset sound / unlock the EEPROM / write SLIP or scrolls.
	// The shipped game word-writes these (LDS asserted), so behavior is unchanged for
	// it; byte-cycle accuracy is what the /WL gate provides.
	wire   wl           = ~cpu_lds_n;
	assign low_write    = wr & wl;
	assign pf_we        = wr & (wr_region == REG_PF);
	assign alpha_we     = wr & (wr_region == REG_ALPHA);
	assign mob_we       = wr & (wr_region == REG_MOB);
	assign pal_we       = wr & (wr_region == REG_PAL);
	assign slip_we      = wr & (wr_region == REG_SLIP)   & wl;
	assign wram_we      = wr & (wr_region == REG_WRAM);
	assign eeprom_we    = wr & (wr_region == REG_EEPROM);
	assign eeprom_unlock= wr & (wr_region == REG_EEUNLK) & wl;
	// Sound command/response registers live on the ODD byte lane (D7:0); the decode
	// matches the even/odd word pair (see toobin_addr_decode) and the LANE is selected
	// here by /LDS, like real hardware (no A0 on a 68k bus).  The game only ever word-
	// accesses these (confirmed by disassembly), which asserts LDS -> works; a stray
	// even-byte-only (UDS) access must NOT strobe them.
	assign snd_cmd_wr   = wr & (wr_region == REG_SNDCMD) & ~cpu_lds_n;
	wire   wdog_clr     = wr & (wr_region == REG_WD)     & wl;
	wire   irqack_wr    = wr & (wr_region == REG_IRQACK) & wl;
	wire   main_sndrst  = wr & (wr_region == REG_SNDRST) & wl;
	// Response-read side-effect (clears the response-full flag in the JSA): one-shot
	// on the LDS-qualified read, not on the AS edge -- read byte strobes may lag AS.
	logic rdlo_d;
	wire  rd_lo = cpu_req & cpu_rw & ~cpu_lds_n;
	always_ff @(posedge clk) begin
		if (reset) rdlo_d <= 1'b0;
		else       rdlo_d <= rd_lo;
	end
	wire   main_resp_rd = (rd_lo & ~rdlo_d) & (rd_region == REG_SNDRESP);
	// ---- control registers (latched on the /WL-gated strobe; data = full BD15:0) ----
	always_ff @(posedge clk) begin
		if (reset) begin
			intensity <= 5'd0; irq_scanline <= 9'd0; hscroll <= 16'd0; vscroll <= 16'd0;
			vscroll_restart <= 1'b0;
		end else begin
			// Register the restart one cycle after the write edge.  This guarantees
			// downstream logic observes the newly latched BD14:6 value with the pulse.
			vscroll_restart <= 1'b0;
			if (wr && wr_region == REG_INTENS  && wl) intensity    <= cpu_wdata[4:0];
			if (wr && wr_region == REG_IRQSCAN && wl) irq_scanline <= cpu_wdata[8:0];
			if (wr && wr_region == REG_HSCRL   && wl) hscroll      <= cpu_wdata;
			if (wr && wr_region == REG_VSCRL   && wl) begin
				vscroll <= cpu_wdata;
				if (~cpu_wdata[0] && hblank) vscroll_restart <= 1'b1;
			end
		end
	end

	// ---- main-side of the JSA sound mailbox (the mailbox itself is in toobin_jsa) ----
	// Drive the main-side strobes/data out to jsa; consume its response + IRQ + ready.
	assign snd_cmd_data = cpu_wdata[7:0];     // 0x828101 odd byte -> jsa.main_cmd_data
	assign snd_resp_rd  = main_resp_rd;       // FF9800 read       -> jsa.main_resp_rd
	assign snd_reset    = main_sndrst;        // FF8400 write      -> jsa.main_sndrst_wr
	wire [7:0] main_resp_data = snd_resp_data; // jsa response -> FF9800 read mux
	wire       main_irq       = snd_irq;       // jsa IRQ      -> IPL1
	wire       m2s_ready      = snd_m2s_ready; // jsa mailbox-full -> FF9000 D13 (schematic)

	// ---- interrupts + watchdog ----
	toobin_irq_wd u_irq (
		.clk(clk), .reset(reset),
		.scanline_match(scanline_match), .irqack_wr(irqack_wr), .sound_irq(main_irq),
		.vsync_start(vsync_start), .wdog_clr(wdog_clr),
		.ipl(ipl), .scanline_pending(scanline_pending_nc), .watchdog_reset(watchdog_reset));

	// ---- FF9000 status -- SCHEMATIC layout ----
	// p096 row order: D15=HBLANK, D14=VBLANK, D13=main->sound latch full (0=full),
	// D12=SELF-TEST.  PROVEN by the game ROM itself: both sound-send sites gate on
	// `btst #5,$9000.w` (@0x4904/0x4944) = high-byte bit5 = word D13 -- the game polls
	// D13 as the transmit-latch flag.  MAME's INPUT_PORTS (hblank=D13, ready=D15) has
	// these two swapped; the old RTL shipped MAME's layout, so the send gate was
	// actually polling raster timing.
	wire [15:0] ff9000 = { ~hblank, ~vblank, ~m2s_ready, ~self_test, 12'hFFF };

	// ---- read mux (combinational; registered below before it reaches the CPU) ----
	logic [15:0] cpu_rdata_comb;
	always_comb begin
		case (rd_region)
			REG_ROM:     cpu_rdata_comb = rom_rdata;
			REG_PF:      cpu_rdata_comb = pf_rdata;
			REG_ALPHA:   cpu_rdata_comb = alpha_rdata;
			REG_MOB:     cpu_rdata_comb = mob_rdata;
			REG_PAL:     cpu_rdata_comb = pal_rdata;
			REG_SLIP:    cpu_rdata_comb = slip_rdata;
			REG_WRAM:    cpu_rdata_comb = wram_rdata;
			REG_EEPROM:  cpu_rdata_comb = {8'hFF, eeprom_rdata};
			REG_SW:      cpu_rdata_comb = switches;
			REG_INP:     cpu_rdata_comb = ff9000;
			REG_SNDRESP: cpu_rdata_comb = {8'hFF, main_resp_data};
			default:     cpu_rdata_comb = 16'hFFFF;   // NOPR / unmapped = open bus
		endcase
	end

	// ---- register the read path: settle cpu_rdata_comb for a FULL clk cycle before DTACK
	// tells the CPU it's valid, instead of presenting a purely-combinational value the same
	// cycle DTACK asserts.  cpu_rdata_comb runs through the address decoder + an 11-way case
	// mux + ff9000's live hblank/vblank concatenation -- on real silicon that chain has real
	// propagation delay and can reconverge with a brief glitch, a hazard a zero-delay
	// simulator can never reproduce (every consumer sees an instantly-settled value within
	// the same delta-cycle).  All local regions were already effectively 0-wait; this makes
	// them 1-wait (still far under a ce_cpu period), matching the wait-state pattern ROM
	// reads already use via rom_ready. DTACK stays a HELD LEVEL for the access duration
	// (read_valid does), preserving the existing "not a pulse" contract the TG68K wrapper
	// relies on.
	logic [15:0] cpu_rdata_r;
	logic        cpu_dtack_r;
	always_ff @(posedge clk) begin
		if (reset) begin
			cpu_dtack_r <= 1'b0;
		end else begin
			cpu_dtack_r <= read_valid;
			if (read_valid) cpu_rdata_r <= cpu_rdata_comb;
		end
	end
	assign cpu_dtack = cpu_dtack_r;
	assign cpu_rdata = cpu_rdata_r;

endmodule
