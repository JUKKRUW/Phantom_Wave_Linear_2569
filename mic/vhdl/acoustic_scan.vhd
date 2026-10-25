library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.acoustic_delay_pkg.all;

-- Output stream is 192 ordered raw 64-bit scores, with backpressure.
-- Keep the snapshot locked until scan_done, including output stalls.
entity acoustic_scan is
    port (
        clk, rst, start : in std_logic;
        busy, scan_done : out std_logic;
        rd_en : out std_logic;
        rd_addr : out unsigned(9 downto 0);
        rd_valid : in std_logic;
        rd_data : in signed(23 downto 0);
        score_valid : out std_logic;
        score_ready : in std_logic;
        score_index : out unsigned(7 downto 0);
        score_data : out unsigned(63 downto 0)
    );
end entity;

architecture rtl of acoustic_scan is
    type state_type is (idle, load_request, load_capture, launch, wait_score, emit);
    signal state : state_type := idle;
    signal direction : natural range 0 to 191 := 0;
    signal microphone : natural range 0 to 7 := 0;
    signal rom_value : unsigned(12 downto 0);
    signal integers : std_logic_vector(39 downto 0);
    signal fractions : std_logic_vector(63 downto 0);
    signal calc_start, calc_done : std_logic;
    signal calculated : unsigned(63 downto 0);
begin
    busy <= '0' when state = idle else '1';
    score_valid <= '1' when state = emit else '0';
    score_index <= to_unsigned(direction, 8);
    score_data <= calculated;
    calc_start <= '1' when state = launch else '0';
    calculator : entity work.das_direction_score
        port map(clk, rst, calc_start, integers, fractions, open, calc_done,
                 calculated, rd_en, rd_addr, rd_valid, rd_data);
    control : process(clk)
    begin
        if rising_edge(clk) then
            scan_done <= '0';
            if rst = '1' then
                state <= idle;
                direction <= 0;
                microphone <= 0;
            else
                case state is
                    when idle =>
                        if start = '1' then
                            direction <= 0;
                            microphone <= 0;
                            state <= load_request;
                        end if;
                    when load_request =>
                        rom_value <= DELAY_ROM(direction*8 + microphone);
                        state <= load_capture;
                    when load_capture =>
                        integers(microphone*5+4 downto microphone*5) <= std_logic_vector(rom_value(12 downto 8));
                        fractions(microphone*8+7 downto microphone*8) <= std_logic_vector(rom_value(7 downto 0));
                        if microphone = 7 then state <= launch;
                        else microphone <= microphone + 1; state <= load_request; end if;
                    when launch => state <= wait_score;
                    when wait_score => if calc_done = '1' then state <= emit; end if;
                    when emit =>
                        if score_ready = '1' then
                            if direction = 191 then state <= idle; scan_done <= '1';
                            else
                                direction <= direction + 1;
                                microphone <= 0;
                                state <= load_request;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
