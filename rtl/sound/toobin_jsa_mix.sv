// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 RetroShrimp. GPL v2 or later.
//
// Toobin' JSA-I audio mixer.  Per MAME atarijsa.cpp mix_w (/MIX 0x2A06) +
// update_all_volumes: YM2151 gain = ym_vol/7; POKEY gain = pk_vol/3. Sheet 21
// switches the mono POKEY feed into the left path with CT1 and the right path
// with CT2. TMS5220 is depopulated (bits 7:6 ignored).
//   /MIX: [7:6]=TMS vol (N/C)  [5:4]=POKEY vol (0-3)  [3:1]=YM vol (0-7)  [0]=LPF en
// The physical LS273 is cleared by /POR, so both volume fields and LPF reset to 0.
//
// Division by 7 / 3 via reciprocal-multiply (x*9363>>16 ~= /7, x*21845>>16 ~= /3).
// Select the combined volume/reciprocal coefficient before the sample multiply.
// Keeping this as one multiply per source/channel is algebraically identical to
// (sample * volume) * reciprocal, but avoids a two-DSP combinational chain on the
// real 64 MHz path. POKEY arrives already scaled/filtered (toobin_pokey_out).
// Sum saturates.

module toobin_jsa_mix
(
	input  logic        clk,
	input  logic        reset,
	input  logic        mix_wr,
	input  logic  [7:0] mix_data,
	input  logic        ym_ct1,        // YM2151 CT1: POKEY -> left gate
	input  logic        ym_ct2,        // YM2151 CT2: POKEY -> right gate
	input  logic signed [15:0] ym_left,
	input  logic signed [15:0] ym_right,
	input  logic signed [15:0] pk_audio,   // from toobin_pokey_out (filtered, DC-blocked)
	output logic signed [15:0] out_left,
	output logic signed [15:0] out_right,
	output logic               lpf_engage    // -> toobin_jsa_lpf
);

	logic [2:0] ym_vol; logic [1:0] pk_vol; logic lpf;
	always_ff @(posedge clk) begin
		if (reset) begin ym_vol <= 3'd0; pk_vol <= 2'd0; lpf <= 1'b0; end
		else if (mix_wr) begin ym_vol <= mix_data[3:1]; pk_vol <= mix_data[5:4]; lpf <= mix_data[0]; end
	end
	wire unused = &{1'b0, mix_data[7:6]};   // TMS vol (depopulated) unused

	// Sheet 21 drives the Q5/Q6 filter switch from R58 (LPF) *and* R57 (YM0) into
	// the same base, drawn with "OR" between them -- so the output low-pass
	// engages on either bit, not on LPF alone.
	assign lpf_engage = lpf | ym_vol[0];

	// Precomputed volume*reciprocal coefficients prevent Quartus from building
	// cascaded sample*volume and *reciprocal multipliers.  The maximum YM
	// coefficient is 7*9363=65541; POKEY is 3*21845=65535.
	logic signed [17:0] ym_gain;
	logic signed [17:0] pk_gain;
	always_comb begin
		case (ym_vol)
			3'd0: ym_gain = 18'sd0;
			3'd1: ym_gain = 18'sd9363;
			3'd2: ym_gain = 18'sd18726;
			3'd3: ym_gain = 18'sd28089;
			3'd4: ym_gain = 18'sd37452;
			3'd5: ym_gain = 18'sd46815;
			3'd6: ym_gain = 18'sd56178;
			default: ym_gain = 18'sd65541;
		endcase
		case (pk_vol)
			2'd0: pk_gain = 18'sd0;
			2'd1: pk_gain = 18'sd21845;
			2'd2: pk_gain = 18'sd43690;
			default: pk_gain = 18'sd65535;
		endcase
	end

	// YM channel: signed sample * precombined vol(0-7)/7 coefficient.
	wire signed [33:0] ym_l_m = $signed(ym_left)  * $signed(ym_gain);
	wire signed [33:0] ym_r_m = $signed(ym_right) * $signed(ym_gain);
	wire signed [17:0] ym_l_s = 18'(ym_l_m >>> 16);
	wire signed [17:0] ym_r_s = 18'(ym_r_m >>> 16);

	// POKEY channel: * vol(0-3) * (1/3), independently gated into the left/right
	// analog paths by CT1/CT2.  The DAC's 6->16 bit scaling, the 7.2 kHz
	// transimpedance pole and the C47 DC block all happen upstream in
	// toobin_pokey_out, which is what keeps these gates from switching POKEY's
	// -16384 silence offset in and out of the sum.
	wire signed [15:0] pk_ext = pk_audio;
	wire signed [33:0] pk_l_m = ym_ct1 ? ($signed(pk_ext) * $signed(pk_gain))
	                                    : 34'sd0;
	wire signed [33:0] pk_r_m = ym_ct2 ? ($signed(pk_ext) * $signed(pk_gain))
	                                    : 34'sd0;
	wire signed [17:0] pk_l_s = 18'(pk_l_m >>> 16);
	wire signed [17:0] pk_r_s = 18'(pk_r_m >>> 16);

	// sum + saturate to 16-bit signed
	wire signed [18:0] sum_l = {ym_l_s[17], ym_l_s} + {pk_l_s[17], pk_l_s};
	wire signed [18:0] sum_r = {ym_r_s[17], ym_r_s} + {pk_r_s[17], pk_r_s};
	function automatic signed [15:0] sat16(input signed [18:0] v);
		if      (v >  19'sd32767)  sat16 =  16'sd32767;
		else if (v < -19'sd32768)  sat16 =  16'sh8000;   // -32768 (min 16-bit signed)
		else                       sat16 = v[15:0];
	endfunction

	always_ff @(posedge clk) begin
		out_left  <= sat16(sum_l);
		out_right <= sat16(sum_r);
	end

endmodule
