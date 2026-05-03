module DE1_SoC_Computer (
	////////////////////////////////////
	// FPGA Pins
	////////////////////////////////////

	// Clock pins
	CLOCK_50,
	CLOCK2_50,
	CLOCK3_50,
	CLOCK4_50,

	// ADC
	ADC_CS_N,
	ADC_DIN,
	ADC_DOUT,
	ADC_SCLK,

	// Audio
	AUD_ADCDAT,
	AUD_ADCLRCK,
	AUD_BCLK,
	AUD_DACDAT,
	AUD_DACLRCK,
	AUD_XCK,

	// SDRAM
	DRAM_ADDR,
	DRAM_BA,
	DRAM_CAS_N,
	DRAM_CKE,
	DRAM_CLK,
	DRAM_CS_N,
	DRAM_DQ,
	DRAM_LDQM,
	DRAM_RAS_N,
	DRAM_UDQM,
	DRAM_WE_N,

	// I2C Bus for Configuration of the Audio and Video-In Chips
	FPGA_I2C_SCLK,
	FPGA_I2C_SDAT,

	// 40-Pin Headers
	GPIO_0,
	GPIO_1,
	
	// Seven Segment Displays
	HEX0,
	HEX1,
	HEX2,
	HEX3,
	HEX4,
	HEX5,

	// IR
	IRDA_RXD,
	IRDA_TXD,

	// Pushbuttons
	KEY,

	// LEDs
	LEDR,

	// PS2 Ports
	PS2_CLK,
	PS2_DAT,
	
	PS2_CLK2,
	PS2_DAT2,

	// Slider Switches
	SW,

	// Video-In
	TD_CLK27,
	TD_DATA,
	TD_HS,
	TD_RESET_N,
	TD_VS,

	// VGA
	VGA_B,
	VGA_BLANK_N,
	VGA_CLK,
	VGA_G,
	VGA_HS,
	VGA_R,
	VGA_SYNC_N,
	VGA_VS,

	////////////////////////////////////
	// HPS Pins
	////////////////////////////////////
	
	// DDR3 SDRAM
	HPS_DDR3_ADDR,
	HPS_DDR3_BA,
	HPS_DDR3_CAS_N,
	HPS_DDR3_CKE,
	HPS_DDR3_CK_N,
	HPS_DDR3_CK_P,
	HPS_DDR3_CS_N,
	HPS_DDR3_DM,
	HPS_DDR3_DQ,
	HPS_DDR3_DQS_N,
	HPS_DDR3_DQS_P,
	HPS_DDR3_ODT,
	HPS_DDR3_RAS_N,
	HPS_DDR3_RESET_N,
	HPS_DDR3_RZQ,
	HPS_DDR3_WE_N,

	// Ethernet
	HPS_ENET_GTX_CLK,
	HPS_ENET_INT_N,
	HPS_ENET_MDC,
	HPS_ENET_MDIO,
	HPS_ENET_RX_CLK,
	HPS_ENET_RX_DATA,
	HPS_ENET_RX_DV,
	HPS_ENET_TX_DATA,
	HPS_ENET_TX_EN,

	// Flash
	HPS_FLASH_DATA,
	HPS_FLASH_DCLK,
	HPS_FLASH_NCSO,

	// Accelerometer
	HPS_GSENSOR_INT,
		
	// General Purpose I/O
	HPS_GPIO,
		
	// I2C
	HPS_I2C_CONTROL,
	HPS_I2C1_SCLK,
	HPS_I2C1_SDAT,
	HPS_I2C2_SCLK,
	HPS_I2C2_SDAT,

	// Pushbutton
	HPS_KEY,

	// LED
	HPS_LED,
		
	// SD Card
	HPS_SD_CLK,
	HPS_SD_CMD,
	HPS_SD_DATA,

	// SPI
	HPS_SPIM_CLK,
	HPS_SPIM_MISO,
	HPS_SPIM_MOSI,
	HPS_SPIM_SS,

	// UART
	HPS_UART_RX,
	HPS_UART_TX,

	// USB
	HPS_CONV_USB_N,
	HPS_USB_CLKOUT,
	HPS_USB_DATA,
	HPS_USB_DIR,
	HPS_USB_NXT,
	HPS_USB_STP
);

// PORT declarations

// FPGA Pins

// Clock pins
input            CLOCK_50;
input            CLOCK2_50;
input            CLOCK3_50;
input            CLOCK4_50;

// ADC
inout            ADC_CS_N;
output           ADC_DIN;
input            ADC_DOUT;
output           ADC_SCLK;

// Audio
input            AUD_ADCDAT;
inout            AUD_ADCLRCK;
inout            AUD_BCLK;
output           AUD_DACDAT;
inout            AUD_DACLRCK;
output           AUD_XCK;

// SDRAM
output  [12: 0]  DRAM_ADDR;
output  [ 1: 0]  DRAM_BA;
output           DRAM_CAS_N;
output           DRAM_CKE;
output           DRAM_CLK;
output           DRAM_CS_N;
inout   [15: 0]  DRAM_DQ;
output           DRAM_LDQM;
output           DRAM_RAS_N;
output           DRAM_UDQM;
output           DRAM_WE_N;

// I2C bus for the audio and video-in chips.
output           FPGA_I2C_SCLK;
inout            FPGA_I2C_SDAT;

// 40-pin headers
inout   [35: 0]  GPIO_0;
inout   [35: 0]  GPIO_1;

// Seven Segment Displays
output  [ 6: 0]  HEX0;
output  [ 6: 0]  HEX1;
output  [ 6: 0]  HEX2;
output  [ 6: 0]  HEX3;
output  [ 6: 0]  HEX4;
output  [ 6: 0]  HEX5;

// IR
input            IRDA_RXD;
output           IRDA_TXD;

// Pushbuttons
input   [ 3: 0]  KEY;

// LEDs
output  [ 9: 0]  LEDR;

// PS2 Ports
inout            PS2_CLK;
inout            PS2_DAT;

inout            PS2_CLK2;
inout            PS2_DAT2;

// Slider Switches
input   [ 9: 0]  SW;

// Video-In
input            TD_CLK27;
input   [ 7: 0]  TD_DATA;
input            TD_HS;
output           TD_RESET_N;
input            TD_VS;

// VGA
output  [ 7: 0]  VGA_B;
output           VGA_BLANK_N;
output           VGA_CLK;
output  [ 7: 0]  VGA_G;
output           VGA_HS;
output  [ 7: 0]  VGA_R;
output           VGA_SYNC_N;
output           VGA_VS;

// HPS Pins

// DDR3 SDRAM
output  [14: 0]  HPS_DDR3_ADDR;
output  [ 2: 0]  HPS_DDR3_BA;
output           HPS_DDR3_CAS_N;
output           HPS_DDR3_CKE;
output           HPS_DDR3_CK_N;
output           HPS_DDR3_CK_P;
output           HPS_DDR3_CS_N;
output  [ 3: 0]  HPS_DDR3_DM;
inout   [31: 0]  HPS_DDR3_DQ;
inout   [ 3: 0]  HPS_DDR3_DQS_N;
inout   [ 3: 0]  HPS_DDR3_DQS_P;
output           HPS_DDR3_ODT;
output           HPS_DDR3_RAS_N;
output           HPS_DDR3_RESET_N;
input            HPS_DDR3_RZQ;
output           HPS_DDR3_WE_N;

// Ethernet
output           HPS_ENET_GTX_CLK;
inout            HPS_ENET_INT_N;
output           HPS_ENET_MDC;
inout            HPS_ENET_MDIO;
input            HPS_ENET_RX_CLK;
input   [ 3: 0]  HPS_ENET_RX_DATA;
input            HPS_ENET_RX_DV;
output  [ 3: 0]  HPS_ENET_TX_DATA;
output           HPS_ENET_TX_EN;

// Flash
inout   [ 3: 0]  HPS_FLASH_DATA;
output           HPS_FLASH_DCLK;
output           HPS_FLASH_NCSO;

// Accelerometer
inout            HPS_GSENSOR_INT;

// General Purpose I/O
inout   [ 1: 0]  HPS_GPIO;

// I2C
inout            HPS_I2C_CONTROL;
inout            HPS_I2C1_SCLK;
inout            HPS_I2C1_SDAT;
inout            HPS_I2C2_SCLK;
inout            HPS_I2C2_SDAT;

// Pushbutton
inout            HPS_KEY;

// LED
inout            HPS_LED;

// SD Card
output           HPS_SD_CLK;
inout            HPS_SD_CMD;
inout   [ 3: 0]  HPS_SD_DATA;

// SPI
output           HPS_SPIM_CLK;
input            HPS_SPIM_MISO;
output           HPS_SPIM_MOSI;
inout            HPS_SPIM_SS;

// UART
input            HPS_UART_RX;
output           HPS_UART_TX;

// USB
inout            HPS_CONV_USB_N;
input            HPS_USB_CLKOUT;
inout   [ 7: 0]  HPS_USB_DATA;
input            HPS_USB_DIR;
input            HPS_USB_NXT;
output           HPS_USB_STP;

// REG/WIRE declarations

wire [23:0] hex5_hex0;

HexDigit Digit0(HEX0, hex5_hex0[3:0]);
HexDigit Digit1(HEX1, hex5_hex0[7:4]);
HexDigit Digit2(HEX2, hex5_hex0[11:8]);
HexDigit Digit3(HEX3, hex5_hex0[15:12]);
HexDigit Digit4(HEX4, hex5_hex0[19:16]);
HexDigit Digit5(HEX5, hex5_hex0[23:20]);

// Agent parameter memory flat buses
wire [16*10-1:0] agent_param_rd_addr;
wire [16*32-1:0] agent_param_rd_data;

// Per-agent unpacked read signals
wire [ 9:0] agent_addr  [0:15];
wire [31:0] agent_rdata [0:15];

genvar i;
generate
    for (i = 0; i < 16; i = i + 1) begin : gen_agent_wires
        assign agent_addr[i]                    = agent_param_rd_addr[i*10 +: 10];
        assign agent_param_rd_data[i*32 +: 32] = agent_rdata[i];
    end
endgenerate

// Market simulator interconnect wires

// Drives the active-low core reset from KEY[0].
wire core_rst_n = KEY[0];

// Reads the active agent count from the slide switches.
wire [15:0] active_agent_count = {6'd0, SW};

// Ties off the param loader; no PIO is wired through Qsys yet.
wire        param_wr_en   = 1'b0;
wire [15:0] param_wr_addr = 16'd0;
wire [31:0] param_wr_data = 32'd0;

// Order bus between order_gen_top and matching_engine.
wire [31:0] order_packet;
wire        gen_order_valid;
wire        me_order_ready;

// Matching engine scalar outputs.
wire [31:0] me_trade_price;
wire [15:0] me_trade_quantity;
wire        me_trade_side;
wire        me_trade_valid;
wire [31:0] me_last_executed_price;
wire        me_last_executed_price_valid;
wire [31:0] me_best_bid_price;
wire [15:0] me_best_bid_quantity;
wire        me_best_bid_valid;
wire [31:0] me_best_ask_price;
wire [15:0] me_best_ask_quantity;
wire        me_best_ask_valid;

// Matching engine retire bus.
wire        me_order_retire_valid;
wire [15:0] me_order_retire_trade_count;
wire [15:0] me_order_retire_fill_quantity;
wire [ 1:0] me_order_retire_agent_type;

// Depth tap between matching_engine and orderbook_writer.
wire [ 8:0] depth_rd_addr;
wire [15:0] me_bid_depth_rd_data;
wire [15:0] me_ask_depth_rd_data;

// Orderbook M10K write port (driven by orderbook_writer, read by Qsys s1).
wire [ 9:0] ob_mem_addr;
wire        ob_mem_write;
wire [31:0] ob_mem_writedata;

// Injection debug bus from order_gen_top.
wire [31:0] inject_packet;
wire        inject_trigger;
wire [31:0] inject_count;
wire        inject_active;

// AnalogClock divider: ~100 snapshots/sec at 50 MHz, drives orderbook_writer only.
localparam [29:0] SPEED = 30'd500_000;

reg  [29:0] counter;
wire        AnalogClock;

always @(posedge CLOCK_50) begin
    if (!core_rst_n || counter >= SPEED)
        counter <= 30'd0;
    else
        counter <= counter + 30'd1;
end

assign AnalogClock = (counter == 30'd0);

// Module instantiations

// Qsys Computer_System
Computer_System The_System (
	////////////////////////////////////
	// FPGA Side
	////////////////////////////////////

	.system_pll_ref_clk_clk         (CLOCK_50),
	.system_pll_ref_reset_reset      (1'b0),

	////////////////////////////////////
	// HPS Side
	////////////////////////////////////

	// DDR3 SDRAM
	.memory_mem_a          (HPS_DDR3_ADDR),
	.memory_mem_ba         (HPS_DDR3_BA),
	.memory_mem_ck         (HPS_DDR3_CK_P),
	.memory_mem_ck_n       (HPS_DDR3_CK_N),
	.memory_mem_cke        (HPS_DDR3_CKE),
	.memory_mem_cs_n       (HPS_DDR3_CS_N),
	.memory_mem_ras_n      (HPS_DDR3_RAS_N),
	.memory_mem_cas_n      (HPS_DDR3_CAS_N),
	.memory_mem_we_n       (HPS_DDR3_WE_N),
	.memory_mem_reset_n    (HPS_DDR3_RESET_N),
	.memory_mem_dq         (HPS_DDR3_DQ),
	.memory_mem_dqs        (HPS_DDR3_DQS_P),
	.memory_mem_dqs_n      (HPS_DDR3_DQS_N),
	.memory_mem_odt        (HPS_DDR3_ODT),
	.memory_mem_dm         (HPS_DDR3_DM),
	.memory_oct_rzqin      (HPS_DDR3_RZQ),

	// SDRAM
	.sdram_clk_clk      (DRAM_CLK),
	.sdram_addr         (DRAM_ADDR),
	.sdram_ba           (DRAM_BA),
	.sdram_cas_n        (DRAM_CAS_N),
	.sdram_cke          (DRAM_CKE),
	.sdram_cs_n         (DRAM_CS_N),
	.sdram_dq           (DRAM_DQ),
	.sdram_dqm          ({DRAM_UDQM, DRAM_LDQM}),
	.sdram_ras_n        (DRAM_RAS_N),
	.sdram_we_n         (DRAM_WE_N),

	// Shared On-Chip Memory for Orderbook (exported from Qsys)
	.orderbook_mem_address    (ob_mem_addr),
	.orderbook_mem_write      (ob_mem_write),
	.orderbook_mem_writedata  (ob_mem_writedata),
	.orderbook_mem_chipselect (1'b1),
	.orderbook_mem_clken      (1'b1),
	.orderbook_mem_byteenable (4'b1111),
	.orderbook_mem_readdata   (),

	// Agent 0
	.agent_0_address    (agent_addr[0]),
	.agent_0_clken      (1'b1),
	.agent_0_chipselect (1'b1),
	.agent_0_write      (1'b0),
	.agent_0_writedata  (32'd0),
	.agent_0_byteenable (4'b1111),
	.agent_0_readdata   (agent_rdata[0]),
	// Agent 1
	.agent_1_address    (agent_addr[1]),
	.agent_1_clken      (1'b1),
	.agent_1_chipselect (1'b1),
	.agent_1_write      (1'b0),
	.agent_1_writedata  (32'd0),
	.agent_1_byteenable (4'b1111),
	.agent_1_readdata   (agent_rdata[1]),
	// Agent 2
	.agent_2_address    (agent_addr[2]),
	.agent_2_clken      (1'b1),
	.agent_2_chipselect (1'b1),
	.agent_2_write      (1'b0),
	.agent_2_writedata  (32'd0),
	.agent_2_byteenable (4'b1111),
	.agent_2_readdata   (agent_rdata[2]),
	// Agent 3
	.agent_3_address    (agent_addr[3]),
	.agent_3_clken      (1'b1),
	.agent_3_chipselect (1'b1),
	.agent_3_write      (1'b0),
	.agent_3_writedata  (32'd0),
	.agent_3_byteenable (4'b1111),
	.agent_3_readdata   (agent_rdata[3]),
	// Agent 4
	.agent_4_address    (agent_addr[4]),
	.agent_4_clken      (1'b1),
	.agent_4_chipselect (1'b1),
	.agent_4_write      (1'b0),
	.agent_4_writedata  (32'd0),
	.agent_4_byteenable (4'b1111),
	.agent_4_readdata   (agent_rdata[4]),
	// Agent 5
	.agent_5_address    (agent_addr[5]),
	.agent_5_clken      (1'b1),
	.agent_5_chipselect (1'b1),
	.agent_5_write      (1'b0),
	.agent_5_writedata  (32'd0),
	.agent_5_byteenable (4'b1111),
	.agent_5_readdata   (agent_rdata[5]),
	// Agent 6
	.agent_6_address    (agent_addr[6]),
	.agent_6_clken      (1'b1),
	.agent_6_chipselect (1'b1),
	.agent_6_write      (1'b0),
	.agent_6_writedata  (32'd0),
	.agent_6_byteenable (4'b1111),
	.agent_6_readdata   (agent_rdata[6]),
	// Agent 7
	.agent_7_address    (agent_addr[7]),
	.agent_7_clken      (1'b1),
	.agent_7_chipselect (1'b1),
	.agent_7_write      (1'b0),
	.agent_7_writedata  (32'd0),
	.agent_7_byteenable (4'b1111),
	.agent_7_readdata   (agent_rdata[7]),
	// Agent 8
	.agent_8_address    (agent_addr[8]),
	.agent_8_clken      (1'b1),
	.agent_8_chipselect (1'b1),
	.agent_8_write      (1'b0),
	.agent_8_writedata  (32'd0),
	.agent_8_byteenable (4'b1111),
	.agent_8_readdata   (agent_rdata[8]),
	// Agent 9
	.agent_9_address    (agent_addr[9]),
	.agent_9_clken      (1'b1),
	.agent_9_chipselect (1'b1),
	.agent_9_write      (1'b0),
	.agent_9_writedata  (32'd0),
	.agent_9_byteenable (4'b1111),
	.agent_9_readdata   (agent_rdata[9]),
	// Agent 10
	.agent_10_address    (agent_addr[10]),
	.agent_10_clken      (1'b1),
	.agent_10_chipselect (1'b1),
	.agent_10_write      (1'b0),
	.agent_10_writedata  (32'd0),
	.agent_10_byteenable (4'b1111),
	.agent_10_readdata   (agent_rdata[10]),
	// Agent 11
	.agent_11_address    (agent_addr[11]),
	.agent_11_clken      (1'b1),
	.agent_11_chipselect (1'b1),
	.agent_11_write      (1'b0),
	.agent_11_writedata  (32'd0),
	.agent_11_byteenable (4'b1111),
	.agent_11_readdata   (agent_rdata[11]),
	// Agent 12
	.agent_12_address    (agent_addr[12]),
	.agent_12_clken      (1'b1),
	.agent_12_chipselect (1'b1),
	.agent_12_write      (1'b0),
	.agent_12_writedata  (32'd0),
	.agent_12_byteenable (4'b1111),
	.agent_12_readdata   (agent_rdata[12]),
	// Agent 13
	.agent_13_address    (agent_addr[13]),
	.agent_13_clken      (1'b1),
	.agent_13_chipselect (1'b1),
	.agent_13_write      (1'b0),
	.agent_13_writedata  (32'd0),
	.agent_13_byteenable (4'b1111),
	.agent_13_readdata   (agent_rdata[13]),
	// Agent 14
	.agent_14_address    (agent_addr[14]),
	.agent_14_clken      (1'b1),
	.agent_14_chipselect (1'b1),
	.agent_14_write      (1'b0),
	.agent_14_writedata  (32'd0),
	.agent_14_byteenable (4'b1111),
	.agent_14_readdata   (agent_rdata[14]),
	// Agent 15
	.agent_15_address    (agent_addr[15]),
	.agent_15_clken      (1'b1),
	.agent_15_chipselect (1'b1),
	.agent_15_write      (1'b0),
	.agent_15_writedata  (32'd0),
	.agent_15_byteenable (4'b1111),
	.agent_15_readdata   (agent_rdata[15]),

	// Ethernet
	.hps_io_hps_io_gpio_inst_GPIO35  (HPS_ENET_INT_N),
	.hps_io_hps_io_emac1_inst_TX_CLK (HPS_ENET_GTX_CLK),
	.hps_io_hps_io_emac1_inst_TXD0   (HPS_ENET_TX_DATA[0]),
	.hps_io_hps_io_emac1_inst_TXD1   (HPS_ENET_TX_DATA[1]),
	.hps_io_hps_io_emac1_inst_TXD2   (HPS_ENET_TX_DATA[2]),
	.hps_io_hps_io_emac1_inst_TXD3   (HPS_ENET_TX_DATA[3]),
	.hps_io_hps_io_emac1_inst_RXD0   (HPS_ENET_RX_DATA[0]),
	.hps_io_hps_io_emac1_inst_MDIO   (HPS_ENET_MDIO),
	.hps_io_hps_io_emac1_inst_MDC    (HPS_ENET_MDC),
	.hps_io_hps_io_emac1_inst_RX_CTL (HPS_ENET_RX_DV),
	.hps_io_hps_io_emac1_inst_TX_CTL (HPS_ENET_TX_EN),
	.hps_io_hps_io_emac1_inst_RX_CLK (HPS_ENET_RX_CLK),
	.hps_io_hps_io_emac1_inst_RXD1   (HPS_ENET_RX_DATA[1]),
	.hps_io_hps_io_emac1_inst_RXD2   (HPS_ENET_RX_DATA[2]),
	.hps_io_hps_io_emac1_inst_RXD3   (HPS_ENET_RX_DATA[3]),

	// Flash
	.hps_io_hps_io_qspi_inst_IO0  (HPS_FLASH_DATA[0]),
	.hps_io_hps_io_qspi_inst_IO1  (HPS_FLASH_DATA[1]),
	.hps_io_hps_io_qspi_inst_IO2  (HPS_FLASH_DATA[2]),
	.hps_io_hps_io_qspi_inst_IO3  (HPS_FLASH_DATA[3]),
	.hps_io_hps_io_qspi_inst_SS0  (HPS_FLASH_NCSO),
	.hps_io_hps_io_qspi_inst_CLK  (HPS_FLASH_DCLK),

	// Accelerometer
	.hps_io_hps_io_gpio_inst_GPIO61 (HPS_GSENSOR_INT),

	// General Purpose I/O
	.hps_io_hps_io_gpio_inst_GPIO40 (HPS_GPIO[0]),
	.hps_io_hps_io_gpio_inst_GPIO41 (HPS_GPIO[1]),

	// I2C
	.hps_io_hps_io_gpio_inst_GPIO48 (HPS_I2C_CONTROL),
	.hps_io_hps_io_i2c0_inst_SDA    (HPS_I2C1_SDAT),
	.hps_io_hps_io_i2c0_inst_SCL    (HPS_I2C1_SCLK),
	.hps_io_hps_io_i2c1_inst_SDA    (HPS_I2C2_SDAT),
	.hps_io_hps_io_i2c1_inst_SCL    (HPS_I2C2_SCLK),

	// Pushbutton
	.hps_io_hps_io_gpio_inst_GPIO54 (HPS_KEY),

	// LED
	.hps_io_hps_io_gpio_inst_GPIO53 (HPS_LED),

	// SD Card
	.hps_io_hps_io_sdio_inst_CMD  (HPS_SD_CMD),
	.hps_io_hps_io_sdio_inst_D0   (HPS_SD_DATA[0]),
	.hps_io_hps_io_sdio_inst_D1   (HPS_SD_DATA[1]),
	.hps_io_hps_io_sdio_inst_CLK  (HPS_SD_CLK),
	.hps_io_hps_io_sdio_inst_D2   (HPS_SD_DATA[2]),
	.hps_io_hps_io_sdio_inst_D3   (HPS_SD_DATA[3]),

	// SPI
	.hps_io_hps_io_spim1_inst_CLK  (HPS_SPIM_CLK),
	.hps_io_hps_io_spim1_inst_MOSI (HPS_SPIM_MOSI),
	.hps_io_hps_io_spim1_inst_MISO (HPS_SPIM_MISO),
	.hps_io_hps_io_spim1_inst_SS0  (HPS_SPIM_SS),

	// UART
	.hps_io_hps_io_uart0_inst_RX (HPS_UART_RX),
	.hps_io_hps_io_uart0_inst_TX (HPS_UART_TX),

	// USB
	.hps_io_hps_io_gpio_inst_GPIO09 (HPS_CONV_USB_N),
	.hps_io_hps_io_usb1_inst_D0     (HPS_USB_DATA[0]),
	.hps_io_hps_io_usb1_inst_D1     (HPS_USB_DATA[1]),
	.hps_io_hps_io_usb1_inst_D2     (HPS_USB_DATA[2]),
	.hps_io_hps_io_usb1_inst_D3     (HPS_USB_DATA[3]),
	.hps_io_hps_io_usb1_inst_D4     (HPS_USB_DATA[4]),
	.hps_io_hps_io_usb1_inst_D5     (HPS_USB_DATA[5]),
	.hps_io_hps_io_usb1_inst_D6     (HPS_USB_DATA[6]),
	.hps_io_hps_io_usb1_inst_CLK    (HPS_USB_CLKOUT),
	.hps_io_hps_io_usb1_inst_D7     (HPS_USB_DATA[7]),
	.hps_io_hps_io_usb1_inst_STP    (HPS_USB_STP),
	.hps_io_hps_io_usb1_inst_DIR    (HPS_USB_DIR),
	.hps_io_hps_io_usb1_inst_NXT    (HPS_USB_NXT),

	// VGA Subsystem
	.vga_pll_ref_clk_clk     (CLOCK2_50),
	.vga_pll_ref_reset_reset (1'b0),
	.vga_CLK                 (VGA_CLK),
	.vga_BLANK               (VGA_BLANK_N),
	.vga_SYNC                (VGA_SYNC_N),
	.vga_HS                  (VGA_HS),
	.vga_VS                  (VGA_VS),
	.vga_R                   (VGA_R),
	.vga_G                   (VGA_G),
	.vga_B                   (VGA_B)
);

// Order generator
order_gen_top u_order_gen (
    .clk                 (CLOCK_50),
    .rst_n               (core_rst_n),
    .last_executed_price (me_last_executed_price),
    .trade_valid         (me_trade_valid),
    .active_agent_count  (active_agent_count),
    .param_rd_addr       (agent_param_rd_addr),
    .param_rd_data       (agent_param_rd_data),
    .order_packet        (order_packet),
    .order_valid         (gen_order_valid),
    .order_ready         (me_order_ready),
    .inject_packet       (inject_packet),
    .inject_trigger      (inject_trigger),
    .inject_count        (inject_count),
    .inject_active       (inject_active)
);


matching_engine #(
    .kPriceRange    (400),
    .kTickShiftBits (23)
) u_matching_engine (
    .clk                        (CLOCK_50),
    .rst_n                      (core_rst_n),
    .order_packet               (order_packet),
    .order_valid                (gen_order_valid),
    .order_ready                (me_order_ready),
    .trade_price                (me_trade_price),
    .trade_quantity             (me_trade_quantity),
    .trade_side                 (me_trade_side),
    .trade_valid                (me_trade_valid),
    .last_executed_price        (me_last_executed_price),
    .last_executed_price_valid  (me_last_executed_price_valid),
    .best_bid_price             (me_best_bid_price),
    .best_bid_quantity          (me_best_bid_quantity),
    .best_bid_valid             (me_best_bid_valid),
    .best_ask_price             (me_best_ask_price),
    .best_ask_quantity          (me_best_ask_quantity),
    .best_ask_valid             (me_best_ask_valid),
    .order_retire_valid         (me_order_retire_valid),
    .order_retire_agent_type    (me_order_retire_agent_type),
    .order_retire_trade_count   (me_order_retire_trade_count),
    .order_retire_fill_quantity (me_order_retire_fill_quantity),
    .depth_rd_addr              (depth_rd_addr),
    .bid_depth_rd_data          (me_bid_depth_rd_data),
    .ask_depth_rd_data          (me_ask_depth_rd_data)
);


orderbook_writer u_ob_writer (
    .clk                        (CLOCK_50),
    .rst_n                      (core_rst_n),
    .analog_clock               (AnalogClock),
    .depth_rd_addr              (depth_rd_addr),
    .bid_depth_rd_data          (me_bid_depth_rd_data),
    .ask_depth_rd_data          (me_ask_depth_rd_data),
    .last_executed_price        (me_last_executed_price),
    .last_executed_price_valid  (me_last_executed_price_valid),
    .best_bid_price             (me_best_bid_price),
    .best_bid_valid             (me_best_bid_valid),
    .best_ask_price             (me_best_ask_price),
    .best_ask_valid             (me_best_ask_valid),
    .order_retire_valid         (me_order_retire_valid),
    .order_retire_agent_type    (me_order_retire_agent_type),
    .order_retire_fill_quantity (me_order_retire_fill_quantity),
    .mem_address                (ob_mem_addr),
    .mem_write                  (ob_mem_write),
    .mem_writedata              (ob_mem_writedata),
    .mem_chipselect             (),
    .mem_clken                  (),
    .mem_byteenable             ()
);


reg [23:0] retire_count;
reg        trade_ever;

always @(posedge CLOCK_50) begin
    if (!core_rst_n) begin
        retire_count <= 24'd0;
        trade_ever   <= 1'b0;
    end else begin
        if (me_order_retire_valid) retire_count <= retire_count + 24'd1;
        if (me_trade_valid)        trade_ever   <= 1'b1;
    end
end

// HEX display — retire_count proves orders are cycling.
assign hex5_hex0 = retire_count;
assign LEDR = {trade_ever, me_trade_valid, 2'b00, retire_count[5:0]};

endmodule


// Scans the matching engine depth tap and metadata each AnalogClock cycle and writes them
// into the shared orderbook M10K for HPS/VGA consumption.
//
// Memory layout (word addresses):
//   [0   .. 399] bid quantities, one word per price tick
//   [400 .. 799] ask quantities, one word per price tick
//   [800]        last_executed_price (Q8.24)
//   [801]        best_bid_price      (Q8.24)
//   [802]        best_ask_price      (Q8.24)
//   [803]        cumulative_volume
//   [804]        frame_counter
//   [805]        noise_volume
//   [806]        mm_volume
//   [807]        momentum_volume
//   [808]        value_volume
module orderbook_writer #(
    parameter kPriceRange    = 400,
    parameter kTickShiftBits = 23
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        analog_clock,

    // Matching engine depth tap
    output reg  [8:0]  depth_rd_addr,
    input  wire [15:0] bid_depth_rd_data,
    input  wire [15:0] ask_depth_rd_data,

    // Matching engine scalar outputs
    input  wire [31:0] last_executed_price,
    input  wire        last_executed_price_valid,
    input  wire [31:0] best_bid_price,
    input  wire        best_bid_valid,
    input  wire [31:0] best_ask_price,
    input  wire        best_ask_valid,

    // Retire bus
    input  wire        order_retire_valid,
    input  wire [ 1:0] order_retire_agent_type,
    input  wire [15:0] order_retire_fill_quantity,

    // Orderbook M10K s1 port
    output reg  [ 9:0] mem_address,
    output reg         mem_write,
    output reg  [31:0] mem_writedata,
    output wire        mem_chipselect,
    output wire        mem_clken,
    output wire [ 3:0] mem_byteenable
);

    assign mem_chipselect = 1'b1;
    assign mem_clken      = 1'b1;
    assign mem_byteenable = 4'b1111;

    // FSM States
    localparam [2:0] kStateDone       = 3'd0;
    localparam [2:0] kStateScanSetup  = 3'd1;
    localparam [2:0] kStateScanRead   = 3'd2;
    localparam [2:0] kStateScanAsk    = 3'd3;
    localparam [2:0] kStateMetaWrite  = 3'd4;

    reg [2:0]  state;
    reg [8:0]  scan_addr;
    reg [3:0]  meta_idx;

    // Latches both bid and ask in kStateScanRead while depth_rd_addr is still stable for that tick.
    reg [15:0] latched_bid;
    reg [15:0] latched_ask;

    // Cumulative volume counters per agent type.
    reg [31:0] cumulative_volume;
    reg [31:0] frame_counter;
    reg [31:0] noise_volume;
    reg [31:0] mm_volume;
    reg [31:0] momentum_volume;
    reg [31:0] value_volume;

    // Updates the price latches whenever the matching engine asserts valid.
    reg [31:0] last_exec_latch;
    reg [31:0] best_bid_latch;
    reg [31:0] best_ask_latch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_exec_latch <= 32'd0;
            best_bid_latch  <= 32'd0;
            best_ask_latch  <= 32'd0;
        end else begin
            if (last_executed_price_valid)
                last_exec_latch <= last_executed_price;
				if (best_bid_valid && best_bid_price != 0)
                best_bid_latch  <= best_bid_price << kTickShiftBits;
            if (best_ask_valid && best_ask_price != 0)
                best_ask_latch  <= best_ask_price << kTickShiftBits;
        end
    end

    // Volume accumulation on the retire bus
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cumulative_volume <= 32'd0;
            noise_volume      <= 32'd0;
            mm_volume         <= 32'd0;
            momentum_volume   <= 32'd0;
            value_volume      <= 32'd0;
        end else if (order_retire_valid && order_retire_fill_quantity > 0) begin
            cumulative_volume <= cumulative_volume + order_retire_fill_quantity;
            case (order_retire_agent_type)
                2'd0: noise_volume    <= noise_volume    + order_retire_fill_quantity;
                2'd1: mm_volume       <= mm_volume       + order_retire_fill_quantity;
                2'd2: momentum_volume <= momentum_volume + order_retire_fill_quantity;
                2'd3: value_volume    <= value_volume    + order_retire_fill_quantity;
            endcase
        end
    end

    // Main scan FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= kStateDone;
            scan_addr     <= 9'd0;
            meta_idx      <= 4'd0;
            depth_rd_addr <= 9'd0;
            mem_address   <= 10'd0;
            mem_write     <= 1'b0;
            mem_writedata <= 32'd0;
            frame_counter <= 32'd0;
            latched_bid   <= 16'd0;
            latched_ask   <= 16'd0;
        end else begin
            mem_write <= 1'b0;

            case (state)

                // Waits for AnalogClock; one full scan per admitted-order cycle.
                kStateDone: begin
                    if (analog_clock) begin
                        frame_counter <= frame_counter + 32'd1;
                        scan_addr     <= 9'd0;
                        depth_rd_addr <= 9'd0;
                        state         <= kStateScanSetup;
                    end
                end

                // Presents the address to the M10K read port; data is valid next cycle.
                kStateScanSetup: begin
                    state <= kStateScanRead;
                end

                // Latches both bid and ask from the same depth_rd_addr; writes bid this cycle.
                kStateScanRead: begin
                    latched_bid   <= bid_depth_rd_data;
                    latched_ask   <= ask_depth_rd_data;
                    mem_address   <= {1'b0, scan_addr};
                    mem_writedata <= {16'd0, bid_depth_rd_data};
                    mem_write     <= 1'b1;
                    state         <= kStateScanAsk;
                end

                // Writes the ask side from the latch and advances the scan or moves to metadata.
                kStateScanAsk: begin
                    mem_address   <= 10'd400 + {1'b0, scan_addr};
                    mem_writedata <= {16'd0, latched_ask};
                    mem_write     <= 1'b1;

                    if (scan_addr == kPriceRange - 1) begin
                        meta_idx <= 4'd0;
                        state    <= kStateMetaWrite;
                    end else begin
                        scan_addr     <= scan_addr + 9'd1;
                        depth_rd_addr <= scan_addr + 9'd1;
                        state         <= kStateScanSetup;
                    end
                end

                // Writes 9 metadata words (indices 0-8) sequentially.
                kStateMetaWrite: begin
                    mem_write <= 1'b1;
                    case (meta_idx)
                        4'd0: begin mem_address <= 10'd800; mem_writedata <= last_exec_latch;   end
                        4'd1: begin mem_address <= 10'd801; mem_writedata <= best_bid_latch;    end
                        4'd2: begin mem_address <= 10'd802; mem_writedata <= best_ask_latch;    end
                        4'd3: begin mem_address <= 10'd803; mem_writedata <= cumulative_volume; end
                        4'd4: begin mem_address <= 10'd804; mem_writedata <= frame_counter;     end
                        4'd5: begin mem_address <= 10'd805; mem_writedata <= noise_volume;      end
                        4'd6: begin mem_address <= 10'd806; mem_writedata <= mm_volume;         end
                        4'd7: begin mem_address <= 10'd807; mem_writedata <= momentum_volume;   end
                        default: begin mem_address <= 10'd808; mem_writedata <= value_volume;   end
                    endcase

                    if (meta_idx == 4'd8)
                        state <= kStateDone;
                    else
                        meta_idx <= meta_idx + 4'd1;
                end

                default: state <= kStateDone;
            endcase
        end
    end

endmodule
