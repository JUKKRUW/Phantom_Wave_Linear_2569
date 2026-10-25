library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Diagnostic lossless stream: index, high24, middle24, low16 as ASCII hex.
-- Each line: IIIIII HHHHHH MMMMMM LLLLLL\r\n (29 bytes).
-- Index 0..191 = direction score; F0..F7 = microphone AC power.
-- Not the final inter-FPGA transport or 16-bit heatmap scaling.
entity score_uart_stream is
    generic (CLK_HZ : positive := 50_000_000; BAUD : positive := 2000000);
    port (clk, rst, score_valid : in std_logic;
          score_ready : out std_logic;
          score_index : in unsigned(7 downto 0);
          score_data : in unsigned(63 downto 0);
          txd : out std_logic);
end entity;
architecture rtl of score_uart_stream is
    type state_type is (idle, launch, wait_done);
    signal state : state_type := idle;
    signal word_index : natural range 0 to 3 := 0;
    signal saved_index : unsigned(7 downto 0);
    signal saved_score : unsigned(63 downto 0);
    signal word_data : std_logic_vector(23 downto 0);
    signal last_word, tx_start, tx_done : std_logic;
begin
    score_ready <= '1' when state = idle else '0';
    tx_start <= '1' when state = launch else '0';
    last_word <= '1' when word_index = 3 else '0';
    with word_index select word_data <=
        x"0000" & std_logic_vector(saved_index) when 0,
        std_logic_vector(saved_score(63 downto 40)) when 1,
        std_logic_vector(saved_score(39 downto 16)) when 2,
        x"00" & std_logic_vector(saved_score(15 downto 0)) when others;
    transmitter : entity work.UART_HEX_TX
        generic map(CLK_HZ, BAUD)
        port map(clk, rst, word_data, last_word, tx_start, txd, open, tx_done);
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then state <= idle; word_index <= 0;
            else
                case state is
                    when idle =>
                        if score_valid = '1' then
                            saved_index <= score_index;
                            saved_score <= score_data;
                            word_index <= 0;
                            state <= launch;
                        end if;
                    when launch => state <= wait_done;
                    when wait_done =>
                        if tx_done = '1' then
                            if word_index = 3 then state <= idle;
                            else word_index <= word_index + 1; state <= launch; end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
