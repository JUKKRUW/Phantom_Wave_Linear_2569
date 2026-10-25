library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Digital core, independently testable without microphones or board pins.
entity acoustic_core is
    port (
        clk, rst, frame_valid : in std_logic;
        samples_flat : in std_logic_vector(191 downto 0);
        score_valid : out std_logic;
        score_ready : in std_logic;
        score_index : out unsigned(7 downto 0);
        score_data : out unsigned(63 downto 0);
        map_done, capture_overrun : out std_logic
    );
end entity;

architecture rtl of acoustic_core is
    type state_type is (acquire, request_mean, wait_mean, finish_mean,
                        launch, scanning, launch_levels, reading_levels, release_wait);
    signal state : state_type := acquire;
    signal request_snapshot, release_snapshot, available : std_logic;
    signal scan_start, scan_done, rd_en, rd_valid : std_logic;
    signal rd_addr : unsigned(9 downto 0);
    signal rd_data : signed(23 downto 0);
    signal scan_read, level_read, scan_valid, level_valid, level_start, level_done : std_logic;
    signal scan_address, level_address : unsigned(9 downto 0);
    signal scan_index, level_index : unsigned(7 downto 0);
    signal scan_data, level_data : unsigned(63 downto 0);
    signal scan_ready, level_ready : std_logic;
    type means_type is array(0 to 7) of signed(23 downto 0);
    signal means : means_type := (others => (others => '0'));
    signal mean_mic, read_mic : natural range 0 to 7 := 0;
    signal mean_time : natural range 0 to 127 := 0;
    signal mean_sum : signed(30 downto 0) := (others => '0');
    signal centered_data : signed(23 downto 0);
begin
    request_snapshot <= '1' when state = acquire else '0';
    release_snapshot <= '1' when state = release_wait else '0';
    scan_start <= '1' when state = launch else '0';
    map_done <= level_done;
    level_start <= '1' when state = launch_levels else '0';
    rd_en <= '1' when state = request_mean else
             level_read when state = reading_levels else scan_read;
    rd_addr <= to_unsigned(mean_time*8+mean_mic,10)
               when state = request_mean or state = wait_mean else
               level_address when state = reading_levels else scan_address;
    score_valid <= level_valid when state = reading_levels else scan_valid;
    score_index <= level_index when state = reading_levels else scan_index;
    score_data <= level_data when state = reading_levels else scan_data;
    scan_ready <= score_ready when state = scanning else '0';
    level_ready <= score_ready when state = reading_levels else '0';
    storage : entity work.audio_snapshot_buffer
        port map(clk, rst, frame_valid, samples_flat, request_snapshot,
                 release_snapshot, available, open, open, capture_overrun,
                 rd_en, rd_addr, rd_valid, rd_data);
    scanner : entity work.acoustic_scan
        port map(clk, rst, scan_start, open, scan_done,
                 scan_read, scan_address, rd_valid, centered_data,
                 scan_valid, scan_ready, scan_index, scan_data);
    levels : entity work.mic_level_scan
        port map(clk,rst,level_start,level_done,level_read,level_address,rd_valid,rd_data,
                 level_valid,level_ready,level_index,level_data);
    -- Keep RAM unchanged: center only the samples delivered to the beamformer.
    -- The microphone index is latched with the read request, like the RAM data.
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then read_mic <= 0;
            elsif scan_read = '1' then
                read_mic <= to_integer(scan_address(2 downto 0));
            end if;
        end if;
    end process;
    process(rd_data, means, read_mic)
        variable difference : signed(24 downto 0);
    begin
        difference := resize(rd_data,25)-resize(means(read_mic),25);
        -- Subtracting a mean can exceed signed 24-bit range. Saturate, never wrap.
        if difference > to_signed(8388607,25) then
            centered_data <= to_signed(8388607,24);
        elsif difference < to_signed(-8388608,25) then
            centered_data <= to_signed(-8388608,24);
        else centered_data <= resize(difference,24); end if;
    end process;
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= acquire;
                means <= (others => (others => '0'));
                mean_mic <= 0; mean_time <= 0;
                mean_sum <= (others => '0');
            else
                case state is
                    when acquire =>
                        if available = '1' then
                            mean_mic <= 0; mean_time <= 0;
                            mean_sum <= (others => '0'); state <= request_mean;
                        end if;
                    when request_mean => state <= wait_mean;
                    when wait_mean =>
                        if rd_valid = '1' then
                            mean_sum <= mean_sum+resize(rd_data,31);
                            if mean_time = 127 then state <= finish_mean;
                            else mean_time <= mean_time+1; state <= request_mean; end if;
                        end if;
                    when finish_mean =>
                        means(mean_mic) <= resize(shift_right(mean_sum,7),24);
                        if mean_mic = 7 then state <= launch;
                        else
                            mean_mic <= mean_mic+1; mean_time <= 0;
                            mean_sum <= (others => '0'); state <= request_mean;
                        end if;
                    when launch => state <= scanning;
                    when scanning => if scan_done = '1' then state <= launch_levels; end if;
                    when launch_levels => state <= reading_levels;
                    when reading_levels => if level_done = '1' then state <= release_wait; end if;
                    when release_wait => state <= acquire;
                end case;
            end if;
        end if;
    end process;
end architecture;
