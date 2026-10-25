-- AC power for each microphone from the SAME locked 128-sample snapshot.
-- power = floor((128*sum(x*x) - sum(x)**2) / 128**2).
-- UART stream indices F0..F7 carry this power, not direction scores.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity mic_level_scan is
    port (clk, rst, start : in std_logic;
          done : out std_logic;
          rd_en : out std_logic;
          rd_addr : out unsigned(9 downto 0);
          rd_valid : in std_logic;
          rd_data : in signed(23 downto 0);
          level_valid : out std_logic;
          level_ready : in std_logic;
          level_index : out unsigned(7 downto 0);
          level_power : out unsigned(63 downto 0));
end entity;
architecture rtl of mic_level_scan is
    type state_type is (idle, request_sample, wait_sample, square_sample,
                        accumulate, variance, emit);
    signal state : state_type := idle;
    signal microphone : natural range 0 to 7 := 0;
    signal sample_index : natural range 0 to 127 := 0;
    signal sample_value : signed(23 downto 0);
    signal squared_value : signed(47 downto 0);
    signal total : signed(30 downto 0) := (others => '0');
    signal energy : unsigned(63 downto 0) := (others => '0');
begin
    rd_en <= '1' when state = request_sample else '0';
    rd_addr <= to_unsigned(sample_index*8+microphone,10);
    level_valid <= '1' when state = emit else '0';
    level_index <= to_unsigned(240+microphone,8);
    process(clk)
        variable total_squared : signed(61 downto 0);
    begin
        if rising_edge(clk) then
            done <= '0';
            if rst = '1' then
                state <= idle;
                microphone <= 0;
                sample_index <= 0;
                total <= (others => '0');
                energy <= (others => '0');
                level_power <= (others => '0');
            else
                case state is
                    when idle =>
                        if start = '1' then
                            microphone <= 0;
                            sample_index <= 0;
                            total <= (others => '0');
                            energy <= (others => '0');
                            state <= request_sample;
                        end if;
                    when request_sample => state <= wait_sample;
                    when wait_sample =>
                        if rd_valid = '1' then sample_value <= rd_data; state <= square_sample; end if;
                    when square_sample =>
                        squared_value <= sample_value*sample_value;
                        state <= accumulate;
                    when accumulate =>
                        total <= total+resize(sample_value,31);
                        energy <= energy+resize(unsigned(squared_value),64);
                        if sample_index = 127 then state <= variance;
                        else sample_index <= sample_index+1; state <= request_sample; end if;
                    when variance =>
                        total_squared := total*total;
                        level_power <= shift_right(shift_left(energy,7)-resize(unsigned(total_squared),64),14);
                        state <= emit;
                    when emit =>
                        if level_ready = '1' then
                            if microphone = 7 then state <= idle; done <= '1';
                            else
                                microphone <= microphone+1;
                                sample_index <= 0;
                                total <= (others => '0');
                                energy <= (others => '0');
                                state <= request_sample;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
