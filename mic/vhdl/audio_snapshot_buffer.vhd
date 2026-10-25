library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Two packed 1024x24 synchronous RAMs. No reset of RAM contents.
-- Snapshot address is chronological, not the physical ring address.
entity audio_snapshot_buffer is
    port (
        clk, rst : in std_logic;
        frame_valid : in std_logic;
        samples_flat : in std_logic_vector(191 downto 0);
        snapshot_request, snapshot_release : in std_logic;
        snapshot_valid : out std_logic;
        snapshot_head : out unsigned(6 downto 0);
        snapshot_bank : out std_logic;
        overrun : out std_logic;
        rd_en : in std_logic;
        rd_addr : in unsigned(9 downto 0);
        rd_valid : out std_logic;
        rd_data : out signed(23 downto 0)
    );
end entity;

architecture rtl of audio_snapshot_buffer is
    type ram_type is array(0 to 1023) of std_logic_vector(23 downto 0);
    signal ram_a, ram_b : ram_type;
    attribute ram_style : string;
    attribute ram_style of ram_a, ram_b : signal is "block";
    signal write_bank, locked_bank : std_logic := '0';
    signal head, saved_head : unsigned(6 downto 0) := (others => '0');
    signal fresh_count : natural range 0 to 128 := 0;
    signal locked, writing : std_logic := '0';
    signal column : natural range 0 to 7 := 0;
    signal held_samples : std_logic_vector(191 downto 0);
    signal physical_read : unsigned(9 downto 0);
    signal data_a, data_b : std_logic_vector(23 downto 0);
begin
    snapshot_valid <= locked;
    snapshot_bank <= locked_bank;
    snapshot_head <= saved_head;
    -- Fixed 7-bit addition implements modulo 128, preserving microphone bits.
    physical_read <= (saved_head + rd_addr(9 downto 3)) & rd_addr(2 downto 0);
    rd_data <= signed(data_a) when locked_bank = '0' else signed(data_b);

    memories : process(clk)
        variable address : natural range 0 to 1023;
    begin
        if rising_edge(clk) then
            if rst = '0' then
                if writing = '1' then
                    address := to_integer(head)*8 + column;
                    if write_bank = '0' then
                        ram_a(address) <= held_samples(column*24+23 downto column*24);
                    else
                        ram_b(address) <= held_samples(column*24+23 downto column*24);
                    end if;
                end if;
                if rd_en = '1' and locked = '1' then
                    if locked_bank = '0' then
                        data_a <= ram_a(to_integer(physical_read));
                    else
                        data_b <= ram_b(to_integer(physical_read));
                    end if;
                end if;
            end if;
        end if;
    end process;

    control : process(clk)
    begin
        if rising_edge(clk) then
            rd_valid <= '0';
            if rst = '1' then
                write_bank <= '0';
                locked_bank <= '0';
                head <= (others => '0');
                saved_head <= (others => '0');
                fresh_count <= 0;
                locked <= '0';
                writing <= '0';
                column <= 0;
                overrun <= '0';
            else
                rd_valid <= rd_en and locked;
                if snapshot_release = '1' then locked <= '0'; end if;
                if frame_valid = '1' then
                    if writing = '0' then
                        held_samples <= samples_flat;
                        writing <= '1';
                        column <= 0;
                    else
                        -- A missing frame invalidates continuity: restart history count.
                        overrun <= '1';
                        fresh_count <= 0;
                    end if;
                end if;
                if writing = '1' then
                    if column = 7 then
                        writing <= '0';
                        head <= head + 1;
                        if fresh_count < 128 then fresh_count <= fresh_count + 1; end if;
                        if snapshot_request = '1' and locked = '0' and
                           fresh_count >= 127 and frame_valid = '0' then
                            locked <= '1';
                            locked_bank <= write_bank;
                            saved_head <= head + 1;
                            write_bank <= not write_bank;
                            head <= (others => '0');
                            fresh_count <= 0;
                        end if;
                    else
                        column <= column + 1;
                    end if;
                    -- On an overrun, discard all earlier history including this frame.
                    if frame_valid = '1' then fresh_count <= 0; end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
