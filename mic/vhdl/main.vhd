library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.inmp441_pkg.all;
use work.acoustic_delay_pkg.all;

-- Microphone-board top only; do not compile Wproject/main.vhd in this project.
entity main is
    port (
        clk : in std_logic;
        inmp441_clk, inmp441_ws : out std_logic;
        inmp441_data : in std_logic_vector(7 downto 0);
        usb_uart_txd : out std_logic;
        usb_uart_rxd : in std_logic
    );
end entity;
architecture rtl of main is
    signal startup : unsigned(5 downto 0) := (others => '0');
    signal rst : std_logic := '1';
    signal samples : TYPE_DATA_24BIT_ARRAY;
    signal samples_flat : std_logic_vector(191 downto 0);
    signal frame_valid, score_valid, score_ready : std_logic;
    signal score_index : unsigned(7 downto 0);
    signal score_data : unsigned(63 downto 0);
begin
    -- Deterministic FPGA power-up reset; UART RX is reserved, not a reset pin.
    process(clk)
    begin
        if rising_edge(clk) then
            if startup /= 63 then startup <= startup + 1; rst <= '1';
            else rst <= '0'; end if;
        end if;
    end process;
    microphone : entity work.INMP441_I2S_PARALLEL
        generic map(CLK_FREQ => 50_000_000, SAMPLE_RATE => 32_000, CHANNEL_RIGHT => false)
        port map(clk, rst, inmp441_clk, inmp441_ws, inmp441_data, samples, frame_valid);
    packing : for m in 0 to 7 generate
        samples_flat(m*24+23 downto m*24) <= samples(m);
    end generate;
    -- Core locks a snapshot, subtracts each channel's 128-sample mean,
    -- then scans all directions. Raw microphone-level diagnostics are separate.
    core : entity work.acoustic_core
        port map(clk, rst, frame_valid, samples_flat, score_valid, score_ready,
                 score_index, score_data, open, open);
    diagnostics : entity work.score_uart_stream
        generic map(CLK_HZ => 50_000_000, BAUD => 2000000)
        port map(clk, rst, score_valid, score_ready, score_index, score_data, usb_uart_txd);
end architecture;
