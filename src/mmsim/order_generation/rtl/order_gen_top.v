///
/// @file order_gen_top.v
/// @brief Top-level order generation subsystem composing the GBM source, agent units, and the round-robin arbiter.
///

module order_gen_top #(
    parameter NUM_UNITS       = 16,                              ///< Number of agent execution units (must be a power of two).
    parameter PTR_WIDTH       = 4,                               ///< Bit width of the arbiter pointer (log2(NUM_UNITS)).
    parameter SLOTS_PER_UNIT  = 64,                              ///< Parameter M10K slots provisioned per agent unit.

    parameter signed [31:0] GBM_MU_ITO_DT     = 32'sh00000000,   ///< GBM Ito-corrected drift override.
    parameter signed [31:0] GBM_SIGMA_SQRT_DT = 32'sh00000451,   ///< GBM sigma * sqrt(dt) override.
    parameter        [31:0] GBM_SIGMA_INIT    = 32'h00000451,    ///< GBM initial sigma override.
    parameter        [31:0] GBM_ALPHA         = 32'h00FD70A4,    ///< GBM EWMA smoothing factor override.
    parameter        [31:0] GBM_P0_RECIP      = 32'h00028F5C,    ///< GBM reciprocal of the reference price override.

    parameter [31:0] LFSR_SEED_BASE    = 32'hCAFEBABE,           ///< Base seed for per-unit LFSRs (unit i seeds with BASE + i).
    parameter [31:0] LFSR_POLY         = 32'hB4BCD35C,           ///< Galois polynomial shared by every per-unit LFSR.
    parameter [8:0]  NEAR_NOISE_THRESH = 9'd16                   ///< Offset below which noise traders emit market orders.
)(
    input  wire        clk,                                      ///< System clock.
    input  wire        rst_n,                                    ///< Active-low asynchronous reset.

    input  wire [31:0] last_executed_price,                      ///< Most recent execution price from the matching engine (Q8.24 unsigned).
    input  wire        trade_valid,                              ///< Pulses one cycle on every matching engine execution.

    input  wire [15:0] active_agent_count,                       ///< Number of slots each agent unit round-robins through.

    input  wire        param_wr_en,                              ///< HPS-driven parameter write enable.
    input  wire [15:0] param_wr_addr,                            ///< Parameter write address; high bits select unit, low bits select slot.
    input  wire [31:0] param_wr_data,                            ///< Parameter word written into the selected unit/slot.

    output wire [31:0] order_packet,                             ///< Packet driven onto the bus while order_valid is high.
    output wire        order_valid,                              ///< Asserts when the arbiter is presenting a packet.
    input  wire        order_ready                               ///< Consumer accepts the packet when high alongside order_valid.
);

    localparam SLOTS_LOG2 = 6;  // log2(64), adjust if SLOTS_PER_UNIT changes.

    wire [15:0] zig_gauss_out;
    wire        zig_valid_out;

    wire [31:0] gbm_price_out;
    wire [31:0] gbm_sigma_out;
    wire        gbm_price_valid;

    wire [NUM_UNITS-1:0]    unit_order_valid;
    wire [NUM_UNITS*32-1:0] unit_order_packet;
    wire [NUM_UNITS-1:0]    unit_order_granted;

    ziggurat_gaussian u_ziggurat (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (1'b1),
        .seed0      (32'hDEADBEEF),
        .seed1      (32'hCAFEBABE),
        .seed2      (32'h12345678),
        .seed3      (32'hABCDEF01),
        .seed_valid (1'b0),
        .gauss_out  (zig_gauss_out),
        .valid_out  (zig_valid_out)
    );

    gbm_logspace #(
        .MU_ITO_DT_DEF      (GBM_MU_ITO_DT),
        .SIGMA_SQRT_DT_DEF  (GBM_SIGMA_SQRT_DT),
        .SIGMA_INIT_DEF     (GBM_SIGMA_INIT),
        .ALPHA_FP_DEF       (GBM_ALPHA),
        .P0_RECIP_DEF       (GBM_P0_RECIP)
    ) u_gbm (
        .clk              (clk),
        .rst_n            (rst_n),
        .z_valid          (zig_valid_out),
        .z_in             ($signed(zig_gauss_out)),
        .param_load       (1'b0),
        .mu_ito_dt_in     (32'sd0),
        .sigma_sqrt_dt_in (32'sd0),
        .sigma_init_in    (32'd0),
        .alpha_in         (32'd0),
        .p0_recip_in      (32'd0),
        .price_out        (gbm_price_out),
        .sigma_out        (gbm_sigma_out),
        .price_valid      (gbm_price_valid)
    );

    genvar g;
    generate
        for (g = 0; g < NUM_UNITS; g = g + 1) begin : gen_agent_unit

            wire        unit_wr_en;
            wire [5:0]  unit_wr_slot;
            wire [15:0] unit_param_addr;

            assign unit_wr_en   = param_wr_en && (param_wr_addr[15:SLOTS_LOG2] == g);
            assign unit_wr_slot = param_wr_addr[SLOTS_LOG2-1:0];

            reg [31:0] param_mem [0:SLOTS_PER_UNIT-1];
            reg [31:0] unit_param_data_reg;

            always @(posedge clk) begin
                if (unit_wr_en)
                    param_mem[unit_wr_slot] <= param_wr_data;
            end

            always @(posedge clk) begin
                unit_param_data_reg <= param_mem[unit_param_addr[SLOTS_LOG2-1:0]];
            end

            agent_execution_unit #(
                .NUM_AGENT_SLOTS   (SLOTS_PER_UNIT),
                .LFSR_POLY         (LFSR_POLY),
                .LFSR_SEED         (LFSR_SEED_BASE + g),
                .NEAR_NOISE_THRESH (NEAR_NOISE_THRESH)
            ) u_agent (
                .clk                 (clk),
                .rst_n               (rst_n),
                .gbm_price           (gbm_price_out),
                .last_executed_price (last_executed_price),
                .sigma               (gbm_sigma_out[15:0]),
                .trade_valid         (trade_valid),
                .param_addr          (unit_param_addr),
                .param_data          (unit_param_data_reg),
                .active_agent_count  (active_agent_count),
                .order_packet        (unit_order_packet[g*32 +: 32]),
                .order_valid         (unit_order_valid[g]),
                .order_granted       (unit_order_granted[g])
            );

        end
    endgenerate

    // Drives the boundary handshake straight from the arbiter; backpressure from order_ready
    // flows back to each agent through unit_order_granted, so the matching engine's Accept FIFO
    // is the only buffer in the chain.
    order_arbiter #(
        .NUM_UNITS (NUM_UNITS),
        .PTR_WIDTH (PTR_WIDTH)
    ) u_arbiter (
        .clk             (clk),
        .rst_n           (rst_n),
        .order_valid_in  (unit_order_valid),
        .order_packet_in (unit_order_packet),
        .order_granted   (unit_order_granted),
        .order_packet    (order_packet),
        .order_valid     (order_valid),
        .order_ready     (order_ready)
    );

endmodule
