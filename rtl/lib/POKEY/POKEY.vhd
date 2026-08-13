--
-- Copyright (c) MikeJ - May 2004
--
-- All rights reserved
--
-- Redistribution and use in source and synthezised forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- Redistributions in synthesized form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- Neither the name of the author nor the names of other contributors may
-- be used to endorse or promote products derived from this software without
-- specific prior written permission.
--
-- THIS CODE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--
-- You are responsible for any legal issues arising from your use of this code.
--
-- The latest version of this file can be found at: www.fpgaarcade.com
--
-- Email support@fpgaarcade.com
--
-- Revision list
--
-- version 002 return 00 on allpot when fast scan completed to fix self test
-- version 001 initial release (this version should be considered Beta
--   it seems to make all the right sort of sounds however ... )
--
-- Accuracy fixes below are ported from Videodr0me's Arcade-Tempest_MiSTer
-- (rtl/pokey.vhd, GPL-2.0), which derives from this same MikeJ source:
--   - poly5 LFSR tapped poly4(2) instead of poly5(2)
--   - poly9/poly17 replaced with the hardware shift/tap structure and the real
--     first-entry seeds; MikeJ's all-zero-detect feedback frig removed
--   - channel output stage: AUDC bit 5 selects toggle vs. sample-the-poly (was
--     an unconditional toggle on the rising edge of the gated poly), and the
--     high-pass filters now tap the channel flip-flop output, not the pre-
--     flip-flop signal
-- Kept from this core: the RESET_L port (physical /REST); the Tempest entity has
-- none.
--
-- Two further fixes, prompted by Videodr0me's newer Arcade-MajorHavoc_MiSTer
-- pokey.vhd but derived here from the Altirra Hardware Reference Manual (Avery
-- Lee), whose POKEY chapter and appendix E are measurement-based:
--   - 16-bit (linked) mode: the reload is suppressed on the LOW timer, so it
--     free-runs and its channel updates every 256 ticks rather than at the
--     16-bit rate (see p_tone_generators)
--   - the volume DAC's four gates are not exactly power-of-two weighted (see
--     pokey_dac); AUDIO_OUT widened from 6 to 11 bits to carry it at the same
--     full scale
-- NOT taken from that core: its per-channel one-clock polynomial sampling skew
-- (MAME does not model it and nothing here can settle it), its STIMER reload
-- (Toobin' never writes STIMER) and its "POKEY has no reset pin" SKCTL default
-- (Toobin' wires the physical /REST).
--
library ieee;
	use ieee.std_logic_1164.all;
	use ieee.std_logic_unsigned.all;
	use ieee.numeric_std.all;

entity POKEY is
port (
	ADDR      : in  std_logic_vector(3 downto 0);
	DIN       : in  std_logic_vector(7 downto 0);
	DOUT      : out std_logic_vector(7 downto 0);
	DOUT_OE_L : out std_logic;
	RW_L      : in  std_logic;
	CS        : in  std_logic; -- used as enable
	CS_L      : in  std_logic;
	--
	AUDIO_OUT : out signed(10 downto 0);   -- 4 channels x the 0..511 volume DAC
	--
	PIN       : in  std_logic_vector(7 downto 0);
	ENA       : in  std_logic;
	RESET_L   : in  std_logic; -- physical pin 30 /REST, active low
	CLK       : in  std_logic  -- note 6 Mhz
);
end;

architecture RTL of POKEY is
	type  array_8x8   is array (0 to 7) of std_logic_vector(7 downto 0);
	type  array_4x8   is array (1 to 4) of std_logic_vector(7 downto 0);
	type  array_4x4   is array (1 to 4) of std_logic_vector(3 downto 0);
	type  array_4x9   is array (1 to 4) of std_logic_vector(8 downto 0);  -- DAC weights
	type  array_2x17  is array (1 to 2) of std_logic_vector(16 downto 0);
	type  bool_4      is array (1 to 4) of boolean;

	signal we                   : std_logic;
	signal oe                   : std_logic;
	--
	signal ena_64k_15k          : std_logic;
	signal cnt_64k              : std_logic_vector(4 downto 0) := (others => '0');
	signal ena_64k              : std_logic;
	signal cnt_15k              : std_logic_vector(6 downto 0) := (others => '0');
	signal ena_15k              : std_logic;
	--
	-- seeded with the first entries of the hardware polynomial sequences
	signal poly4                : std_logic_vector(3 downto 0) := "0001";
	signal poly5                : std_logic_vector(4 downto 0) := "00001";
	signal poly9                : std_logic_vector(8 downto 0) := "011111111";
	signal poly17               : std_logic_vector(16 downto 0) := "11111111101111111";
	signal poly_17_9            : std_logic;

	-- registers
	signal audf                 : array_4x8 := (others => (others => '0'));
	signal audc                 : array_4x8 := (others => (others => '0'));
	signal audctl               : std_logic_vector(7 downto 0) := (others => '0');
	signal stimer               : std_logic_vector(7 downto 0);
	signal skres                : std_logic_vector(7 downto 0);
	signal potgo                : std_logic;
	signal serout               : std_logic_vector(7 downto 0);
	signal irqen                : std_logic_vector(7 downto 0);
	signal skctls               : std_logic_vector(7 downto 0);
	signal reset                : std_logic;
	--
	signal kbcode               : std_logic_vector(7 downto 0);
	signal random               : std_logic_vector(7 downto 0);
	signal serin                : std_logic_vector(7 downto 0);
	signal irqst                : std_logic_vector(7 downto 0);
	signal skstat               : std_logic_vector(7 downto 0);
	--
	signal pot_fin              : std_logic;
	signal pot_cnt              : std_logic_vector(7 downto 0);
	signal pot_val              : array_8x8;
	signal pin_reg              : std_logic_vector(7 downto 0);
	signal pin_reg_gated        : std_logic_vector(7 downto 0);
	--
	signal chan_ena             : std_logic_vector(4 downto 1);
	signal tone_gen_div         : std_logic_vector(4 downto 1);
	signal tone_gen_cnt         : array_4x8 := (others => (others => '0'));
	signal tone_gen_div_mux     : std_logic_vector(4 downto 1);
	signal tone_gen_zero        : std_logic_vector(4 downto 1);
	signal tone_gen_zero_t      : array_4x8 := (others => (others => '0'));
	signal chan_done_load       : std_logic_vector(4 downto 1) := (others => '0');
	--
	signal audio_clock          : std_logic_vector(4 downto 1);
	signal audio_sample         : std_logic_vector(4 downto 1);
	signal high_pass_sample     : std_logic_vector(2 downto 1) := (others => '1');
	signal channel_output       : std_logic_vector(4 downto 1);
	signal tone_gen_final       : std_logic_vector(4 downto 1) := (others => '0');

	-- Each channel has a 4-bit DAC whose four gates are MEANT to contribute in
	-- power-of-two ratios but do not quite: the Altirra Hardware Reference Manual
	-- (Avery Lee, appendix E "Analog Audio Model") reports measured single-channel
	-- steady-state voltage drops of 0.12 / 0.26 / 0.56 / 1.12 V (+/-0.01 V) per
	-- volume bit, and notes the bit1->bit2 gap as the most pronounced and "visible
	-- in volume ramp signals".  Those four numbers are the model's LINEAR per-bit
	-- weights: it normalises the raw sum by (0.12+0.26+0.56+1.12) x 4, i.e. the
	-- per-channel DACs add linearly and the four channels then add linearly too.
	--
	-- Scaled so one channel at full volume is 511:
	--     round(511 * drop / 2.06)  ->  bit0 30, bit1 64, bit2 139, bit3 278
	-- (sums to exactly 511; each within 0.8%, well inside the +/-0.01 V the
	-- measurement is quoted to -- which is itself +/-8% on bit0.)
	--
	-- Do NOT be tempted by MAME pokey.cpp vol_init()'s 90k/26.5k/8.05k/3.4k, which
	-- implies ratios of 1:3.4:11.2:26.5 -- three times the spread Altirra measures,
	-- and irreconcilable with "power-of-two ratios, not quite matched".  MAME only
	-- uses those values for output types this driver does not select (atarijsa.cpp
	-- never calls set_output_opamp, so its Toobin' POKEY runs LEGACY_LINEAR), and
	-- its own r_off is commented as a guess.  Videodr0me's Major Havoc core
	-- quantizes that same ladder to 1/5/16/38 and inherits the same error.
	--
	-- Altirra's saturation curve is deliberately NOT modelled: it comes from
	-- POKEY's open-drain output working into a pull-up, and Toobin' instead
	-- terminates AUD in an LM324 transimpedance stage (SP-320 sheet 21; see
	-- toobin_pokey_out.sv) that holds the pin at a virtual ground, so the summing
	-- node stays linear here.
	function pokey_dac(v : std_logic_vector(3 downto 0))
		return std_logic_vector is
		variable r : std_logic_vector(8 downto 0);
	begin
		r := "000000000";
		if (v(0) = '1') then r := r + "000011110"; end if; --  30  (0.12 V)
		if (v(1) = '1') then r := r + "001000000"; end if; --  64  (0.26 V)
		if (v(2) = '1') then r := r + "010001011"; end if; -- 139  (0.56 V)
		if (v(3) = '1') then r := r + "100010110"; end if; -- 278  (1.12 V)
		return r;
	end function;
begin

	p_we : process(RW_L, CS_L, CS, ENA)
	begin
		we <= (not CS_L) and CS and (not RW_L) and ENA;
	end process;

	p_oe : process(RW_L, CS_L, CS)
	begin
		oe <= (not CS_L) and CS and RW_L;
	end process;
	DOUT_OE_L <= not oe;

	p_ipreg : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			pin_reg <= (others => '0');
		else
			pin_reg <= PIN;
		end if;
	end process;

	p_dividers : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			cnt_64k <= (others => '0');
			cnt_15k <= (others => '0');
			ena_64k <= '0';
			ena_15k <= '0';
		elsif (ENA = '1') then
			ena_64k <= '0';
			if cnt_64k = "00000" then
				cnt_64k <= "11011"; -- 28 - 1
				ena_64k <= '1';
			else
				cnt_64k <= cnt_64k - "1";
			end if;

			ena_15k <= '0';
			if cnt_15k = "0000000" then
				cnt_15k <= "1110001"; -- 114 - 1
				ena_15k <= '1';
			else
				cnt_15k <= cnt_15k - "1";
			end if;
		end if;
	end process;

	p_ena_64k_15k : process(ena_64k, ena_15k, audctl)
	begin
		if (audctl(0) = '1') then
			ena_64k_15k <= ena_15k;
		else
			ena_64k_15k <= ena_64k;
		end if;
	end process;

	p_poly : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			-- physical /REST: seed to the first entries of the hardware sequences
			poly4  <= "0001";
			poly5  <= "00001";
			poly9  <= "011111111";
			poly17 <= "11111111101111111";
		elsif (ENA = '1') then
			if (reset = '1') then -- SKCTL reset holds the polys at the seed
				poly4  <= "0001";
				poly5  <= "00001";
				poly9  <= "011111111";
				poly17 <= "11111111101111111";
			else
				poly4 <= poly4(2 downto 0) & not (poly4(3) xor poly4(2));
				poly5 <= poly5(3 downto 0) & not (poly5(4) xor poly5(2));

				poly9 <= (poly9(0) xor poly9(5)) & poly9(8 downto 1);

				poly17(16)          <= poly17(0);
				poly17(15 downto 8) <= poly17(16 downto 9);
				poly17(7)           <= poly17(8) xor poly17(13);
				poly17(6 downto 0)  <= poly17(7 downto 1);
			end if;
		end if;
	end process;

	p_random_mux : process(audctl, poly9, poly17)
	begin
		if (audctl(7) = '1') then -- 9 bit poly
			random    <= poly9(7 downto 0);
			poly_17_9 <= poly9(0);
		else
			random    <= poly17(15 downto 8);
			poly_17_9 <= poly17(0);
		end if;
	end process;

	p_wdata : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			potgo  <= '0';
			audf   <= (others => (others => '0'));
			audc   <= (others => (others => '0'));
			audctl <= (others => '0');
			stimer <= (others => '0');
			skres  <= (others => '0');
			serout <= (others => '0');
			irqen  <= (others => '0');
			skctls <= (others => '0');
		else
			potgo <= '0';
			if (we = '1') then
			case ADDR is
				when x"0" => audf(1)  <= DIN;
				when x"1" => audc(1)  <= DIN;
				when x"2" => audf(2)  <= DIN;
				when x"3" => audc(2)  <= DIN;
				when x"4" => audf(3)  <= DIN;
				when x"5" => audc(3)  <= DIN;
				when x"6" => audf(4)  <= DIN;
				when x"7" => audc(4)  <= DIN;
				when x"8" => audctl   <= DIN;
				when x"9" => stimer   <= DIN;
				when x"A" => skres    <= DIN;
				when x"B" => potgo    <= '1';
				--when x"C" =>
				when x"D" => serout   <= DIN;
				when x"E" => irqen    <= DIN;
				when x"F" => skctls   <= DIN;
				when others => null;
			end case;
			end if;
		end if;
	end process;

	p_reset : process(skctls)
	begin
		-- chip in reset if bits 1..0 of skctls are both zero
		reset <= '0';
		if (skctls(1 downto 0) = "00") then
			reset <= '1';
		end if;
	end process;

	p_rdata : process(oe, ADDR, pot_val, pin_reg_gated, kbcode, random, serin, irqst, skstat)
	begin
		DOUT <= x"00";
		if (oe = '1') then -- keep things quiet
			case ADDR IS
				when x"0" => DOUT <= pot_val(0);   -- pot 0
				when x"1" => DOUT <= pot_val(1);   -- pot 1
				when x"2" => DOUT <= pot_val(2);   -- pot 2
				when x"3" => DOUT <= pot_val(3);   -- pot 3
				when x"4" => DOUT <= pot_val(4);   -- pot 4
				when x"5" => DOUT <= pot_val(5);   -- pot 5
				when x"6" => DOUT <= pot_val(6);   -- pot 6
				when x"7" => DOUT <= pot_val(7);   -- pot 7
				when x"8" => DOUT <= pin_reg_gated;-- allpot
				when x"9" => DOUT <= kbcode;
				when x"A" => DOUT <= random;
				when x"B" => DOUT <= x"FF";
				when x"C" => DOUT <= x"FF";
				when x"D" => DOUT <= serin;
				when x"E" => DOUT <= irqst;
				when x"F" => DOUT <= skstat;
				when others => null;
			end case;
		end if;
	end process;

	-- POT ANALOGUE IN UNTESTED !!
	p_pot_cnt : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			pot_cnt <= (others => '0');
		elsif (potgo = '1') then
			pot_cnt <= x"00";
		elsif ((ena_15k = '1') or (skctls(2) = '1')) and (ENA = '1') then -- fast scan mode
			pot_cnt <= pot_cnt + "1";
		end if;
	end process;

	p_pot_comp : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') or (reset = '1') then
			pot_fin <= '1';
		else
			if (potgo = '1') then
				pot_fin <= '0';
			elsif (pot_cnt = x"E4") then -- 228
				pot_fin <= '1';
			end if;
		end if;
	end process;

	p_pot_val : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			pot_val <= (others => (others => '0'));
		else
			for i in 0 to 7 loop
				if (pot_fin = '0') and (pin_reg(i) = '0') then
					-- continue latching counter value until input reaches ViH threshold
					pot_val(i) <= pot_cnt;
				end if;
			end loop;
		end if;
	end process;

	-- dump transistors
	--PIN <= x"00" when (pot_fin = '1') else (others => 'Z');
	p_in_gate : process(pin_reg, reset, pot_fin) -- dump transistor fakeup
	begin
		pin_reg_gated <= pin_reg;
		-- I think the datasheet lies about dump transistors being disabled
		-- in fast scan mode, as the self test fails ....
		if (reset = '1') or (pot_fin = '1') then --and (skctls(2) = '0'))
			pin_reg_gated <= x"00";
		end if;
	end process;

	p_tone_cnt_ena : process(audctl, ena_64k_15k, tone_gen_div)
		variable chan_ena1, chan_ena3 : std_ulogic;
	begin

		if (audctl(6) = '1') then
			chan_ena1 := '1'; -- 1.5 MHz,
		else
			chan_ena1 := ena_64k_15k;
		end if;
		chan_ena(1) <= chan_ena1;

		if (audctl(4) = '1') then -- chan 1/2 joined
			chan_ena(2) <= chan_ena1;
		else
			chan_ena(2) <= ena_64k_15k;
		end if;

		if (audctl(5) = '1') then
			chan_ena3 := '1'; -- 1.5 MHz,
		else
			chan_ena3 := ena_64k_15k; -- 64 KHz
		end if;
		chan_ena(3) <= chan_ena3;

		if (audctl(3) = '1') then -- chan 3/4 joined
			chan_ena(4) <= chan_ena3;
		else
			chan_ena(4) <= ena_64k_15k; -- 64 KHz
		end if;
	end process;

	p_tone_generator_zero : process(tone_gen_cnt, chan_ena)
	begin
		for i in 1 to 4 loop
			if (tone_gen_cnt(i) = "00000000") and (chan_ena(i) = '1') then
				tone_gen_zero(i) <= '1';
			else
				tone_gen_zero(i) <= '0';
			end if;
		end loop;
	end process;

	p_tone_generators : process
		variable chan_load : std_logic_vector(4 downto 1);
		variable chan_dec : std_logic_vector(4 downto 1);
		-- chan_load reloads a counter; chan_pulse is the borrow that clocks the
		-- channel's output stage.  They are the same event except in 16-bit mode,
		-- where the low counter borrows on its own without reloading the pair.
		variable chan_pulse : std_logic_vector(4 downto 1);
	begin
		-- quite tricky this .. but I think it does the correct stuff
		-- bet this is not how is was done originally !
		--
		-- nasty frig to easily get exact chip behaviour in high speed mode
		-- fout = fin / 2(audf + n) when n=4 or 7 in 16 bit mode
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			tone_gen_div   <= (others => '0');
			tone_gen_cnt   <= (others => (others => '0'));
			tone_gen_zero_t <= (others => (others => '0'));
			chan_done_load <= (others => '0');
		elsif (ENA = '1') then
			tone_gen_div <= "0000";

			if (audctl(4) = '1') then -- chan 1/2 joined
				chan_load(1) := '0';
				chan_load(2) := '0';
				if (tone_gen_zero_t(1)(5) = '1') and (tone_gen_zero_t(2)(5) = '1') and (chan_done_load(1) = '0') then
					chan_load(1) := '1';
					chan_load(2) := '1';
				end if;
				chan_dec(1) := '1';
				chan_dec(2) := tone_gen_zero(1);
				-- In 16-bit mode only the HIGH counter's borrow reloads the pair;
				-- the low counter free-runs through its full 8-bit range, so its
				-- channel output is clocked by its own wrap -- every 256 clocks in
				-- steady state, independent of AUDF.  Tying it to the pair reload
				-- instead (as this source originally did) makes the low channel
				-- sound the 16-bit note in unison with the high one.  Toobin' cares:
				-- sound command 0x59 programs AUDC3=87 AUDC4=87 under AUDCTL=78, so
				-- both channels of the joined 3/4 pair are audible.
				chan_pulse(1) := tone_gen_zero_t(1)(2);
				chan_pulse(2) := chan_load(2);
			else
				chan_load(1) := tone_gen_zero_t(1)(2) and not chan_done_load(1);
				chan_load(2) := tone_gen_zero_t(2)(2) and not chan_done_load(2);

				chan_dec(1) := '1';
				chan_dec(2) := '1';
				chan_pulse(1) := chan_load(1);
				chan_pulse(2) := chan_load(2);
			end if;

			if (audctl(3) = '1') then -- chan 1/2 joined
				chan_load(3) := '0';
				chan_load(4) := '0';
				if (tone_gen_zero_t(3)(5) = '1') and (tone_gen_zero_t(4)(5) = '1') and (chan_done_load(3) = '0') then
					chan_load(3) := '1';
					chan_load(4) := '1';
				end if;
				chan_dec(3) := '1';
				chan_dec(4) := tone_gen_zero(3);
				chan_pulse(3) := tone_gen_zero_t(3)(2);   -- see the 1/2 pair above
				chan_pulse(4) := chan_load(4);
			else
				chan_load(3) := tone_gen_zero_t(3)(2) and not chan_done_load(3);
				chan_load(4) := tone_gen_zero_t(4)(2) and not chan_done_load(4);

				chan_dec(3) := '1';
				chan_dec(4) := '1';
				chan_pulse(3) := chan_load(3);
				chan_pulse(4) := chan_load(4);
			end if;

			for i in 1 to 4 loop

				if (chan_load(i) = '1') then
					chan_done_load(i) <= '1';
					tone_gen_cnt(i) <= audf(i);
				elsif (chan_dec(i) = '1') and (chan_ena(i) = '1') then
					chan_done_load(i) <= '0';
					tone_gen_cnt(i) <= tone_gen_cnt(i) - "1";
				end if;

				tone_gen_div(i) <= chan_pulse(i);
				tone_gen_zero_t(i)(7 downto 0) <= tone_gen_zero_t(i)(6 downto 0) & tone_gen_zero(i);
			end loop;

		end if;
	end process;

	p_tone_generator_mux : process(audctl, tone_gen_div)
	begin
		if (audctl(4) = '1') then -- chan 1/2 joined
			tone_gen_div_mux(1) <= tone_gen_div(1); -- do they both waggle
			tone_gen_div_mux(2) <= tone_gen_div(2); -- or do I mute chan 1?
		else
			tone_gen_div_mux(1) <= tone_gen_div(1);
			tone_gen_div_mux(2) <= tone_gen_div(2);
		end if;

		if (audctl(3) = '1') then -- chan 3/4 joined
			tone_gen_div_mux(3) <= tone_gen_div(3); -- ditto
			tone_gen_div_mux(4) <= tone_gen_div(4);
		else
			tone_gen_div_mux(3) <= tone_gen_div(3);
			tone_gen_div_mux(4) <= tone_gen_div(4);
		end if;
	end process;

	-- The tone generator gates the channel *clock*; the poly selected by AUDC bit 6
	-- supplies the *data*.  Keeping the two separate is what lets AUDC bit 5 pick
	-- between the divide-by-two flip-flop and sampling the poly (see p_audio_out).
	p_poly_gating : process(audc, poly4, poly5, poly_17_9, tone_gen_div_mux)
	begin
		for i in 1 to 4 loop
			if (audc(i)(7) = '0') then
				audio_clock(i) <= poly5(0) and tone_gen_div_mux(i);-- 5 bit poly
			else
				audio_clock(i) <= tone_gen_div_mux(i);
			end if;

			if (audc(i)(6) = '1') then
				audio_sample(i) <= poly4(0);-- 4 bit poly
			else
				audio_sample(i) <= poly_17_9;-- 17/9 bit poly
			end if;
		end loop;
	end process;

	-- Channels 3 and 4 have no high-pass, so their flip-flop is the channel output.
	-- Channels 1 and 2 keep the XOR in the path unconditionally: when the filter is
	-- disabled the chip holds the storage node at '1' rather than bypassing the
	-- gate, so those two channels run INVERTED relative to 3 and 4.  That is real
	-- silicon behaviour (Altirra HW Reference Manual; the die reconstruction's
	-- "(not I) xnor QI" reduces to the same XOR once active-low polarity is
	-- unwound), and it changes the DAC sum whenever more than one channel is
	-- audible -- so it is not a cosmetic detail.
	p_high_pass_filters : process(tone_gen_final, high_pass_sample)
	begin
		channel_output(3) <= tone_gen_final(3);
		channel_output(4) <= tone_gen_final(4);
		channel_output(1) <= tone_gen_final(1) xor high_pass_sample(1);
		channel_output(2) <= tone_gen_final(2) xor high_pass_sample(2);
	end process;

	p_audio_out : process
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			high_pass_sample <= (others => '1');
			tone_gen_final   <= (others => '0');
		elsif (ENA = '1') then
			if (reset = '1') then
				high_pass_sample <= (others => '1');
				tone_gen_final   <= (others => '0');
			else
				-- High-pass sample-and-hold taps the channel flip-flop output, and
				-- is clocked by the *divider* of channel 3 / 4 regardless of what
				-- AUDC those channels are programmed with.  Disabling the filter
				-- forces the storage node to '1' (see p_high_pass_filters).
				if (audctl(2) = '0') then
					high_pass_sample(1) <= '1';
				elsif (tone_gen_div(3) = '1') then -- chan 1 clocked by gen 3
					high_pass_sample(1) <= tone_gen_final(1);
				end if;

				if (audctl(1) = '0') then
					high_pass_sample(2) <= '1';
				elsif (tone_gen_div(4) = '1') then -- chan 2 clocked by gen 4
					high_pass_sample(2) <= tone_gen_final(2);
				end if;

				for i in 1 to 4 loop
					if (audio_clock(i) = '1') then
						if (audc(i)(5) = '1') then
							tone_gen_final(i) <= not tone_gen_final(i);
						else
							tone_gen_final(i) <= audio_sample(i);
						end if;
					end if;
				end loop;
			end if;
		end if;
	end process;

	p_op_mixer : process
		variable vol   : array_4x4;
		variable dac   : array_4x9;
		variable sum12 : std_logic_vector(9 downto 0);
		variable sum34 : std_logic_vector(9 downto 0);
		variable sum   : std_logic_vector(10 downto 0);
	begin
		wait until rising_edge(CLK);
		if (RESET_L = '0') then
			AUDIO_OUT <= (others => '0');
		elsif (ENA = '1') then
			for i in 1 to 4 loop
				if (audc(i)(4) = '1') then -- vol only
					vol(i) := audc(i)(3 downto 0);
				else
					if (channel_output(i) = '1') then
						vol(i) := audc(i)(3 downto 0);
					else
						vol(i) := "0000";
					end if;
				end if;
				dac(i) := pokey_dac(vol(i));
			end loop;

			sum12 := ('0' & dac(1)) + ('0' & dac(2));
			sum34 := ('0' & dac(3)) + ('0' & dac(4));
			sum   := ('0' & sum12 ) + ('0' & sum34 );

			if (reset = '1') then
				AUDIO_OUT <= (others=>'0');
			else
				AUDIO_OUT <= signed((not sum(sum'left)) & sum(sum'left-1 downto 0) );
			end if;
		end if;
	end process;

	-- keyboard / serial etc to do
end architecture RTL;
