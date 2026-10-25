library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.inmp441_pkg.all;

entity INMP441_I2S_PARALLEL is
    generic (
        CLK_FREQ : positive := 50_000_000;
        SAMPLE_RATE : positive := 32_000;
        CHANNEL_RIGHT : boolean := false
    );
    port (
        CLK, RST : in std_logic;
        I2S_SCK, I2S_WS : out std_logic;
        I2S_SD : in std_logic_vector(7 downto 0);
        DATA_SAMPLE_OUT : out TYPE_DATA_24BIT_ARRAY;
        FLAG_DATA_VALID : out std_logic
    );
end entity;

architecture rtl of INMP441_I2S_PARALLEL is
    -- SCK toggles twice per bit. Round the HALF-period divider, not full period.
    constant HALF_DIV : positive := (CLK_FREQ + SAMPLE_RATE*64)/(2*SAMPLE_RATE*64);
    signal divider : natural range 0 to HALF_DIV-1 := 0;
    signal sck : std_logic := '0';
    signal position : natural range 0 to 63 := 0;
    signal synchronized_frame : std_logic := '0';
    signal sd_meta, sd_sync : std_logic_vector(7 downto 0) := (others => '0');
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sd_meta, sd_sync : signal is "TRUE";
    signal shift_data : TYPE_DATA_24BIT_ARRAY := (others => (others => '0'));
begin
    I2S_SCK <= sck;
    I2S_WS <= '0' when position < 32 else '1';
    process(CLK)
        variable selected_position : integer;
        variable next_word : std_logic_vector(23 downto 0);
    begin
        if rising_edge(CLK) then
            FLAG_DATA_VALID <= '0';
            sd_meta <= I2S_SD;
            sd_sync <= sd_meta;
            if RST = '1' then
                divider <= 0;
                sck <= '0';
                position <= 0;
                synchronized_frame <= '0';
                shift_data <= (others => (others => '0'));
                DATA_SAMPLE_OUT <= (others => (others => '0'));
            elsif divider = HALF_DIV-1 then
                divider <= 0;
                sck <= not sck;
                if sck = '1' then
                    if position = 63 then
                        position <= 0;
                        synchronized_frame <= '1';
                    else position <= position + 1; end if;
                else
                    selected_position := position;
                    if CHANNEL_RIGHT then selected_position := position - 32; end if;
                    -- Standard I2S: slot bit 0 is the one-bit delay after WS;
                    -- bits 1..24 are MSB..LSB. Never include slot padding.
                    if synchronized_frame = '1' and selected_position >= 1 and selected_position <= 24 then
                        for m in 0 to 7 loop
                            next_word := shift_data(m)(22 downto 0) & sd_sync(m);
                            shift_data(m) <= next_word;
                            if selected_position = 24 then DATA_SAMPLE_OUT(m) <= next_word; end if;
                        end loop;
                        if selected_position = 24 then FLAG_DATA_VALID <= '1'; end if;
                    end if;
                end if;
            else divider <= divider + 1;
            end if;
        end if;
    end process;
    assert HALF_DIV >= 4 report "System clock too slow for synchronized I2S input" severity failure;
    assert CLK_FREQ/(2*HALF_DIV*64) >= 7800 and CLK_FREQ/(2*HALF_DIV*64) <= 50000
        report "Actual sample rate outside INMP441 supported range" severity failure;
end architecture;
