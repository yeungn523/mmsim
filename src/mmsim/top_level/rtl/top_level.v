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

//=======================================================
//  PORT declarations
//=======================================================

////////////////////////////////////
// FPGA Pins
////////////////////////////////////

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

// I2C Bus for Configuration of the Audio and Video-In Chips
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

////////////////////////////////////
// HPS Pins
////////////////////////////////////
	
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

//=======================================================
//  REG/WIRE declarations
//=======================================================

wire			[23: 0]	hex5_hex0;

HexDigit Digit0(HEX0, hex5_hex0[3:0]);
HexDigit Digit1(HEX1, hex5_hex0[7:4]);
HexDigit Digit2(HEX2, hex5_hex0[11:8]);
HexDigit Digit3(HEX3, hex5_hex0[15:12]);
HexDigit Digit4(HEX4, hex5_hex0[19:16]);
HexDigit Digit5(HEX5, hex5_hex0[23:20]);

// -------------------------------------------------------
// PLL clocks from Qsys
// -------------------------------------------------------
// vga_pll is the 25.175 MHz pixel clock (outclk0 of VGA_PLL inside Computer_System); vga_pll_lock asserts once the PLL
// is stable. Both are driven by Computer_System through the exported VGA_PLL interfaces below.
wire vga_pll_lock;
wire vga_pll;

// -------------------------------------------------------
// VGA reset (active high)
// -------------------------------------------------------
// Asserted whenever KEY[0] is held (manual reset) or the VGA PLL has not yet locked, so vga_driver and the chart M10K
// read port stay in reset until the pixel clock is stable.
wire vga_reset = ~KEY[0] | ~vga_pll_lock;

//=======================================================
//  Structural coding - Qsys Computer_System
//=======================================================

Computer_System The_System (
	////////////////////////////////////
	// FPGA Side
	////////////////////////////////////

	// Global signals
	.system_pll_ref_clk_clk         (CLOCK_50),
	.system_pll_ref_reset_reset     (1'b0),

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

	// VGA PLL reference: the PLL inside VGA_PLL takes CLOCK_50 as its reference and produces the 25.175 MHz pixel clock
	// on outclk0; the matching engine's M10Ks already run on CLOCK_50 so no separate M10K PLL is needed.
	.vga_pll_ref_clk_clk       (CLOCK_50),
	.vga_pll_ref_reset_reset   (1'b0),
	.vga_pll_locked_export     (vga_pll_lock),
	.vga_pll_outclk0_clk       (vga_pll)
);

// Derives the market simulator's active-low reset directly from KEY[0]; holding KEY[0] asserts reset.
wire core_rst_n = KEY[0];

// Configures the round-robin slot count from the slide switches; the parameter loader inputs stay tied off until a
// PIO is wired through Qsys.
wire [15:0] active_agent_count = {6'd0, SW};
wire        param_wr_en        = 1'b0;
wire [15:0] param_wr_addr      = 16'd0;
wire [31:0] param_wr_data      = 32'd0;

// Carries the order packet and the valid/ready handshake between order generation and the matching engine.
wire [31:0] order_packet;
wire        order_valid;
wire        order_ready;

// Captures every matching engine output. Only last_executed_price feeds back into order generation; the rest stay as
// named wires so future visualization or logging blocks can pick them up.
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
wire        me_order_retire_valid;
wire [15:0] me_order_retire_trade_count;
wire [15:0] me_order_retire_fill_quantity;

// Depth tap wires from the matching engine to the VGA renderer. The renderer drives the tick index combinationally on
// the pixel clock; the price level stores' time-multiplexed port B returns the bid-side and ask-side resting quantities
// one cycle later.
wire [8:0]  depth_rd_addr;
wire [15:0] me_bid_depth_rd_data;
wire [15:0] me_ask_depth_rd_data;

// Carries the chart aggregator, history buffer, and renderer pipeline plus the vga_driver pixel-coordinate feedback.
wire [31:0] chart_window_min_price;
wire [31:0] chart_window_max_price;
wire        chart_window_valid;
wire [8:0]  chart_rd_offset;
wire [8:0]  chart_rd_top_pixel_y;
wire [8:0]  chart_rd_bottom_pixel_y;
wire [9:0]  vga_next_x;
wire [9:0]  vga_next_y;
wire [7:0]  vga_color_in;

// Crosses the active-high vga_reset into the pixel-clock domain through a two-stage synchronizer.
reg  vga_rst_sync_a;
reg  vga_rst_sync_b;
wire vga_rst_pixel = vga_rst_sync_b;

// Generates orders by composing the ziggurat Gaussian, the GBM price source, the agent units, and the round-robin
// arbiter; presents the resulting packet on the valid/ready bus.
order_gen_top u_order_gen (
	.clk                 (CLOCK_50),
	.rst_n               (core_rst_n),
	.last_executed_price (me_last_executed_price),
	.trade_valid         (me_trade_valid),
	.active_agent_count  (active_agent_count),
	.param_wr_en         (param_wr_en),
	.param_wr_addr       (param_wr_addr),
	.param_wr_data       (param_wr_data),
	.order_packet        (order_packet),
	.order_valid         (order_valid),
	.order_ready         (order_ready)
);

// Matches each accepted order through the three-stage pipeline over the two no-cancellation price level stores and
// republishes trade and top-of-book observations.
matching_engine u_matching_engine (
	.clk                        (CLOCK_50),
	.rst_n                      (core_rst_n),
	.order_packet               (order_packet),
	.order_valid                (order_valid),
	.order_ready                (order_ready),
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
	.order_retire_trade_count   (me_order_retire_trade_count),
	.order_retire_fill_quantity (me_order_retire_fill_quantity),
	.depth_rd_addr              (depth_rd_addr),
	.bid_depth_rd_data          (me_bid_depth_rd_data),
	.ask_depth_rd_data          (me_ask_depth_rd_data)
);

// Aggregates trades into fixed wall-clock windows; each closed window emits the min and max prices plus a valid pulse.
tick_window_aggregator u_tick_window_aggregator (
	.clk              (CLOCK_50),
	.rst_n            (core_rst_n),
	.trade_valid      (me_trade_valid),
	.trade_price      (me_trade_price),
	.window_min_price (chart_window_min_price),
	.window_max_price (chart_window_max_price),
	.window_valid     (chart_window_valid)
);

// Drives the two-stage VGA reset synchronizer; vga_rst_pixel is the destination-domain reset.
always @(posedge vga_pll or posedge vga_reset) begin
	if (vga_reset) begin
		vga_rst_sync_a <= 1'b1;
		vga_rst_sync_b <= 1'b1;
	end else begin
		vga_rst_sync_a <= 1'b0;
		vga_rst_sync_b <= vga_rst_sync_a;
	end
end

// Caches one (top, bottom) pixel-Y pair per closed window and serves it back on the pixel clock through the M10K CDC.
circular_buffer u_chart_history (
	.wr_clk            (CLOCK_50),
	.rst_n             (core_rst_n),
	.wr_en             (chart_window_valid),
	.wr_min_price      (chart_window_min_price),
	.wr_max_price      (chart_window_max_price),
	.rd_clk            (vga_pll),
	.rd_offset         (chart_rd_offset),
	.rd_top_pixel_y    (chart_rd_top_pixel_y),
	.rd_bottom_pixel_y (chart_rd_bottom_pixel_y)
);

// Walks the screen at the pixel clock and forwards the upcoming pixel coordinate one cycle ahead of color registration.
vga_driver u_vga_driver (
	.clock   (vga_pll),
	.reset   (vga_rst_pixel),
	.color_in(vga_color_in),
	.next_x  (vga_next_x),
	.next_y  (vga_next_y),
	.hsync   (VGA_HS),
	.vsync   (VGA_VS),
	.red     (VGA_R),
	.green   (VGA_G),
	.blue    (VGA_B),
	.sync    (VGA_SYNC_N),
	.clk     (VGA_CLK),
	.blank   (VGA_BLANK_N)
);

// Maps each pixel coordinate to RGB332 by combining the rolling chart history on the left half and the bid/ask depth
// ladder on the right half; outputs feed back into vga_driver.color_in.
renderer u_renderer (
	.next_x            (vga_next_x),
	.next_y            (vga_next_y),
	.rd_offset         (chart_rd_offset),
	.rd_top_pixel_y    (chart_rd_top_pixel_y),
	.rd_bottom_pixel_y (chart_rd_bottom_pixel_y),
	.depth_rd_addr     (depth_rd_addr),
	.bid_depth_rd_data (me_bid_depth_rd_data),
	.ask_depth_rd_data (me_ask_depth_rd_data),
	.color_in          (vga_color_in)
);

// Drives the six HEX digits with the upper 24 bits of the most recent execution price (Q8.24). HEX5:HEX4 show the
// integer byte, HEX3:HEX2 show the upper fractional byte, HEX1:HEX0 show the next fractional byte.
assign hex5_hex0 = me_last_executed_price[31:8];

// Ties LEDR low so the LED bar pins have a defined driver; Quartus warns otherwise.
assign LEDR = 10'd0;

endmodule
