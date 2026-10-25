library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- One direction, eight signed 24-bit microphones, 64 output samples.
-- Memory is an external, immutable snapshot of 128 x 8 samples.
-- All ports use clk. Only one read request is outstanding at a time.
entity das_direction_score is
    port (
        clk : in std_logic;
        rst : in std_logic;
        start : in std_logic;
        -- Mic m: bits m*5+4:m*5, integer delay 0..20.
        delay_integer_flat : in std_logic_vector(39 downto 0);
        -- Mic m: bits m*8+7:m*8, fractional delay / 256.
        delay_fraction_flat : in std_logic_vector(63 downto 0);
        busy : out std_logic;
        done : out std_logic;
        score : out unsigned(63 downto 0);
        -- Every cycle with rd_en=1 must be accepted by the memory adapter.
        -- Address = time_index*8 + mic_index; response may have variable latency.
        rd_en : out std_logic;
        rd_addr : out unsigned(9 downto 0);
        rd_valid : in std_logic;
        rd_data : in signed(23 downto 0)
    );
end entity;

architecture rtl of das_direction_score is
    type state_type is (idle, request_first, wait_first, request_second,
                        wait_second, interpolate, add_microphone, square_sample,
                        accumulate_energy, finish);
    signal state : state_type := idle;
    signal delays : std_logic_vector(39 downto 0);
    signal fractions : std_logic_vector(63 downto 0);
    signal sample_index : integer range 64 to 127 := 64;
    signal mic_index : integer range 0 to 7 := 0;
    signal first_value, second_value : signed(23 downto 0);
    signal interpolated_value : signed(23 downto 0);
    signal microphone_sum : signed(26 downto 0) := (others => '0');
    signal squared_value : signed(47 downto 0);
    signal energy_sum : unsigned(63 downto 0) := (others => '0');
begin
    busy <= '0' when state = idle else '1';
    rd_en <= '1' when state = request_first or state = request_second else '0';

    address_decode : process(state, sample_index, mic_index, delays)
        variable time_index : integer;
    begin
        rd_addr <= (others => '0');
        if state = request_first or state = request_second then
            time_index := sample_index - to_integer(unsigned(
                delays(mic_index*5+4 downto mic_index*5)));
            if state = request_second then
                time_index := time_index - 1;
            end if;
            rd_addr <= to_unsigned(time_index*8 + mic_index, rd_addr'length);
        end if;
    end process;

    calculation : process(clk)
        variable difference : signed(24 downto 0);
        variable fraction : signed(8 downto 0);
        variable product : signed(33 downto 0);
        variable interpolated_wide : signed(24 downto 0);
        variable average_value : signed(23 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= idle;
                done <= '0';
                score <= (others => '0');
                microphone_sum <= (others => '0');
                energy_sum <= (others => '0');
                sample_index <= 64;
                mic_index <= 0;
            else
                done <= '0';
                case state is
                    when idle =>
                        if start = '1' then
                            for m in 0 to 7 loop
                                assert unsigned(delay_integer_flat(m*5+4 downto m*5)) <= 20
                                    report "Integer delay must be 0..20" severity failure;
                            end loop;
                            delays <= delay_integer_flat;
                            fractions <= delay_fraction_flat;
                            sample_index <= 64;
                            mic_index <= 0;
                            microphone_sum <= (others => '0');
                            energy_sum <= (others => '0');
                            state <= request_first;
                        end if;
                    when request_first => state <= wait_first;
                    when wait_first =>
                        if rd_valid = '1' then
                            first_value <= rd_data;
                            state <= request_second;
                        end if;
                    when request_second => state <= wait_second;
                    when wait_second =>
                        if rd_valid = '1' then
                            second_value <= rd_data;
                            state <= interpolate;
                        end if;
                    when interpolate =>
                        -- x0 + floor((x1-x0)*fraction/256).
                        -- Widen before subtraction: full-scale difference needs 25 bits.
                        difference := resize(second_value, 25) - resize(first_value, 25);
                        fraction := signed('0' & fractions(mic_index*8+7 downto mic_index*8));
                        product := difference * fraction;
                        interpolated_wide := resize(first_value, 25) +
                            resize(shift_right(product, 8), 25);
                        interpolated_value <= resize(interpolated_wide, 24);
                        state <= add_microphone;
                    when add_microphone =>
                        microphone_sum <= microphone_sum + resize(interpolated_value, 27);
                        if mic_index = 7 then
                            state <= square_sample;
                        else
                            mic_index <= mic_index + 1;
                            state <= request_first;
                        end if;
                    when square_sample =>
                        -- Arithmetic shift rounds negative values toward minus infinity.
                        average_value := resize(shift_right(microphone_sum, 3), 24);
                        squared_value <= average_value * average_value;
                        state <= accumulate_energy;
                    when accumulate_energy =>
                        energy_sum <= energy_sum + resize(unsigned(squared_value), 64);
                        if sample_index = 127 then
                            state <= finish;
                        else
                            sample_index <= sample_index + 1;
                            mic_index <= 0;
                            microphone_sum <= (others => '0');
                            state <= request_first;
                        end if;
                    when finish =>
                        score <= shift_right(energy_sum, 6);
                        done <= '1';
                        state <= idle;
                end case;
            end if;
        end if;
    end process;
end architecture;
