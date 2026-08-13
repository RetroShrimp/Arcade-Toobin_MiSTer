// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
`timescale 1ns/1ps

// Single-port SDR-SDRAM controller for the MiSTer 32MB module (MT48LC16M16 class:
// 4 banks x 13-bit row x 9-bit col x16). READ/WRITE with auto-precharge, CL2.
// Blocking host contract: when `ready` is high, pulse `req` with `addr`/`we`(/`wdata`)
// and `blen`; `ready` drops during the access and returns high when done, read data on
// `rdata` with a one-cycle `valid` pulse per word. AUTO_REFRESH interleaves while idle.
//
// Burst reads: `blen` = words-1 (0/1/3).  The words must be consecutive and the group
// must not cross a row (callers use aligned groups: tile pairs are 2-aligned, sprite
// quads 4-aligned).  One ACTIVE opens the row, then blen+1 READ commands issue on
// consecutive cycles (CAS-pipelined) with auto-precharge (A10) only on the LAST read;
// data words return on consecutive `valid` pulses.  blen=0 is cycle-identical to the
// original single-word read (the HW-proven path); bursts only add mid-transaction READ
// cycles, so every absolute timing (tRCD/CL/tRP/tRC/tRAS) is met a fortiori.  Writes
// are always single-word (blen ignored).
//
// SystemVerilog re-implementation of the proven reference controller
// (Arcade-Atari-system1 rtl/lib/mem/sdram.vhd) -- same command/mode encoding -- so the
// iverilog/verilator flow (which can't run the VHDL original) exercises the identical
// protocol against a behavioral model. Adapted verbatim from the sim-proven Paperboy
// controller written for the author's Atari System 2 core; the logic is
// game-independent. Structured as single-cycle command states + explicit wait states so
// each step is obviously correct. This module's SDRAM_CLK output is the inverted
// controller clock; the MiSTer top instead drives the pin from a phase-shifted PLL
// output (see Toobin.sv) and leaves this one unconnected.
module toobin_sdram #(
	parameter int CLK_MHZ  = 32,    // controller clock in MHz (integer)
	parameter int ROW_BITS = 13,
	parameter int COL_BITS = 9
) (
	input  logic        clk,
	input  logic        reset,

	// Host word port. addr is a 16-bit-word address: {BA[1:0], ROW, COL}.
	input  logic [ROW_BITS+COL_BITS+1:0] addr,
	input  logic [15:0] wdata,
	input  logic        we,
	input  logic [1:0]  blen,       // read burst: words-1 (0/1/3); consecutive, row-aligned group
	input  logic        req,
	output logic [15:0] rdata,
	output logic        valid,
	output logic        ready,

	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic [1:0]  SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CLK,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

// Timing floor: MT48LC16M16A2-7E / common -75-or-faster MiSTer modules at
// CL2.  The -7E refresh-cycle time tRFC is 66 ns even though its ordinary
// ACTIVE-to-ACTIVE tRC is 60 ns; the old controller incorrectly used 60 ns
// for AUTO_REFRESH recovery.  The 18 ns tRCD/tRP values are conservative for
// both the -7E Micron (15 ns) and AS4C -6 (18 ns) families.
//
// Delay minima use ceil(ns*MHz/1000).  Refresh *interval* uses floor so the
// command is issued at 7.8 us or faster, never one clock slower because of
// integer rounding.  At 64 MHz: tRFC=5 clocks and tREFI=499 clocks.
localparam int tINIT = (200000*CLK_MHZ + 999) / 1000;
localparam int tRFC  = (    66*CLK_MHZ + 999) / 1000;
localparam int tRCD  = (    18*CLK_MHZ + 999) / 1000;
localparam int tRP   = (    18*CLK_MHZ + 999) / 1000;
localparam int tMRD  = (    12*CLK_MHZ + 999) / 1000;
localparam int tREFI_RAW = (7800*CLK_MHZ) / 1000;
localparam int tREFI = (tREFI_RAW > 0) ? tREFI_RAW : 1;
localparam logic [15:0] tREFI_LAST = 16'(tREFI - 1);
localparam int CL    = 2;

localparam logic [3:0] CMD_LMR=4'b0000, CMD_REFRESH=4'b0001, CMD_PRECHARGE=4'b0010,
                       CMD_ACTIVE=4'b0011, CMD_WRITE=4'b0100, CMD_READ=4'b0101,
                       CMD_NOP=4'b0111;
localparam logic [12:0] MODE_REG = {3'b000, 1'b1, 2'b00, 3'b010, 1'b0, 3'b000};

localparam int AW     = ROW_BITS + COL_BITS + 2;
localparam int BA_HI  = AW-1,  BA_LO  = AW-2;
localparam int ROW_HI = COL_BITS + ROW_BITS - 1, ROW_LO = COL_BITS;

typedef enum logic [3:0] {
	S_INIT, S_PRE, S_TRP_I, S_REFI, S_TRC_I, S_MRD, S_TMRD,
	S_IDLE, S_ACT, S_TRCD, S_BURST, S_WR, S_RECOV, S_REF, S_TRC
} state_t;
state_t state;                    // all state is cleared in the synchronous reset below

logic [15:0] dly;
logic [3:0]  ref_init;
logic [15:0] rfsh_ctr;
logic        rfsh_req;

logic           we_l;
logic [15:0]    wdata_l;
logic [AW-1:0]  addr_l;
logic [1:0]     blen_l;
logic [2:0]     bcyc;             // burst cycle: READs issue at 0..blen_l, data lands at 3..3+blen_l
logic           pending;          // a captured request awaiting service

// ---- combinational command / address / DQ-OE from the single-cycle states -------
logic [3:0]  cmd;
logic [12:0] a_comb;
logic [1:0]  ba_comb;
logic        dq_oe;

// Column address on A; A10 = read/write with auto-precharge. COL_BITS<=9 so the
// column sits in A[8:0] and A10 is free for the auto-precharge flag. Built as one
// concatenation (iverilog mishandles partial bit-selects inside always_comb).
// Burst: column advances with bcyc; A10 asserts only on the LAST read of the burst
// (bcyc==blen_l) so the row stays open for the intermediate reads.  Writes enter S_WR
// with bcyc==0 and blen_l==0, so they keep auto-precharge exactly as before.
wire [COL_BITS-1:0] col_cur  = addr_l[COL_BITS-1:0] + {{(COL_BITS-3){1'b0}}, bcyc};
wire                ap_last  = (bcyc == {1'b0, blen_l});
wire [12:0] col_a = {2'b00, ap_last, {(10-COL_BITS){1'b0}}, col_cur};
localparam logic [12:0] PRE_ALL = 13'h0400; // A10=1 = precharge all banks

// Pre-extract the address fields as continuous-assign wires; iverilog mishandles
// constant part-selects inside always_* blocks (drives "all bits").
wire [1:0]           ba_w  = addr_l[BA_HI:BA_LO];
wire [ROW_BITS-1:0]  row_w = addr_l[ROW_HI:ROW_LO];
wire [12:0]          row_a = {{(13-ROW_BITS){1'b0}}, row_w};

always_comb begin
	cmd = CMD_NOP; a_comb = '0; ba_comb = '0; dq_oe = 1'b0;
	case (state)
		S_PRE:  begin cmd = CMD_PRECHARGE; a_comb = PRE_ALL; end
		S_REFI: cmd = CMD_REFRESH;
		S_MRD:  begin cmd = CMD_LMR; a_comb = MODE_REG; end
		S_ACT:  begin cmd = CMD_ACTIVE; ba_comb = ba_w; a_comb = row_a; end
		S_BURST: if (bcyc <= {1'b0, blen_l}) begin cmd = CMD_READ; ba_comb = ba_w; a_comb = col_a; end
		S_WR:   begin cmd = CMD_WRITE; ba_comb = ba_w; a_comb = col_a; dq_oe = 1'b1; end
		S_REF:  cmd = CMD_REFRESH;
		default: ;
	endcase
end

// Registered command/address/write-data outputs.  At 64 MHz the combinational
// state->a_comb->SDRAM_A path fails the address setup (tIS) vs the -180deg SDRAM_CLK
// by ~4 ns (STA: the ONLY failing paths are *->SDRAM_A[*]); registering makes each a
// clean reg->pin path Quartus can pack into the I/O output registers.  The resulting
// 1-cycle output delay is absorbed by capturing read data one cycle later (S_RD loads
// dly=CL instead of CL-1), so the SDRAM sees command+address+wdata all shifted by the
// same cycle and every relative timing (tRCD/CL/tRP/tRC) is preserved.
logic [3:0]  cmd_r;  logic [12:0] a_r;  logic [1:0] ba_r;
logic        dqoe_r; logic [15:0] wdata_r;
always_ff @(posedge clk) begin
	if (reset) begin cmd_r <= CMD_NOP; dqoe_r <= 1'b0; end
	else       begin cmd_r <= cmd;     dqoe_r <= dq_oe; end
	a_r <= a_comb; ba_r <= ba_comb; wdata_r <= wdata_l;
end

assign SDRAM_CLK = ~clk;
assign SDRAM_CKE = ~reset;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd_r;
assign SDRAM_A   = a_r;
assign SDRAM_BA  = ba_r;
assign SDRAM_DQ  = dqoe_r ? wdata_r : 16'hzzzz;
assign {SDRAM_DQMH, SDRAM_DQML} = 2'b00;
assign ready     = (state == S_IDLE) && !rfsh_req && !pending;

// helper: wait state that decrements dly, jumps to NEXT when it hits 0.
`define WAIT(NEXT) begin if (dly != 0) dly <= dly - 1'b1; else state <= NEXT; end

always_ff @(posedge clk) begin
	valid <= 1'b0;

	if (state != S_INIT && state != S_PRE && state != S_TRP_I &&
	    state != S_REFI && state != S_TRC_I && state != S_MRD && state != S_TMRD) begin
		if (rfsh_ctr >= tREFI_LAST) begin rfsh_ctr <= '0; rfsh_req <= 1'b1; end
		else rfsh_ctr <= rfsh_ctr + 1'b1;
	end

	if (reset) begin
		state <= S_INIT; dly <= tINIT[15:0]; ref_init <= '0;
		rfsh_ctr <= '0; rfsh_req <= 1'b0; pending <= 1'b0;
	end else begin
		case (state)
		// ---- power-up init ----
		S_INIT:  begin if (dly != 0) dly <= dly - 1'b1; else begin state <= S_PRE; end end
		S_PRE:   begin state <= S_TRP_I; dly <= tRP[15:0]-1'b1; end
		S_TRP_I: begin if (dly != 0) dly <= dly-1'b1; else begin state <= S_REFI; ref_init <= '0; end end
		S_REFI:  begin state <= S_TRC_I; dly <= tRFC[15:0]-1'b1; end
		S_TRC_I: begin if (dly != 0) dly <= dly-1'b1;
		               else if (ref_init == 4'd7) state <= S_MRD;
		               else begin ref_init <= ref_init + 1'b1; state <= S_REFI; end end
		S_MRD:   begin state <= S_TMRD; dly <= tMRD[15:0]-1'b1; end
		S_TMRD:  `WAIT(S_IDLE)

		// ---- normal operation ----
		S_IDLE: begin
			// Capture an incoming request so a coincident refresh can't drop it.
			if (req && !pending) begin
				we_l <= we; wdata_l <= wdata; addr_l <= addr; pending <= 1'b1;
				blen_l <= we ? 2'd0 : blen;          // writes are always single-word
			end
			if (rfsh_req) begin state <= S_REF; rfsh_req <= 1'b0; end
			else if (pending || req) begin pending <= 1'b0; state <= S_ACT; end
		end
		S_ACT:   begin state <= S_TRCD; dly <= tRCD[15:0]-1'b1; end
		S_TRCD:  begin if (dly != 0) dly <= dly-1'b1; else begin state <= we_l ? S_WR : S_BURST; bcyc <= 3'd0; end end
		// READ commands issue at bcyc 0..blen_l (registered outputs shift them 1 clk, same
		// as before); each word's DQ is captured CL+1 cycles after its READ (the +1 absorbs
		// the registered cmd/addr outputs), i.e. bcyc CL+1 .. CL+1+blen_l, on consecutive
		// `valid` pulses.  blen_l==0 is cycle-identical to the old S_RD/S_CL path.
		S_BURST: begin
			bcyc <= bcyc + 3'd1;
			if (bcyc >= 3'(CL+1)) begin rdata <= SDRAM_DQ; valid <= 1'b1; end
			if (bcyc == (3'(CL+1) + {1'b0, blen_l})) begin state <= S_RECOV; dly <= tRP[15:0]-1'b1; end
		end
		S_WR:    begin state <= S_RECOV; dly <= tRP[15:0]-1'b1; end
		S_RECOV: `WAIT(S_IDLE)
		S_REF:   begin state <= S_TRC; dly <= tRFC[15:0]-1'b1; end
		S_TRC:   `WAIT(S_IDLE)
		default: state <= S_IDLE;
		endcase
	end
end

endmodule
