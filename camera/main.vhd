-- OV7670 -> FPGA (EDGE Spartan-7) -> USB UART -> PC (OpenCV)
--
-- กล้องตั้งเป็น VGA YUV422 15 fps, FPGA เก็บเฉพาะ Y (ขาวดำ) ทุก 2 พิกเซล / 2 เส้น = 320x240
-- ไม่เก็บทั้งเฟรม: พิกเซลเข้า FIFO 16 KB แล้วไหลออก UART 12 Mbaud ทันที (สตรีมทุกเฟรม)
-- นาฬิการะบบ 96 MHz จาก MMCM (50 MHz x 24 / 12.5) -> UART 96/8 = 12 Mbaud, XCLK 96/4 = 24 MHz
--
-- รูปแบบข้อมูล ทีละเส้น: 0xFF, เลขเส้น (0..239), status, แล้ว 320 ไบต์ (ค่าพิกเซลถูกบีบให้ <= 0xFE)
--   status = 0xA5 ปกติ, 0xA4 กล้องไม่ตอบ ACK, 0xA6 FIFO ล้นในเฟรมนี้
-- ตั้งค่ากล้องซ้ำทุก ~1 วินาที เผื่อกล้องรีเซ็ตตัวเอง (ไฟกระตุก/ขั้วต่อขยับ)
--
-- sw0 = สลับเฟส byte (ถ้าภาพออกมาเป็นสีเทาเรียบ/นูน ให้โยก sw0)
-- led0 = กล้องตอบ ACK ครบ, led1 = กะพริบทุกเฟรม

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is
  generic (
    SIM : boolean := false        -- true: ใช้ clk เป็นนาฬิการะบบตรง ๆ (ไม่มี MMCM) และย่นเวลารอ
  );
  port (
    clk          : in    std_logic;
    sw0          : in    std_logic;
    led          : out   std_logic_vector(1 downto 0);
    ov7670_sioc  : out   std_logic;
    ov7670_siod  : inout std_logic;
    ov7670_vsync : in    std_logic;
    ov7670_href  : in    std_logic;
    ov7670_pclk  : in    std_logic;
    ov7670_xclk  : out   std_logic;
    ov7670_data  : in    std_logic_vector(7 downto 0);
    ov7670_reset : out   std_logic;
    ov7670_pwdn  : out   std_logic;
    usb_uart_txd : out   std_logic
  );
end entity;

architecture rtl of main is

  ---------------------------------------------------------------------------
  -- Xilinx primitives (ประกาศเองเพื่อให้ GHDL วิเคราะห์ไฟล์ได้โดยไม่ต้องมี unisim)
  ---------------------------------------------------------------------------
  component MMCME2_BASE
    generic (
      BANDWIDTH        : string  := "OPTIMIZED";
      CLKFBOUT_MULT_F  : real    := 5.0;
      CLKFBOUT_PHASE   : real    := 0.0;
      CLKIN1_PERIOD    : real    := 0.0;
      CLKOUT0_DIVIDE_F : real    := 1.0;
      DIVCLK_DIVIDE    : integer := 1;
      REF_JITTER1      : real    := 0.0;
      STARTUP_WAIT     : boolean := false
    );
    port (
      CLKOUT0   : out std_logic;
      CLKOUT0B  : out std_logic;
      CLKOUT1   : out std_logic;
      CLKOUT1B  : out std_logic;
      CLKOUT2   : out std_logic;
      CLKOUT2B  : out std_logic;
      CLKOUT3   : out std_logic;
      CLKOUT3B  : out std_logic;
      CLKOUT4   : out std_logic;
      CLKOUT5   : out std_logic;
      CLKOUT6   : out std_logic;
      CLKFBOUT  : out std_logic;
      CLKFBOUTB : out std_logic;
      LOCKED    : out std_logic;
      CLKIN1    : in  std_logic;
      PWRDWN    : in  std_logic;
      RST       : in  std_logic;
      CLKFBIN   : in  std_logic
    );
  end component;

  component BUFGCE
    port (O : out std_logic; CE : in std_logic; I : in std_logic);
  end component;

  ---------------------------------------------------------------------------
  -- ค่าคงที่ (นาฬิการะบบ 96 MHz)
  ---------------------------------------------------------------------------
  constant FIFO_AW  : natural := 14;      -- 16 KB
  constant BAUD_DIV : natural := 8;       -- 96 MHz / 8 = 12 Mbaud

  function sel(c : boolean; a, b : natural) return natural is
  begin
    if c then return a; else return b; end if;
  end function;

  constant SCCB_QDIV : natural := sel(SIM, 4, 480);          -- 1/4 บิต SCCB -> SCL 50 kHz
  constant SCCB_GAP  : natural := sel(SIM, 50, 960_000);     -- 10 ms ระหว่างแต่ละรีจิสเตอร์
  constant REFRESH   : natural := sel(SIM, 200, 96_000_000); -- ตั้งค่าซ้ำทุก 1 s
  constant SETTLE    : natural := sel(SIM, 50, 9_600_000);   -- 100 ms หลังตั้งค่าครั้งแรก

  ---------------------------------------------------------------------------
  -- รายการรีจิสเตอร์ OV7670 (reg & value)
  ---------------------------------------------------------------------------
  type rom_t is array (natural range <>) of std_logic_vector(15 downto 0);
  constant CAM_ROM : rom_t := (
    x"1280",  -- COM7  : soft reset
    x"1280",  -- COM7  : reset ซ้ำ (เผื่อครั้งแรกหลุด)
    x"1100",  -- CLKRC : prescale 1 -> 15 fps ที่ XCLK 24 MHz (PCLK 12 MHz)  (REFRESH_FROM)
    x"1200",  -- COM7  : VGA, YUV
    x"3A04",  -- TSLB  : ลำดับ Y U Y V
    x"3D88",  -- COM13 : gamma on, UV auto
    x"1E00"   -- MVFP  : ไม่กลับภาพ
  );
  constant REFRESH_FROM : natural := 2;   -- ตอนตั้งซ้ำไม่ต้องรีเซ็ตกล้อง
  constant MAX_RETRY    : natural := 3;

  ---------------------------------------------------------------------------
  -- Clock
  ---------------------------------------------------------------------------
  signal clk_sys  : std_logic;
  signal clk_mmcm : std_logic;
  signal clk_fb   : std_logic;
  signal locked   : std_logic;
  signal xclk_div : unsigned(1 downto 0) := "00";

  ---------------------------------------------------------------------------
  -- SCCB
  ---------------------------------------------------------------------------
  type sc_state_t is (SC_GAP, SC_START, SC_BITS, SC_STOP, SC_DONE);
  signal sc_state  : sc_state_t := SC_GAP;
  signal sc_qcnt   : natural range 0 to SCCB_QDIV - 1 := 0;
  signal sc_gapcnt : natural range 0 to REFRESH := 0;
  signal sc_phase  : unsigned(1 downto 0) := "00";
  signal sc_bit    : natural range 0 to 26 := 0;
  signal sc_shift  : std_logic_vector(26 downto 0) := (others => '1');
  signal sc_idx    : natural range 0 to CAM_ROM'length := 0;
  signal sc_retry  : natural range 0 to MAX_RETRY := 0;
  signal sc_nack   : std_logic := '0';   -- มี NACK ในรอบนี้
  signal scl_r     : std_logic := '1';
  signal sda_r     : std_logic := '1';
  signal sda_rel   : std_logic := '0';   -- '1' = ปล่อยสาย (ช่วง ACK)
  signal sda_in    : std_logic_vector(1 downto 0) := "11";
  signal cfg_done  : std_logic := '0';   -- ตั้งค่าครบหนึ่งรอบแล้ว (เริ่มจับภาพได้)
  signal cfg_ok    : std_logic := '0';   -- รอบล่าสุดกล้องตอบ ACK ครบ

  ---------------------------------------------------------------------------
  -- Capture
  ---------------------------------------------------------------------------
  signal pclk_s   : std_logic_vector(2 downto 0) := (others => '0');
  signal href_s   : std_logic_vector(2 downto 0) := (others => '0');
  signal vs_s     : std_logic_vector(2 downto 0) := (others => '0');
  signal sw_s     : std_logic_vector(1 downto 0) := (others => '0');
  signal d_s1     : std_logic_vector(7 downto 0) := (others => '0');
  signal d_s2     : std_logic_vector(7 downto 0) := (others => '0');

  type m_state_t is (M_WAIT_CFG, M_SETTLE, M_RUN);
  signal m_state  : m_state_t := M_WAIT_CFG;
  signal settle_c : natural range 0 to SETTLE := 0;
  signal byte_cnt : unsigned(10 downto 0) := (others => '0');  -- 0..1279 ในหนึ่งเส้น
  signal line_cnt : unsigned(8 downto 0)  := (others => '1');  -- 0..479 (เริ่มนอกเฟรม)
  signal phase    : std_logic := '0';                          -- ล็อกค่า sw0 ตอนเริ่มเฟรม
  signal hdr_cnt  : natural range 0 to 3 := 0;                 -- header ที่ยังต้องใส่ FIFO
  signal hdr_line : unsigned(7 downto 0) := (others => '0');
  signal ovf      : std_logic := '0';
  signal frame_t  : std_logic := '0';

  ---------------------------------------------------------------------------
  -- FIFO (BRAM)
  ---------------------------------------------------------------------------
  type ram_t is array (0 to 2 ** FIFO_AW - 1) of std_logic_vector(7 downto 0);
  signal ram     : ram_t;
  signal ram_we  : std_logic := '0';
  signal ram_wd  : std_logic_vector(7 downto 0) := (others => '0');
  signal ram_rd  : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_ptr  : unsigned(FIFO_AW - 1 downto 0) := (others => '0');
  signal rd_ptr  : unsigned(FIFO_AW - 1 downto 0) := (others => '0');
  signal ram_wa  : unsigned(FIFO_AW - 1 downto 0) := (others => '0');
  signal ram_ra  : unsigned(FIFO_AW - 1 downto 0) := (others => '0');

  ---------------------------------------------------------------------------
  -- UART TX (+ prefetch จาก FIFO)
  ---------------------------------------------------------------------------
  signal pf_state : natural range 0 to 2 := 0;
  signal nb_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal nb_valid : std_logic := '0';
  signal tx_busy  : std_logic := '0';
  signal tx_shift : std_logic_vector(8 downto 0) := (others => '1');
  signal tx_cnt   : natural range 0 to BAUD_DIV - 1 := 0;
  signal tx_bit   : natural range 0 to 9 := 0;
  signal txd_r    : std_logic := '1';

begin

  ---------------------------------------------------------------------------
  -- Clock: 50 MHz -> 96 MHz
  ---------------------------------------------------------------------------
  g_sim : if SIM generate
    clk_sys <= clk;
  end generate;

  g_hw : if not SIM generate
    u_mmcm : MMCME2_BASE
      generic map (
        CLKFBOUT_MULT_F  => 24.0,   -- VCO 1200 MHz
        CLKIN1_PERIOD    => 20.0,
        CLKOUT0_DIVIDE_F => 12.5,   -- 96 MHz
        DIVCLK_DIVIDE    => 1)
      port map (
        CLKOUT0 => clk_mmcm, CLKOUT0B => open, CLKOUT1 => open, CLKOUT1B => open,
        CLKOUT2 => open, CLKOUT2B => open, CLKOUT3 => open, CLKOUT3B => open,
        CLKOUT4 => open, CLKOUT5 => open, CLKOUT6 => open,
        CLKFBOUT => clk_fb, CLKFBOUTB => open, LOCKED => locked,
        CLKIN1 => clk, PWRDWN => '0', RST => '0', CLKFBIN => clk_fb);

    -- นาฬิกาจะเดินหลัง MMCM lock แล้วเท่านั้น
    u_bufg : BUFGCE port map (I => clk_mmcm, CE => locked, O => clk_sys);
  end generate;

  ov7670_xclk  <= xclk_div(1);  -- 24 MHz
  ov7670_reset <= '1';          -- active low
  ov7670_pwdn  <= '0';          -- active high
  ov7670_sioc  <= scl_r;
  ov7670_siod  <= 'Z' when sda_rel = '1' else sda_r;
  usb_uart_txd <= txd_r;
  led(0)       <= cfg_ok;
  led(1)       <= frame_t;

  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      xclk_div <= xclk_div + 1;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- SCCB writer: start, [0x42 ack] [reg ack] [data ack], stop
  -- ตรวจ ACK ทุกไบต์; ถ้า NACK ตอนตั้งค่าครั้งแรก -> เริ่มใหม่ (สูงสุด MAX_RETRY)
  -- จบแล้วรอ REFRESH แล้วเขียนรีจิสเตอร์ตั้งแต่ REFRESH_FROM ซ้ำ
  ---------------------------------------------------------------------------
  process (clk_sys)
    variable last_q : boolean;
  begin
    if rising_edge(clk_sys) then
      sda_in <= sda_in(0) & to_x01(ov7670_siod);
      last_q := (sc_qcnt = SCCB_QDIV - 1);
      if last_q then sc_qcnt <= 0; else sc_qcnt <= sc_qcnt + 1; end if;

      case sc_state is
        when SC_GAP =>
          scl_r <= '1'; sda_r <= '1'; sda_rel <= '0';
          if sc_gapcnt >= SCCB_GAP then
            sc_gapcnt <= 0;
            if sc_idx = CAM_ROM'length then
              -- จบหนึ่งรอบ
              if sc_nack = '1' and cfg_done = '0' and sc_retry < MAX_RETRY then
                sc_retry <= sc_retry + 1;
                sc_idx   <= 0;
              else
                cfg_done <= '1';
                cfg_ok   <= not sc_nack;
                sc_state <= SC_DONE;
              end if;
              sc_nack <= '0';
            else
              sc_shift <= x"42" & '1' & CAM_ROM(sc_idx)(15 downto 8) & '1'
                                      & CAM_ROM(sc_idx)(7 downto 0)  & '1';
              sc_phase <= "00";
              sc_state <= SC_START;
            end if;
          else
            sc_gapcnt <= sc_gapcnt + 1;
          end if;

        when SC_START =>
          if last_q then
            sc_phase <= sc_phase + 1;
            case sc_phase is
              when "00"   => scl_r <= '1'; sda_r <= '1';
              when "01"   => sda_r <= '0';
              when "10"   => scl_r <= '0';
              when others => sc_bit <= 0; sc_state <= SC_BITS;
            end case;
          end if;

        when SC_BITS =>
          if last_q then
            sc_phase <= sc_phase + 1;
            case sc_phase is
              when "00" =>
                sda_r <= sc_shift(26);
                if sc_bit = 8 or sc_bit = 17 or sc_bit = 26 then
                  sda_rel <= '1';           -- ช่อง ACK: ปล่อยสายให้กล้อง
                else
                  sda_rel <= '0';
                end if;
              when "01" => scl_r <= '1';
              when "10" =>
                if sda_rel = '1' and sda_in(1) /= '0' then
                  sc_nack <= '1';           -- กล้องไม่ดึง SDA ลง = NACK
                end if;
              when others =>
                scl_r    <= '0';
                sc_shift <= sc_shift(25 downto 0) & '1';
                if sc_bit = 26 then
                  sc_state <= SC_STOP;
                else
                  sc_bit <= sc_bit + 1;
                end if;
            end case;
          end if;

        when SC_STOP =>
          if last_q then
            sc_phase <= sc_phase + 1;
            case sc_phase is
              when "00"   => sda_rel <= '0'; sda_r <= '0';
              when "01"   => scl_r <= '1';
              when "10"   => sda_r <= '1';
              when others => sc_idx <= sc_idx + 1; sc_state <= SC_GAP;
            end case;
          end if;

        when SC_DONE =>
          scl_r <= '1'; sda_r <= '1'; sda_rel <= '0';
          if sc_gapcnt = REFRESH then
            sc_gapcnt <= 0;
            sc_idx    <= REFRESH_FROM;
            sc_state  <= SC_GAP;
          else
            sc_gapcnt <= sc_gapcnt + 1;
          end if;
      end case;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Synchronizers (ทุกสัญญาณกล้องผ่าน 2 FF เท่ากัน -> เฟสตรงกัน)
  ---------------------------------------------------------------------------
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      pclk_s <= pclk_s(1 downto 0) & ov7670_pclk;
      href_s <= href_s(1 downto 0) & ov7670_href;
      vs_s   <= vs_s(1 downto 0) & ov7670_vsync;
      d_s1   <= ov7670_data;
      d_s2   <= d_s1;
      sw_s   <= sw_s(0) & sw0;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- FIFO RAM
  ---------------------------------------------------------------------------
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      if ram_we = '1' then
        ram(to_integer(ram_wa)) <= ram_wd;
      end if;
      ram_rd <= ram(to_integer(ram_ra));
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Capture -> FIFO
  -- header ของเส้นถูกใส่ช่วง blanking (ตอน VSYNC ลง / HREF ลงของเส้นก่อนหน้า)
  ---------------------------------------------------------------------------
  process (clk_sys)
    variable pclk_rise : boolean;
    variable href_fall : boolean;
    variable vs_fall   : boolean;
    variable nl        : unsigned(8 downto 0);
    variable push      : boolean;
    variable pdata     : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk_sys) then
      pclk_rise := pclk_s(1) = '1' and pclk_s(2) = '0';
      href_fall := href_s(1) = '0' and href_s(2) = '1';
      vs_fall   := vs_s(1) = '0' and vs_s(2) = '1';
      push      := false;
      pdata     := (others => '0');
      ram_we    <= '0';

      case m_state is
        when M_WAIT_CFG =>
          if cfg_done = '1' then
            settle_c <= 0;
            m_state  <= M_SETTLE;
          end if;

        when M_SETTLE =>
          if settle_c = SETTLE then
            m_state <= M_RUN;
          else
            settle_c <= settle_c + 1;
          end if;

        when M_RUN =>
          if vs_fall then
            -- เริ่มเฟรม
            byte_cnt <= (others => '0');
            line_cnt <= (others => '0');
            phase    <= sw_s(1);
            ovf      <= '0';
            frame_t  <= not frame_t;
            hdr_line <= (others => '0');
            hdr_cnt  <= 3;
          elsif href_fall then
            byte_cnt <= (others => '0');
            nl       := line_cnt + 1;
            line_cnt <= nl;
            if nl(0) = '0' and nl < 480 then
              hdr_line <= nl(8 downto 1);
              hdr_cnt  <= 3;
            end if;
          elsif pclk_rise and href_s(1) = '1' then
            byte_cnt <= byte_cnt + 1;
            if line_cnt(0) = '0' and line_cnt < 480
               and byte_cnt(1 downto 0) = ('0' & phase) and byte_cnt < 1280 then
              push := true;
              if d_s2 = x"FF" then
                pdata := x"FE";              -- 0xFF ใช้เป็น sync เท่านั้น
              else
                pdata := d_s2;
              end if;
            end if;
          elsif hdr_cnt /= 0 then
            push := true;
            case hdr_cnt is
              when 3 =>
                pdata := x"FF";
              when 2 =>
                pdata := std_logic_vector(hdr_line);
              when others =>
                if ovf = '1' then
                  pdata := x"A6";
                elsif cfg_ok = '0' then
                  pdata := x"A4";
                else
                  pdata := x"A5";
                end if;
            end case;
            hdr_cnt <= hdr_cnt - 1;
          end if;
      end case;

      if push then
        if wr_ptr + 1 = rd_ptr then
          ovf <= '1';                        -- FIFO เต็ม: ทิ้งไบต์
        else
          ram_we <= '1';
          ram_wa <= wr_ptr;
          ram_wd <= pdata;
          wr_ptr <= wr_ptr + 1;
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- FIFO -> UART TX 8N1, LSB first (ดึงไบต์ถัดไปรอไว้ระหว่างส่ง)
  ---------------------------------------------------------------------------
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      -- prefetch
      case pf_state is
        when 0 =>
          if nb_valid = '0' and rd_ptr /= wr_ptr then
            ram_ra   <= rd_ptr;
            rd_ptr   <= rd_ptr + 1;
            pf_state <= 1;
          end if;
        when 1 =>
          pf_state <= 2;                     -- รอ BRAM
        when others =>
          nb_data  <= ram_rd;
          nb_valid <= '1';
          pf_state <= 0;
      end case;

      -- UART
      if tx_busy = '0' then
        txd_r <= '1';
        if nb_valid = '1' then
          txd_r    <= '0';                   -- start bit
          tx_shift <= '1' & nb_data;         -- data + stop
          nb_valid <= '0';
          tx_cnt   <= 0;
          tx_bit   <= 0;
          tx_busy  <= '1';
        end if;
      else
        if tx_cnt = BAUD_DIV - 1 then
          tx_cnt <= 0;
          if tx_bit = 9 then
            if nb_valid = '1' then
              -- ต่อไบต์ถัดไปทันที ไม่เว้นช่อง (ทุกรอบนาฬิกามีค่าที่ 12 Mbaud)
              txd_r    <= '0';
              tx_shift <= '1' & nb_data;
              nb_valid <= '0';
              tx_bit   <= 0;
            else
              tx_busy <= '0';
              txd_r   <= '1';
            end if;
          else
            txd_r    <= tx_shift(0);
            tx_shift <= '1' & tx_shift(8 downto 1);
            tx_bit   <= tx_bit + 1;
          end if;
        else
          tx_cnt <= tx_cnt + 1;
        end if;
      end if;
    end if;
  end process;

end architecture;
