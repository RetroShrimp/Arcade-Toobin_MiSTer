# Toobin' for MiSTer FPGA

A hardware recreation of the 1988 Atari Games arcade title **Toobin'**, implemented
as an FPGA core for the [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer/wiki)
platform.

This is not a software port. The core reconstructs the original PCB — a 68010 main
board plus an Atari JSA I sound board — from Atari's SP-320 schematic package, with
MAME used as a functional oracle where the schematics are silent. Where a schematic
and MAME disagree, the schematic wins and the disagreement is recorded — see
[Where this core differs from MAME](#where-this-core-differs-from-mame).

Toobin' is its own platform, not Atari System 1 or System 2 (MAME driver
`toobin.cpp`); only the video sync chain resembles System 2.

## Supported ROM sets

Six MAME sets run on identical RTL — they differ only in the main CPU ROMs.

| MRA | MAME set | Region |
| --- | --- | --- |
| `Toobin.mra` | `toobin` | World, rev 3 |
| `_alternatives/_Toobin/Toobin' (rev 2).mra` | `toobin2` | World, rev 2 |
| `_alternatives/_Toobin/Toobin' (rev 1).mra` | `toobin1` | World, rev 1 |
| `_alternatives/_Toobin/Toobin' (Europe, rev 3).mra` | `toobine` | Europe |
| `_alternatives/_Toobin/Toobin' (Europe, rev 2).mra` | `toobin2e` | Europe |
| `_alternatives/_Toobin/Toobin' (German, rev 3).mra` | `toobing` | Germany |

## Requirements

| Item | Requirement |
| --- | --- |
| Board | DE10-Nano (Cyclone V `5CSEBA6U23I7`) |
| SDRAM | **Required** — a standard 32 MB module or larger |
| Display | Portrait ROT270 cabinet; rotated into the framebuffer by default, so a normal landscape monitor works |
| ROMs | Supplied by you from a MAME archive; none are included here |

**The SDRAM module is not optional.** All ROM data is streamed from it at runtime —
512 KB of 68010 program, 512 KB of tiles and 2 MB of motion objects, 3 MB in total —
and there is no block-RAM fallback. The controller is addressed for the usual
MT48LC16M16-class part (4 banks × 13-bit row × 9-bit column), so a legacy 8 MB module
will not work even though only 3 MB of the module is used. Bandwidth matters as much
as capacity here: the tile prefetch alone issues roughly 192 reads per scanline, which
is why `clk_sys` runs at 64 MHz rather than 32.

## Installation

1. Copy `releases/Toobin_YYYYMMDD.rbf` to `_Arcade/cores/` on the SD card.
2. Copy `releases/Toobin.mra` to `_Arcade/`, and any wanted alternates from
   `releases/_alternatives/` to `_Arcade/_alternatives/`.
3. Place the matching MAME ROM archive (`toobin.zip`, etc.) in `games/mame/`.

**No ROM data is included in this repository, and none ever will be.** The MRA
builds the correct memory image from an archive you already own.

## Controls

Toobin' has no joystick. Each player gets four paddle buttons plus a Throw Can
button, which the cabinet also uses as Start — there is no separate Start button.

| Button | Function |
| --- | --- |
| A | Left paddle back |
| B | Right paddle back |
| X | Left paddle forward |
| Y | Right paddle forward |
| L | Throw Can / Start |
| R | Coin |

Both players have their own coin button; the cabinet has two chutes and the core
wires them separately.

## Options

Toobin' has **no DIP switches**. Every operator setting — difficulty, lives, coinage,
the works — lives in the on-board X2804 EEPROM and is edited from the game's own
self-test, reached with the OSD **Service** toggle. Settings and high scores persist
through MiSTer's *Save Settings* (the MRA declares a 512-byte NVRAM).

The cabinet used a portrait CRT (ROT270), so **Orientation** offers *Vert* (rotate
into the framebuffer for a normal landscape monitor), *No Rotate* (passthrough for a
physically rotated TATE monitor) and *No Rotate 180*. An **Analog alignment** page
provides CRT H-Size / H-Position and analog VGA H/V-Shift; none of it touches core
timing.

## Hardware baseline

| Block | Implementation |
| --- | --- |
| Main CPU | Motorola 68010 @ 8.000 MHz (32 MHz / 4), big-endian 16-bit |
| Protection | None — no slapstic, no banking; 512 KB program ROM mapped flat |
| Sound board | Atari JSA I: 6502 + YM2151 + POKEY @ 3.579545 MHz (TMS5220 socket empty) |
| Raster | 640 × 416 total, **512 × 384 visible**, ~60.10 Hz, 16 MHz pixel clock |
| Playfield | 128 × 64 tiles, 8 × 8, 4 bpp, 32-bit/tile, 4 priority categories |
| Alphanumerics | 64 × 48 tiles, 8 × 8, 2 bpp, drawn on top |
| Motion objects | Linked 16 × 16, 4 bpp, per-scanline SLIP lists, transparent pen 0 |
| Palette | 1024 × 16-bit, 5:5:5 RGB + intensity bit + global brightness |
| NVRAM | Atari 2804 parallel EEPROM (one-shot unlock, 10 ms busy) |
| Watchdog | LS90 decade counter clocked by /VSYNC; resets on counts 8–9 |

The whole core runs in a single 64 MHz `clk_sys` domain with clock enables, which is
how the real board works: one master crystal divided down to the 68010 and pixel
clocks. Only the SDRAM and graphics datapath run at the full rate.

Resource use on the DE10-Nano's Cyclone V (`5CSEBA6U23I7`): 18,405 / 41,910 ALMs
(44 %), 305 / 553 RAM blocks (55 %), 62 / 112 DSP blocks (55 %). Timing closes with
+1.209 ns worst-case setup slack on `clk_sys`.

## Accuracy and verification

This core was developed with AI assistance. Because that raises a fair question
about whether the result was actually checked, here is the verification record.

**Simulation suite** — 58 module testbenches (Icarus Verilog / GHDL) plus Verilator
lint, covering the address decode, bus and byte-lane behaviour, IRQ and watchdog,
EEPROM, SDRAM controller and arbitration, every video stage, and the full JSA sound
path.

**Pixel-exact compositor gate** — MAME 0.288 is instrumented to capture complete
video state (playfield, alpha, motion-object and palette RAM, plus the scroll/SLIP
registers) at chosen frames. Those states are replayed through the real core RTL and
the rendered frame is compared to MAME's own output pixel for pixel. Across attract,
self-test and gameplay captures, **10 / 10 in-scope frames are bit-identical over all
196,608 pixels.** One gameplay frame is a documented out-of-scope XFAIL for this
static gate: a mid-frame HUD write lands after MAME's first partial-update boundary,
which a static end-of-frame comparison cannot represent.

**Raster-live gate** — the write-*timing* counterpart: each captured register write is
replayed at its captured raster row while the core renders live. **4 / 4 frames exact**
on comparable rows, and it passes the frame the static gate cannot.

**Per-layer gate** — a full-frame CRC is blind to a layer that is only wrong where
another layer covers it, so each layer is also rendered alone over a whole real
captured frame against an independent reference: **7 / 7 non-trivial cases**. The gate
scores itself — a layer that happens to be empty in a capture reports `TRIVIAL`, not
`PASS`, and the run fails if nothing non-trivial was produced.

**Render-load oracle** — the motion-object budget is sized against measured game load,
not a guess: a MAME script sweeps 36,000 frames of attract and gameplay and reports
what the MO engine is actually asked for per scanline. The real worst case is a
65-entry object chain with 48 covering columns, and the engine is sized for it.

These gates have teeth: the compositor gate caught two real defects that the module
suite could not see — the palette conversion had to *truncate* rather than round, and
the motion-object line-buffer clear sweep and bank swap must run on every scanline
including vblank. Both were fixed and re-verified.

**On real hardware** (DE10-Nano): tested and confirmed working end to end — boot,
gameplay, YM2151 and POKEY audio, the self-test, coin handling, and EEPROM persistence.
There are no outstanding hardware tests.

## Where this core differs from MAME

MAME is this project's functional oracle, and every gate above measures the core
*against* it — so this is a narrow claim, not a general one. It applies where the
SP-320 schematics document something MAME's model does not, and in two of the six
cases MAME's own source flags the gap.

| Behaviour | MAME | This core |
| --- | --- | --- |
| JSA I `/MIX` low-pass bit | `atarijsa.cpp` carries `TODO: emulate the low pass filter!` — the bit does nothing | the real 2nd-order filter, component by component |
| POKEY stereo gating | `atarijsa.cpp` notes it is "currently only mono, only looking at `ym2151_ct1`" | CT1 gates the POKEY feed into the left path, CT2 into the right, independently |
| Alpha character flip | `(data >> 10) & 1` taken as the flip bit | sheet 6 routes `ANHFLIP` to **D11**; D10 reaches only the optional `ANROMA14/VPP` socket pin, which the populated 16 KiB rev-3 character ROM never decodes |
| POKEY volume DAC | linear gate weights on this path | the measured non-power-of-two weights from the Altirra Hardware Reference Manual, carried at 11 bits |
| Mid-frame register writes | re-composited at partial-update boundaries | applied on the scanline they occur — the core renders the raster live |
| JSA `/RDIO` D6 | JSA I and II comments say active low, JSA III says active high | resolved from the sheet 22 LS240 |

**The output filter is the largest of these.** Sheet 21 draws a unity-gain Sallen-Key
2nd-order low-pass around LM324 4A, and the core implements it with the values read off
the drawing at 420 dpi: two 12 kΩ series resistors, a 2.2 nF bridge capacitor, a
permanent 1.0 nF shunt, and a 2.7 nF shunt switched to ground by a 2N3904 — 8942 Hz at
Q 0.742 disengaged, 4649 Hz at Q 0.386 engaged. The drawing also marks an `OR` at the
transistor base, so the filter engages on `/MIX` bit 0 **or** the YM2151's YM0 line,
not on the LPF bit alone. POKEY's own output stage comes from the same sheet: pin 37
`AUD` is a current output feeding LM324 2B as a transimpedance stage, whose single
signal-path pole is R34 × C37 = 7.2 kHz.

**Where MAME is still the authority.** The pixel priority network is PAL 7E on sheet 16
and no fuse map for it exists, so `toobin_priority.sv` carries MAME's functional model —
with the hardware's `LBPRI1:0` bits preserved through the renderer but deliberately
unused — rather than a guessed equation. The sibling Atari System 2 schematic implements
the same factor list as a discrete 4-bit adder used as a comparator, which suggests the
real term is finer than that approximation; that is recorded, not implemented. The
analog chain beyond the poles above is left alone on the same principle: no invented IIR
is passed off as hardware accuracy.

## Known deviations and open questions

Everything below is settled as far as documents can settle it. What is left needs a
real Toobin' PCB. Each item below is already worked out to the point where someone with
a board could act on it, and a full write-up exists for each — verified pin tables,
probe lists and capture procedures. **If you have a board and are willing to run any of
these, that is the most valuable contribution this core can receive.** Open an issue and
the full recipe can be posted, tailored to the equipment you have.

### Would change behaviour

**1. Priority PAL 7E (136061-1151) — a 1024-vector truth-table capture.** The one that
matters most. The PAL on sheet 16 resolves playfield / motion-object / alpha priority
and has never been dumped, so `toobin_priority.sv` carries MAME's functional
approximation, which collapses the `LBPRI1:0` against `PFPRI1:0` comparison to
"playfield category non-zero". The sibling Atari System 2 board builds the same factor
list from a discrete 4-bit adder used as a comparator, so the real term is very likely
finer than that. The pin table is verified and each output code's *meaning* is already
known from the F153 wiring, so a capture yields a directly implementable selector
rather than an opaque table. Sweep all 1024 input vectors with `/CRAM` swept as an
input — do not tie it inactive.

**2. Raster seams — a purpose-built diagnostic ROM and a capture.** No documentary
source can answer these, because the shipping ROM never performs the qualifying
writes: a 12,000-frame trace of rev 3 saw no `D0=0` VSCROLL write at all. Two ROMs are
specified in full:

- *HSCROLL seam* — on a mid-line HSCROLL write, do the playfield and a
  relative-coordinate motion object adopt the new value on the current line, on the
  next line, at **different times from each other**, or only after a specific HBLANK
  edge? The "different times from each other" case is the one this core cannot express.
- *VSCROLL restart* — the `FF8700` D0 qualifier written during active display and at
  early, middle and late HBLANK, to pin the exact late-HBLANK visibility through the
  playfield line prefetch.

A logic analyser at 100–200 MS/s is enough for the edge ordering; a scope is needed
where the answer is a relationship to RGB and sync.

### Cosmetic or archival

**3. Video DAC — a 32-step voltage sweep per channel.** Sheet 16 shows an R/2R ladder
*and* a 74F260 five-input NOR acting as an all-bits-zero detect, both feeding the same
analog summing node — which is why colour code 0 is treated differently from every
nonzero code, and which shows the pedestal is real hardware rather than an emulator
artefact. That shape is implemented and pixel-exact. Unmeasured is the exact 8-bit
normalisation: whether the pedestal lands precisely at +38/255, and whether the ramp
slope is exactly 7 per code, depends on transistor V<sub>BE</sub>, saturation and
resistor tolerance.

**4. End-to-end audio transfer.** The `/MIX` Sallen-Key and the POKEY transimpedance
pole are derived from sheet 21's component values, but the baseline response of the
whole LM324 chain has never been measured. Nothing beyond those two poles has been
invented to fill the gap.

**5. HSYNC / VSYNC edge placement.** The counter geometry and the sheet-5 388–391 VSYNC
interval pass an exhaustive gate, but the exact edges have never been checked against a
scope on a real board.

### Needs a document, not a board

**6. JSA `/RDIO` D6.** Resolved here from sheet 22's LS240, against MAME comments that
contradict each other between JSA I/II and JSA III. The JSA I stand-alone audio PCB
(Atari A-043713) is shared with Blasteroids, Vindicators, Xybots and Skull & Crossbones,
so **SP-316**, **SP-317** and **SP-313** carry the same audio sheets — a second scan
settles it without touching hardware.

## Building

Quartus Prime **17.0.2** (Lite or Standard) — the version MiSTer standardises on.
Open `Toobin.qpf` and run a full compile; the bitstream lands in
`output_files/Toobin.rbf`. Source files are listed in `files.qip`, which Quartus reads
but cannot edit — add and remove entries by hand.

## Attribution

This core's own RTL is **GPL-2.0-or-later** (every file carries an SPDX tag). Because it
builds on GPL-3.0-or-later components, the **combined work is GPL-3.0-or-later** — which
is what `LICENSE` contains. Individual components keep their own notices, which must be
preserved:

| Component | Author | License |
| --- | --- | --- |
| MiSTer framework (`sys/`) | Alexey Melnikov (sorgelig) and contributors | GPL-2.0-or-later / GPL-3.0-or-later per file |
| TG68K (68010) | Tobias Gubener | LGPL-3.0-or-later |
| T65 (6502) | Daniel Wallner, with fixes by Mike Johnson, ehenciak and Wolfgang Scherr (OpenCores / FPGAArcade) | BSD-style |
| POKEY | Mike Johnson (FPGAArcade) | BSD-style |
| jt51 (YM2151) | Jose Tejada (jotego) | GPL-3.0-or-later |
| `analog_hsize` | Umberto Parisi (rmonic79) | GPL-3.0-or-later |

The 68010, 6502, POKEY and SDRAM building blocks were taken from the
**Arcade-Atari-system1** MiSTer core; the video-pipeline architecture and verification
methodology come from the author's Atari System 2 (Paperboy) work.

Thanks to the MAME team, whose `toobin.cpp`, `atarijsa` and `atarimo` code served as
the functional oracle throughout, and to whoever preserved the Atari SP-320 schematic
package.

Toobin' and its ROMs, artwork and manuals are © Atari Games. This project contains no
copyrighted ROM data.

Core by **RetroShrimp**.
