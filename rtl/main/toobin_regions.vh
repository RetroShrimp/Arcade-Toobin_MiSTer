// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' main-bus region codes (shared by the decoder and the bus).
// Order matches the MAME toobin.cpp main_map install order; the numeric value
// doubles as the install priority (higher = installed later = wins on overlap).
// No include guard: these are module-scoped localparams, so each module that
// includes this file gets its own copy (include exactly once per module).

localparam [4:0]
	REG_NONE    = 5'd0,
	REG_ROM     = 5'd1,   // 0x000000-0x07FFFF  R    512 KB program ROM
	REG_PF      = 5'd2,   // 0xC00000-0xC07FFF  R/W  playfield RAM (32-bit tiles)
	REG_ALPHA   = 5'd3,   // 0xC08000-0xC097FF  R/W  alpha RAM  (mirror 0x046000)
	REG_MOB     = 5'd4,   // 0xC09800-0xC09FFF  R/W  motion-object RAM (mirror 0x046000)
	REG_PAL     = 5'd5,   // 0xC10000-0xC107FF  R/W  color/palette RAM (mirror 0x047800)
	REG_NOPR    = 5'd6,   // 0x826000           R    unknown ("read at controls time")
	REG_WD      = 5'd7,   // 0x828000           W    watchdog clear
	REG_SNDCMD  = 5'd8,   // 0x828101           W    main->sound command
	REG_INTENS  = 5'd9,   // 0x828300           W    overall intensity (brightness)
	REG_IRQSCAN = 5'd10,  // 0x828340           W    scanline IRQ compare
	REG_SLIP    = 5'd11,  // 0x828380           W    motion-object SLIP RAM
	REG_IRQACK  = 5'd12,  // 0x8283C0           W    scanline IRQ acknowledge
	REG_SNDRST  = 5'd13,  // 0x828400           W    sound CPU reset
	REG_EEUNLK  = 5'd14,  // 0x828500           W    EEPROM unlock strobe
	REG_HSCRL   = 5'd15,  // 0x828600           W    HSCROLL
	REG_VSCRL   = 5'd16,  // 0x828700           W    VSCROLL (+ counter restart)
	REG_SW      = 5'd17,  // 0x828800           R    SWITCHES (paddles + throws)
	REG_INP     = 5'd18,  // 0x829000           R    INPUTS (hblank/vblank/comm/self-test)
	REG_SNDRESP = 5'd19,  // 0x829801           R    sound->main response
	REG_EEPROM  = 5'd20,  // 0x82A000-0x82A3FF  R/W  2804 EEPROM (byte lane)
	REG_WRAM    = 5'd21;  // 0x82C000-0x82FFFF  R/W  16 KB work RAM
