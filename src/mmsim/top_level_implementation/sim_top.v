`timescale 1ns/1ns
///
/// @file sim_top.v
/// @brief Integration top level: order generation subsystem + matching engine.
///
/// Wires order_gen_top's FIFO read port directly into matching_engine's external FIFO
/// interface. HPS control signals fan out to order_gen_top. Matching engine feedback
/// (last_trade_price, trade_valid) loops back into order_gen_top. VGA ports are stubbed
/// as output wires for later connection.
///
module sim_top #(
    // Order generation
    parameter NUM_UNITS        = 4,
    parameter PTR_WIDTH        = 2,
    parameter SLOTS_PER_UNIT   = 64,
    parameter FIFO_DEPTH       = 256,
    parameter FIFO_AF_THRESH   = 16,
    // GBM
    parameter signed [31:0] GBM_MU_ITO_DT     = 32'sh00000000,
    parameter signed [31:0] GBM_SIGMA_SQRT_DT  = 32'sh00000451,
    parameter        [31:0] GBM_SIGMA_INIT      = 32'h00000451,
    parameter        [31:0] GBM_ALPHA           = 32'h00FD70A4,
    parameter        [31:0] GBM_P0_RECIP        = 32'h00028F5C,
    // Agent execution
    parameter [31:0] LFSR_SEED_BASE    = 32'hCAFEBABE,
    parameter [31:0] LFSR_POLY         = 32'hB4BCD35C,
    parameter [8:0]  NEAR_NOISE_THRESH = 9'd16,
    // Matching engine
    parameter kPriceWidth    = 32,
    parameter kQuantityWidth = 16,
    parameter kPriceRange    = 480
)(
    input  wire        clk,
    input  wire        rst_n,

    // HPS runtime controls
    input  wire [15:0] hps_active_agent_count,
    // HPS agent parameter write port
    input  wire        hps_param_wr_en,
    input  wire [15:0] hps_param_wr_addr,
    input  wire [31:0] hps_param_wr_data,

    // Matching engine outputs (for TB monitoring and future VGA)
    output wire [kPriceWidth-1:0]    best_bid_price,
    output wire [kQuantityWidth-1:0] best_bid_quantity,
    output wire                      best_bid_valid,
    output wire [kPriceWidth-1:0]    best_ask_price,
    output wire [kQuantityWidth-1:0] best_ask_quantity,
    output wire                      best_ask_valid,
    output wire [kPriceWidth-1:0]    trade_price,
    output wire [kQuantityWidth-1:0] trade_quantity,
    output wire                      trade_side,
    output wire                      trade_valid,
    output wire [kPriceWidth-1:0]    last_trade_price,
    output wire                      last_trade_price_valid,
    output wire                      order_retire_valid,
    output wire [kQuantityWidth-1:0] order_retire_trade_count,
    output wire [kQuantityWidth-1:0] order_retire_fill_quantity
);

    // FIFO interconnect between order_gen_top and matching_engine
    wire [31:0] fifo_dout;
    wire        fifo_empty;
    wire        fifo_rd_en;

    order_gen_top #(
        .NUM_UNITS        (NUM_UNITS),
        .PTR_WIDTH        (PTR_WIDTH),
        .SLOTS_PER_UNIT   (SLOTS_PER_UNIT),
        .FIFO_DEPTH       (FIFO_DEPTH),
        .FIFO_AF_THRESH   (FIFO_AF_THRESH),
        .GBM_MU_ITO_DT    (GBM_MU_ITO_DT),
        .GBM_SIGMA_SQRT_DT(GBM_SIGMA_SQRT_DT),
        .GBM_SIGMA_INIT   (GBM_SIGMA_INIT),
        .GBM_ALPHA        (GBM_ALPHA),
        .GBM_P0_RECIP     (GBM_P0_RECIP),
        .LFSR_SEED_BASE   (LFSR_SEED_BASE),
        .LFSR_POLY        (LFSR_POLY),
        .NEAR_NOISE_THRESH(NEAR_NOISE_THRESH)
    ) u_order_gen (
        .clk                (clk),
        .rst_n              (rst_n),
        .last_exec_price    (last_trade_price),
        .trade_valid        (trade_valid),
        .active_agent_count (hps_active_agent_count),
        .param_wr_en        (hps_param_wr_en),
        .param_wr_addr      (hps_param_wr_addr),
        .param_wr_data      (hps_param_wr_data),
        .fifo_rd_en         (fifo_rd_en),
        .fifo_dout          (fifo_dout),
        .fifo_empty         (fifo_empty)
    );

    matching_engine #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kPriceRange    (kPriceRange)
    ) u_matching_engine (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .fifo_dout                  (fifo_dout),
        .fifo_empty                 (fifo_empty),
        .fifo_rd_en                 (fifo_rd_en),
        .trade_price                (trade_price),
        .trade_quantity             (trade_quantity),
        .trade_side                 (trade_side),
        .trade_valid                (trade_valid),
        .last_trade_price           (last_trade_price),
        .last_trade_price_valid     (last_trade_price_valid),
        .best_bid_price             (best_bid_price),
        .best_bid_quantity          (best_bid_quantity),
        .best_bid_valid             (best_bid_valid),
        .best_ask_price             (best_ask_price),
        .best_ask_quantity          (best_ask_quantity),
        .best_ask_valid             (best_ask_valid),
        .order_retire_valid         (order_retire_valid),
        .order_retire_trade_count   (order_retire_trade_count),
        .order_retire_fill_quantity (order_retire_fill_quantity)
    );

endmodule