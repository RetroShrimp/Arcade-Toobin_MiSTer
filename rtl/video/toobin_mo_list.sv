// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' motion-object list walker (builds one scanline's live sprite list).
//
// Toobin's SLIP is a single band (slipheight 1024 >= 512-tall MO bitmap), so the
// starting link is slipram[0] & 0xff (passed in as start_link).  From there we walk
// the linked list in MO RAM (256 entries x 4 words at 0xC09800): entry = ram[link*4
// + {0,1,2,3}]; next link = WORD2 & 0x00ff.  Stop on a revisited link or after 256
// entries (MAX_PER_BANK).  Each visited entry is decoded (per atarimo masks) and
// written to the active-list scratch RAM for the rasterizer.  The renderer re-runs
// this walk whenever MO RAM is written or start_link moves -- SLINKPTR and MO links
// change mid-frame -- and reuses the built list otherwise (toobin_mo_render's
// active-list cache).  What is built here depends on neither scanline nor scroll.
//
// Word fields (schematic sheet 6 latch wiring + MAME atarimo config -- the link
// lives in w2, NOT w0; w0[7:0] is ypos-low/size bits):
//   w0: abs[15], ypos[14:6], height[5:3], width[2:0]
//   w1: vflip[15], hflip[14], code[13:0]
//   w2: link[7:0]            (D15:12 "palette" label on p096 connects to nothing)
//   w3: xpos[15:6], MOPRI[5:4], color[3:0]
//
// Active entry (48b): {priority[1:0],abs,vflip,hflip, height[2:0],width[2:0], yraw[8:0],
//                      xraw[9:0], color[3:0], code[13:0]}.

module toobin_mo_list
(
	input  logic        clk,
	input  logic        reset,
	// MO RAM CPU port (16-bit words, 1024 words); read-back valid 1 clk after addr
	input  logic        mo_wr,
	input  logic  [9:0] mo_wr_addr,      // word address link*4+widx (CPU read+write)
	input  logic [15:0] mo_wr_data,
	input  logic  [1:0] mo_wr_be,        // [1]=D15:8 (UDS), [0]=D7:0 (LDS)
	output logic [15:0] mo_rdata,        // moram[mo_wr_addr] (CPU read-back)
	// frame control
	input  logic        start,           // pulse to (re)build the active list
	input  logic  [7:0] start_link,      // slipram[0] & 0xff
	// active-list read port (for the rasterizer)
	input  logic  [7:0] rd_index,
	output logic [47:0] rd_entry,
	output logic  [8:0] count,           // number of active entries
	output logic        busy
);

	// ---- MO RAM: CPU write/read (A) + engine read (B) ----
	// Use the proven byte-enabled dual-port wrapper.  Writing array slices inline
	// made Quartus 17 implement both byte lanes as 16K flip-flops instead of M10K.
	logic  [9:0] mo_rd_addr;
	logic [15:0] mo_rd_q;
	toobin_dpram #(.DW(16), .AW(10)) u_moram (
		.clk(clk),
		.a_addr(mo_wr_addr), .a_din(mo_wr_data), .a_we(mo_wr ? mo_wr_be : 2'b00), .a_dout(mo_rdata),
		.b_addr(mo_rd_addr), .b_din(16'b0),       .b_we(2'b00), .b_re(1'b1),       .b_dout(mo_rd_q) );

	// ---- active-list RAM: engine write (A) + rasterizer read (B) ----
	logic [47:0] actram [0:255];
	logic  [7:0] act_wr_addr;
	logic [47:0] act_wr_data;
	logic        act_we;
	always_ff @(posedge clk) begin
		if (act_we) actram[act_wr_addr] <= act_wr_data;
		rd_entry <= actram[rd_index];
	end

	// ---- visited bitmap ----
	logic [255:0] visited;

	// ---- FSM ----
	// PIPELINED against the MO RAM's 1-clock read latency.  The earlier walk issued
	// one address, idled a cycle, then collected (S_ISSUE/S_WAIT/S_COLLECT), i.e. 3
	// clocks per word and ~13-17 clocks per entry -- three times the memory's actual
	// cost.  That is the dominant term in the per-line render budget (measured at
	// ~16.7 clk/entry under full SDRAM contention, so a 65-entry chain spent ~1085 of
	// 2548 clk), which is why it is worth pipelining rather than just caching.
	//
	// The port is registered-address / registered-output: an address ASSIGNED in
	// cycle t is presented in t+1 and its data is readable in t+2.  So addresses for
	// w0..w3 issue on four consecutive cycles and the words land two cycles behind.
	// The chain is inherently serial -- the next entry's address needs w2 -- but w2
	// is readable one cycle before w3, so the next entry's w0 address issues off
	// mo_rd_q directly (next_link) while w3 is still in flight.  Steady state is
	// four clocks per entry with no idle cycle.
	//
	// One free-running 2-bit `phase` drives both ends, because the data beat is
	// exactly two behind the address beat and the entry period is four:
	//   phase 0  address w0            capture w2 of the PREVIOUS entry -> next link
	//   phase 1  address w1            capture w3 of the previous entry -> STORE it
	//   phase 2  address w2            capture w0 of the current entry
	//   phase 3  address w3            capture w1 of the current entry
	// `warm` suppresses the two previous-entry captures until the first entry has
	// actually issued all four of its addresses.
	typedef enum logic [1:0] { S_IDLE, S_WALK, S_TAIL } state_t;
	state_t      st;
	logic  [7:0] cur_link;
	logic  [1:0] phase;
	logic        warm;
	logic [15:0] w0, w1;
	logic  [8:0] cnt;

	assign count = cnt;
	assign busy  = (st != S_IDLE);

	// Link pointer comes from WORD 2 (schematic sheet 6: 17F link register is loaded
	// from the C09804 word; MAME linkmask {{0,0,0x00ff,0}}).  Was w0[7:0] -- which is
	// ypos-low/size bits -- so the walker chased a garbage chain.
	// Both of these read the port LIVE: w2 lands on phase 0 and w3 on phase 1/S_TAIL,
	// and each is consumed on exactly that cycle -- w2 needs no register at all, since
	// its only live field is the link.  (D15:12, labelled "palette" on p096, connects
	// to nothing on silicon; D11:8 likewise.)
	wire  [7:0] next_link = mo_rd_q[7:0];       // valid on phase 0 (w2 on the port)
	wire [15:0] w3_live   = mo_rd_q;            // valid on the store cycle

	// Decode the collected words into a packed active entry.  w0..w2 are registered;
	// w3 is taken LIVE off the read port, because the entry is stored on the very
	// cycle w3 arrives -- registering it first would cost a cycle per entry and gain
	// nothing.  `entry` is therefore only meaningful on a store cycle (phase 1 with
	// warm, and S_TAIL), which is the only place it is consumed.
	wire [13:0] code   = w1[13:0];
	wire        hflip  = w1[14];
	wire        vflip  = w1[15];
	wire  [3:0] color  = w3_live[3:0];
	wire  [1:0] mopri  = w3_live[5:4];
	wire  [9:0] xraw   = w3_live[15:6];
	wire  [8:0] yraw   = w0[14:6];
	wire  [2:0] width  = w0[2:0];
	wire  [2:0] height = w0[5:3];
	wire        absol  = w0[15];
	wire [47:0] entry  = { mopri, absol, vflip, hflip, height, width, yraw, xraw, color, code };

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= S_IDLE; cnt <= 0; act_we <= 1'b0; visited <= '0; warm <= 1'b0;
		end else begin
			act_we <= 1'b0;
			case (st)
				S_IDLE: begin
					if (start) begin
						cur_link   <= start_link;
						visited    <= '0;
						cnt        <= 9'd0;
						warm       <= 1'b0;
						mo_rd_addr <= {start_link, 2'd0};   // phase 0 address
						phase      <= 2'd1;
						st         <= S_WALK;
					end
				end
				S_WALK: begin
					phase <= phase + 2'd1;
					case (phase)
						// address w0 of the entry named by cur_link, and take delivery
						// of the PREVIOUS entry's w2 -- which is its link, so the chain
						// step and this address are the same decision.
						2'd0: begin
							visited[cur_link] <= 1'b1;
							// terminate on revisit; (next==cur) covers the bit just set
							// above, not yet visible through the non-blocking update.
							if (visited[next_link] || (next_link == cur_link) || (cnt == 9'd255)) begin
								st <= S_TAIL;               // let w3 land, store, stop
							end else begin
								cur_link   <= next_link;
								mo_rd_addr <= {next_link, 2'd0};
							end
						end
						2'd1: begin
							mo_rd_addr <= {cur_link, 2'd1};
							if (warm) begin                 // previous entry complete
								act_wr_addr <= cnt[7:0];
								act_wr_data <= entry;
								act_we      <= 1'b1;
								cnt         <= cnt + 9'd1;
							end
						end
						2'd2: begin mo_rd_addr <= {cur_link, 2'd2}; w0 <= mo_rd_q; end
						2'd3: begin mo_rd_addr <= {cur_link, 2'd3}; w1 <= mo_rd_q; warm <= 1'b1; end
					endcase
				end
				// last entry: its w3 is still in flight; take it, store, and finish.
				S_TAIL: begin
					act_wr_addr <= cnt[7:0];
					act_wr_data <= entry;
					act_we      <= 1'b1;
					cnt         <= cnt + 9'd1;
					st          <= S_IDLE;
				end
				default: st <= S_IDLE;
			endcase
		end
	end

endmodule
