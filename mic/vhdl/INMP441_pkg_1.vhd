----------------------------------------------------------------
-- Package
----------------------------------------------------------------
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;

PACKAGE inmp441_pkg IS
    -- 8 parallel microphones, each 24-bit sample
    TYPE TYPE_DATA_24BIT_ARRAY IS ARRAY (0 TO 7) OF STD_LOGIC_VECTOR(23 DOWNTO 0);
END PACKAGE;