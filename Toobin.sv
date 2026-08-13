// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
//============================================================================
//
//  Toobin' (Atari Games, 1988) MiSTer FPGA core — top-level glue (emu).
//
//  Wires toobin_core (68010 + JSA sound + SDRAM datapath + ce_pix video) to the
//  MiSTer framework: PLL clocks, hps_io (ROM download + controls), arcade_video
//  + screen_rotate (ROT270 vertical monitor), audio, and the SDRAM chip pins.
//  See rtl/toobin_core.sv.
//
//  Single clk_sys domain + clock enables (the accurate model — the real main
//  board derives 68010/8 MHz and pixel/16 MHz from one master by division).
//
//  The PLL outputs clk_sys = 64 MHz (SDRAM headroom: the tile prefetch does ~192
//  SDRAM reads/line; 32 MHz is bandwidth-marginal) and clk_sdram = 64 MHz phase-
//  shifted for the SDRAM_CLK pin.  The core dividers below (PIX_DIV=4 -> 16 MHz
//  pixel, CPU_DIV=8 -> 8 MHz CPU) and SDRAM_CLK_MHZ=64 assume that; regenerate
//  pll.qip if you change them.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
//  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT= 0;

assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Toobin' runs on a VERTICAL monitor (ROT270).  screen_rotate handles the display
// rotation via the DDR framebuffer.  The advertised "Original" aspect has to follow
// the Orientation option: rotated presents a 3:4 portrait frame, but the passthrough
// states present the native 4:3 landscape raster, and advertising 3:4 for those would
// squash it.  See the orientation block further down for the state encoding.
// VIDEO_ARX/ARY are driven by video_freak (down in the video section) so the
// Scale option can force integer scaling; these are the requested ratios it
// starts from.
wire [1:0] ar = status[122:121];
wire       ar_rotated = (status[5:4] == 2'd0) & ~direct_video;
wire [11:0] arx = (!ar) ? (ar_rotated ? 12'd3 : 12'd4) : 12'(ar - 1'd1);
wire [11:0] ary = (!ar) ? (ar_rotated ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Toobin;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:4],Orientation,Vert,No Rotate,No Rotate 180;",
	"O[22:20],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer;",
	"-;",
	// Analog alignment.  Every field is plain two's complement, so the list is
	// 0,+1..+max then -min..-1 and the decode is a $signed() -- see
	// toobin_analog_adjust.sv.  None of these touch the core's timing.
	"P1,Analog alignment;",
	"P1-;",
	"P1O[27:23],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[34:28],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,+49,+50,+51,+52,+53,+54,+55,+56,+57,+58,+59,+60,+61,+62,+63,-64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[40:35],Analog VGA H-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[46:41],Analog VGA V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	// No DIP page: Toobin' has no dip switches.  MAME's INPUT_PORTS_START(toobin) has only
	// the FF8800 controls and the FF9000 service/status word; every operator setting lives
	// in the X2804 EEPROM and is changed from the game's own self-test.  A "DIP;" line here
	// would ask MiSTer Main to splice in a menu the MRA can never populate.
	"O[6],Service,Off,On;",
	"-;",
	"T[0],Reset;",
	"J1,Left Back,Right Back,Left Forward,Right Forward,Throw Can/Start,Coin;",
	"jn,A,B,X,Y,L,R;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire        direct_video;
wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
wire        ioctl_upload, ioctl_upload_req;
wire  [7:0] ioctl_upload_index, ioctl_din;

wire [31:0] joystick_0, joystick_1;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	.status_menumask(1'b0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index),
	.ioctl_din(ioctl_din),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;               // 64 MHz game clock (see PLL note above)
wire clk_sdram;             // 64 MHz phase-shifted for the SDRAM_CLK pin
wire clk_20_unused;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),
	.outclk_1(clk_20_unused),
	.outclk_2(clk_sdram),
	.locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

///////////////////////   CONTROLS   /////////////////////////////

// Five direct cabinet buttons per player. Throw Can is also the game's Start:
// [4]=Left Back [5]=Right Back [6]=Left Forward [7]=Right Forward
// [8]=Throw Can/Start [9]=Coin.  D-pad bits [3:0] are intentionally unused.
wire [15:0] sw_ff8800;
toobin_inputs u_inputs (
	.p1_l_back(joystick_0[4]), .p1_r_back(joystick_0[5]),
	.p1_l_fwd(joystick_0[6]),  .p1_r_fwd(joystick_0[7]),
	.p1_throw_start(joystick_0[8]),
	.p2_l_back(joystick_1[4]), .p2_r_back(joystick_1[5]),
	.p2_l_fwd(joystick_1[6]),  .p2_r_fwd(joystick_1[7]),
	.p2_throw_start(joystick_1[8]),
	.switches(sw_ff8800) );

// Separate coin chutes: the cabinet has two, entering on the JSA's
// /RDIO D1:D0 -- player 1's Coin button = chute 1, player 2's = chute 2.
wire coin1     = joystick_0[9];
wire coin2     = joystick_1[9];
wire self_test = status[6];

///////////////////////   CORE   /////////////////////////////////

wire        ce_pix;
wire  [7:0] core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb;
wire signed [15:0] aud_l, aud_r;

toobin_core #(.SDRAM_CLK_MHZ(64), .PIX_DIV(4), .CPU_DIV(8)) u_core
(
	.clk_sys(clk_sys), .reset(reset), .init_reset(~pll_locked),

	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload), .ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din),

	.sw_ff8800(sw_ff8800), .self_test(self_test), .coin1(coin1), .coin2(coin2),

	.ce_pix(ce_pix), .vga_r(core_r), .vga_g(core_g), .vga_b(core_b),
	.hsync(core_hs), .vsync(core_vs), .hblank(core_hb), .vblank(core_vb),

	.aud_l(aud_l), .aud_r(aud_r),

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CLK(), .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE)
);

// SDRAM clock pin from the phase-shifted PLL output (not the controller's ~clk)
assign SDRAM_CLK = clk_sdram;

///////////////////////   AUDIO   ////////////////////////////////

assign AUDIO_S = 1'b1;              // signed samples
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

///////////////////////   VIDEO   ////////////////////////////////

wire [7:0] R, G, B;
wire       HSync, VSync, HBlank, VBlank;
assign R = core_r;
assign G = core_g;
assign B = core_b;
assign HSync  = core_hs;
assign VSync  = core_vs;
assign HBlank = core_hb;
assign VBlank = core_vb;

// The cabinet raster is always ROT270 and the release core presents its native
// pixels without an OSD-selectable scaler effect. MiSTer's forced scandoubler
// signal remains framework-controlled for displays that require it.
wire [2:0] fx = 3'b000;

// Orientation (status[5:4]).  screen_rotate exposes exactly THREE usable states, not
// four: it derives `do_flip = no_rotate && flip` and `fb_en = ~no_rotate | flip`
// (sys/arcade_video.v:233,288), so rotating and flipping are mutually exclusive --
// `flip` means "180 degrees INSTEAD of rotating" and is dead while the core rotates.
// (An earlier "Vert/Flip" option drove `flip` with `no_rotate` tied to 0, so it was
// ANDed with a constant zero and could never do anything.)
//   0 Vert         : rotate CCW into the DDR framebuffer -- a normal horizontal monitor
//   1 No Rotate    : straight passthrough  -- a physically rotated (TATE) monitor
//   2 No Rotate 180: passthrough flipped 180 -- monitor rotated the other way
// direct_video bypasses the scaler/framebuffer entirely, so it forces the passthrough
// state; this is the standard MiSTer arcade idiom (`no_rotate = <opt> | direct_video`).
wire [1:0] orient     = status[5:4];
wire       no_rotate  = (orient != 2'd0) | direct_video;
wire       rotate_ccw = 1'b1;                       // ROT270
wire       flip       = (orient == 2'd2) & ~direct_video;
wire       video_rotated;

assign CLK_VIDEO = clk_sys;

// Analog alignment (CRT H-Size / H-Position, VGA H-Shift / V-Shift).  Placed
// ahead of arcade_video so the mixer, scandoubler and video_freak all see the
// adjusted raster; the core's own timing is untouched.  With H-Size active the
// pixel rate is no longer ce_pix, which is why arcade_video is clocked from
// adj_ce rather than ce_pix.
wire [7:0] adj_r, adj_g, adj_b;
wire       adj_hs, adj_vs, adj_hb, adj_vb, adj_ce;

toobin_analog_adjust #(.H_TOTAL(640), .V_TOTAL(416), .CLK_PER_PIX(4)) u_analog_adjust
(
	.clk        (clk_sys),
	.ce_pix     (ce_pix),
	.osd_hsize  (status[27:23]),
	.osd_hpos   (status[34:28]),
	.osd_hshift (status[40:35]),
	.osd_vshift (status[46:41]),
	.r_in (R), .g_in (G), .b_in (B),
	.hs_in(HSync), .vs_in(VSync), .hb_in(HBlank), .vb_in(VBlank),
	.r_out(adj_r), .g_out(adj_g), .b_out(adj_b),
	.hs_out(adj_hs), .vs_out(adj_vs), .hb_out(adj_hb), .vb_out(adj_vb),
	.ce_out(adj_ce)
);

wire vga_de_raw;

arcade_video #(.WIDTH(512), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(adj_ce),
	.RGB_in({adj_r, adj_g, adj_b}),
	.HBlank(adj_hb),
	.VBlank(adj_vb),
	.HSync(adj_hs),
	.VSync(adj_vs),
	.VGA_DE(vga_de_raw),
	.fx(fx)
);

// Scale (status[22:20]) maps onto video_freak's SCALE encoding, which is
// documented at sys/video_freak.sv:32 as
//   0 normal, 1 V-integer, 2 HV-Integer-, 3 HV-Integer+, 4 HV-Integer.
// "Narrower HV-Integer" is therefore 2, and plain "HV-Integer" is 4 -- they are
// not adjacent, so the menu order and the encoding deliberately differ.
wire [2:0] scale_sel = (status[22:20] == 3'd0) ? 3'd0 :   // Normal
                       (status[22:20] == 3'd1) ? 3'd1 :   // V-Integer
                       (status[22:20] == 3'd2) ? 3'd4 :   // HV-Integer
                                                 3'd2;    // Narrower HV-Integer

video_freak video_freak
(
	.CLK_VIDEO  (CLK_VIDEO),
	.CE_PIXEL   (CE_PIXEL),
	.VGA_VS     (VGA_VS),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE     (VGA_DE),
	.VIDEO_ARX  (VIDEO_ARX),
	.VIDEO_ARY  (VIDEO_ARY),
	.VGA_DE_IN  (vga_de_raw),
	.ARX        (arx),
	.ARY        (ary),
	.CROP_SIZE  (12'd0),
	.CROP_OFF   (5'd0),
	.SCALE      (scale_sel)
);

screen_rotate screen_rotate (.*);

///////////////////////   STATUS LED   ///////////////////////////

assign LED_USER = ioctl_download;

endmodule
