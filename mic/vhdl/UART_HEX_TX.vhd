----------------------------------------------------------------
-- UART hex transmitter
-- Sends a 24-bit value as 6 ASCII hex characters followed by
-- either a space or CR+LF (when last = '1').
----------------------------------------------------------------
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY UART_HEX_TX IS
    GENERIC (
        CLK_HZ : POSITIVE := 50_000_000;
        BAUD : POSITIVE := 115200
    );
    PORT (
        clk : IN STD_LOGIC;
        rst : IN STD_LOGIC;
        data_in : IN STD_LOGIC_VECTOR(23 DOWNTO 0);
        last : IN STD_LOGIC; -- '1' → CR+LF, '0' → space
        start : IN STD_LOGIC;
        txd : OUT STD_LOGIC;
        busy : OUT STD_LOGIC;
        done : OUT STD_LOGIC
    );
END ENTITY;

ARCHITECTURE Behavioral OF UART_HEX_TX IS

    CONSTANT BAUD_DIV : POSITIVE := CLK_HZ / BAUD;

    TYPE state_t IS (IDLE, LOAD, START_BIT, DATA_BIT, STOP_BIT, NEXT_CHAR);
    SIGNAL state : state_t := IDLE;

    SIGNAL baud_cnt : NATURAL RANGE 0 TO BAUD_DIV - 1 := 0;
    SIGNAL bit_idx : NATURAL RANGE 0 TO 7 := 0;
    SIGNAL char_idx : NATURAL RANGE 0 TO 7 := 0;

    SIGNAL shift_reg : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL tx_reg : STD_LOGIC := '1';
    SIGNAL data_reg : STD_LOGIC_VECTOR(23 DOWNTO 0) := (OTHERS => '0');
    SIGNAL last_reg : STD_LOGIC := '0';
    SIGNAL done_reg : STD_LOGIC := '0';

    FUNCTION nibble_to_ascii (n : STD_LOGIC_VECTOR(3 DOWNTO 0))
        RETURN STD_LOGIC_VECTOR IS
    BEGIN
        CASE n IS
            WHEN x"0" => RETURN x"30";
            WHEN x"1" => RETURN x"31";
            WHEN x"2" => RETURN x"32";
            WHEN x"3" => RETURN x"33";
            WHEN x"4" => RETURN x"34";
            WHEN x"5" => RETURN x"35";
            WHEN x"6" => RETURN x"36";
            WHEN x"7" => RETURN x"37";
            WHEN x"8" => RETURN x"38";
            WHEN x"9" => RETURN x"39";
            WHEN x"A" => RETURN x"41";
            WHEN x"B" => RETURN x"42";
            WHEN x"C" => RETURN x"43";
            WHEN x"D" => RETURN x"44";
            WHEN x"E" => RETURN x"45";
            WHEN x"F" => RETURN x"46";
            WHEN OTHERS => RETURN x"3F"; -- '?'
        END CASE;
    END FUNCTION;

BEGIN

    txd <= tx_reg;
    busy <= '0' WHEN state = IDLE ELSE
        '1';
    done <= done_reg;

    PROCESS (clk)
        VARIABLE nibble : STD_LOGIC_VECTOR(3 DOWNTO 0);
    BEGIN
        IF rising_edge(clk) THEN
            IF rst = '1' THEN
                state <= IDLE;
                baud_cnt <= 0;
                bit_idx <= 0;
                char_idx <= 0;
                tx_reg <= '1';
                done_reg <= '0';
            ELSE
                done_reg <= '0';

                CASE state IS
                    WHEN IDLE =>
                        tx_reg <= '1';
                        IF start = '1' THEN
                            data_reg <= data_in;
                            last_reg <= last;
                            char_idx <= 0;
                            state <= LOAD;
                        END IF;

                    WHEN LOAD =>
                        -- Prepare next character
                        CASE char_idx IS
                            WHEN 0 => nibble := data_reg(23 DOWNTO 20);
                            WHEN 1 => nibble := data_reg(19 DOWNTO 16);
                            WHEN 2 => nibble := data_reg(15 DOWNTO 12);
                            WHEN 3 => nibble := data_reg(11 DOWNTO 8);
                            WHEN 4 => nibble := data_reg(7 DOWNTO 4);
                            WHEN 5 => nibble := data_reg(3 DOWNTO 0);
                            WHEN 6 =>
                                IF last_reg = '1' THEN
                                    shift_reg <= x"0D"; -- CR
                                ELSE
                                    shift_reg <= x"20"; -- space
                                END IF;
                            WHEN 7 => shift_reg <= x"0A"; -- LF
                            WHEN OTHERS => NULL;
                        END CASE;

                        IF char_idx <= 5 THEN
                            shift_reg <= nibble_to_ascii(nibble);
                        END IF;

                        bit_idx <= 0;
                        baud_cnt <= 0;
                        state <= START_BIT;

                    WHEN START_BIT =>
                        tx_reg <= '0';
                        IF baud_cnt = BAUD_DIV - 1 THEN
                            baud_cnt <= 0;
                            state <= DATA_BIT;
                        ELSE
                            baud_cnt <= baud_cnt + 1;
                        END IF;

                    WHEN DATA_BIT =>
                        tx_reg <= shift_reg(0);
                        IF baud_cnt = BAUD_DIV - 1 THEN
                            baud_cnt <= 0;
                            shift_reg <= '0' & shift_reg(7 DOWNTO 1);
                            IF bit_idx = 7 THEN
                                state <= STOP_BIT;
                            ELSE
                                bit_idx <= bit_idx + 1;
                            END IF;
                        ELSE
                            baud_cnt <= baud_cnt + 1;
                        END IF;

                    WHEN STOP_BIT =>
                        tx_reg <= '1';
                        IF baud_cnt = BAUD_DIV - 1 THEN
                            baud_cnt <= 0;
                            state <= NEXT_CHAR;
                        ELSE
                            baud_cnt <= baud_cnt + 1;
                        END IF;

                    WHEN NEXT_CHAR =>
                        -- Finished after space (char 6) or after LF (char 7)
                        IF (last_reg = '0' AND char_idx = 6) OR
                            (last_reg = '1' AND char_idx = 7) THEN
                            done_reg <= '1';
                            state <= IDLE;
                        ELSE
                            char_idx <= char_idx + 1;
                            state <= LOAD;
                        END IF;

                    WHEN OTHERS =>
                        state <= IDLE;
                END CASE;
            END IF;
        END IF;
    END PROCESS;

END ARCHITECTURE;