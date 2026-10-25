## Clock 50 MHz
set_property -dict { PACKAGE_PIN H11 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]

## Switch / LED
set_property -dict { PACKAGE_PIN K11 IOSTANDARD LVCMOS33 } [get_ports sw0]
set_property -dict { PACKAGE_PIN K12 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN M12 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]

## USB UART
set_property -dict { PACKAGE_PIN F2 IOSTANDARD LVCMOS33 } [get_ports usb_uart_txd]

## OV7670 (J5)
set_property -dict { PACKAGE_PIN L14 IOSTANDARD LVCMOS33 PULLUP true } [get_ports ov7670_sioc]
set_property -dict { PACKAGE_PIN M13 IOSTANDARD LVCMOS33 PULLUP true } [get_ports ov7670_siod]
set_property -dict { PACKAGE_PIN H14 IOSTANDARD LVCMOS33 } [get_ports ov7670_vsync]
set_property -dict { PACKAGE_PIN H13 IOSTANDARD LVCMOS33 } [get_ports ov7670_href]
set_property -dict { PACKAGE_PIN F11 IOSTANDARD LVCMOS33 } [get_ports ov7670_pclk]
set_property -dict { PACKAGE_PIN G11 IOSTANDARD LVCMOS33 } [get_ports ov7670_xclk]
set_property -dict { PACKAGE_PIN C14 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[7]}]
set_property -dict { PACKAGE_PIN D14 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[6]}]
set_property -dict { PACKAGE_PIN E13 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[5]}]
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[4]}]
set_property -dict { PACKAGE_PIN F14 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[3]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[2]}]
set_property -dict { PACKAGE_PIN D13 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[1]}]
set_property -dict { PACKAGE_PIN D12 IOSTANDARD LVCMOS33 } [get_ports {ov7670_data[0]}]
set_property -dict { PACKAGE_PIN E12 IOSTANDARD LVCMOS33 } [get_ports ov7670_reset]
set_property -dict { PACKAGE_PIN F12 IOSTANDARD LVCMOS33 } [get_ports ov7670_pwdn]

## สัญญาณกล้องเป็น async -> ผ่าน synchronizer ใน FPGA เอง
set_false_path -from [get_ports {ov7670_pclk ov7670_href ov7670_vsync ov7670_data[*] ov7670_siod sw0}]
set_false_path -to   [get_ports {ov7670_sioc ov7670_siod ov7670_xclk ov7670_reset ov7670_pwdn usb_uart_txd led[*]}]

set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
