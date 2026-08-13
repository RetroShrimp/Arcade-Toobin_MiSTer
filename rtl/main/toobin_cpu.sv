// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' 68010 CPU wrapper: adapts the (clock-enabled) TG68K async 68k bus to
// the toobin_main_bus synchronous interface, in the single clk_sys domain.
//
// TG68K (System 1 core, generic CPU="01" = 68010) is modified with a `cpu_cen`
// clock-enable so the whole CPU advances at the board's 8 MHz (the original
// 32 MHz MASTER_CLOCK / 4; here cen = clk_sys/8 at 64 MHz).
// Polarities (from TG68K.vhd): AS/UDS/LDS active-low; RW 1=read/0=write; IPL
// active-low ("111"=none); DTACK active-low; RESET/HALT active-low.
//
// 68k byte addressing: the CPU drives A23..A1 + UDS/LDS, so A0 is reconstructed
// from the byte strobes (an odd-byte-only access => A0=1). This makes the
// odd-byte registers (sound command 0x828101, response 0x829801) decode right.

module toobin_cpu
(
	input  logic        clk,        // clk_sys
	input  logic        cen,        // 8 MHz enable
	input  logic        reset,      // active-high; also held while ROM not loaded
	input  logic  [2:0] ipl,        // active-low IPL from toobin_irq_wd (already ~level)

	// synchronous bus to toobin_main_bus
	output logic [23:0] addr,       // byte address (A0 reconstructed)
	output logic [15:0] wdata,
	output logic        uds_n,
	output logic        lds_n,
	output logic        rw,         // 1=read 0=write
	output logic        req,        // = ~AS (access in progress)
	input  logic [15:0] rdata,
	input  logic        dtack,      // active-high
	output logic  [2:0] fc          // function code (7 = CPU space/IACK; 6/2 = program)
);

	wire [31:0] tg_addr;
	wire [15:0] tg_datao;
	wire  [2:0] tg_fc;
	wire        tg_as_n, tg_uds_n, tg_lds_n, tg_rw;
	assign fc = tg_fc;

	// IPL synchronization to the TG68K -- TWO flops, and the second one is deliberately on
	// the NEGEDGE.  The TG68K captures IPL into its internal `cpuipl` on the FALLING edge
	// of clk (TG68K.vhd sync process), through a 2-level interrupt-priority mux.
	//
	//   ipl  --posedge-->  ipl_r  --negedge-->  ipl_rn  -->[TG68K 2-mux]--negedge--> cpuipl
	//
	// Stage 1 (ipl_r, posedge): captures the reconverging `~{sound_irq,scanline_pending}`
	// encode from toobin_irq_wd (routed irq_wd->main_bus->here) with a full posedge->posedge
	// period -- fine.  Stage 2 (ipl_rn, negedge) is the actual fix: it makes the LONG path
	// (ipl_rn -> TG68K interrupt mux -> cpuipl) a full negedge->negedge PERIOD (~15.6 ns)
	// instead of a posedge->negedge HALF-cycle (~7.8 ns @64 MHz).  The only half-cycle left
	// (ipl_r -> ipl_rn) is a bare flop->flop hop with zero logic between, which meets trivially.
	//
	// WHY a single posedge flop is not enough: `ipl_r` is NOT cen-gated (it toggles
	// every posedge), so ipl_r->cpuipl would physically be a HALF cycle -- and an early
	// blanket `set_multicycle_path -setup -end 8` across all of u_cpu told STA to check
	// it 8 CYCLES out (Toobin.sdc now scopes that exception to the TG68K kernel only).
	// STA therefore reported enormous slack while real silicon only had 7.8 ns
	// -- the exact "closes-in-STA / fails-on-hardware" signature (deterministic, zero-delay-sim
	// invisible, 64 MHz-only; atarisys1 runs this core at ~7 MHz where the half-cycle is ~70 ns).
	// The negedge stage makes the long path a real full period, so the multicycle's relaxation
	// is now harmless.  The 1/2-clk added latency is invisible to the ce_cpu(/8) IPL sampling.
	logic [2:0] ipl_r;
	always_ff @(posedge clk) begin
		if (reset) ipl_r <= 3'b111;   // active-low: 111 = no interrupt
		else       ipl_r <= ipl;
	end
	logic [2:0] ipl_rn;
	always_ff @(negedge clk) begin
		if (reset) ipl_rn <= 3'b111;
		else       ipl_rn <= ipl_r;
	end

	// reconstruct A0: 1 only when the odd byte alone is selected (LDS, not UDS)
	wire a0 = (~tg_lds_n) & tg_uds_n;

	assign addr  = {tg_addr[23:1], a0};
	assign wdata = tg_datao;
	assign uds_n = tg_uds_n;
	assign lds_n = tg_lds_n;
	assign rw    = tg_rw;
	assign req   = ~tg_as_n;

	// CPU generic defaults to "01" (68010) in TG68K.vhd, so no override is needed.
	TG68K u_tg68k (
		.CLK    (clk),
		.cpu_cen(cen),
		.RESET  (~reset),      // active-low
		.HALT   (~reset),      // held with reset
		.BERR   (1'b0),
		.IPL    (ipl_rn),     // negedge-synchronized (see above) -- full-period into the TG68K's negedge cpuipl capture
		.ADDR   (tg_addr),
		.FC     (tg_fc),
		.DATAI  (rdata),
		.DATAO  (tg_datao),
		.AS     (tg_as_n),
		.UDS    (tg_uds_n),
		.LDS    (tg_lds_n),
		.RW     (tg_rw),
		.DTACK  (~dtack),      // active-low
		.E      (),
		.VPA    (1'b1),        // no 6800 peripherals
		.VMA    ()
	);

endmodule
