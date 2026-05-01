///
/// @file order_gen_top.v
/// @brief Top-level order generation subsystem composing the GBM source, agent units, and the round-robin arbiter.
///
module order_gen_top #(
    parameter NUM_UNITS       = 16,
    parameter PTR_WIDTH       = 4,                               ///< log2(NUM_UNITS)
    parameter SLOTS_PER_UNIT  = 1024,
    parameter FIFO_DEPTH      = 256,
    parameter signed [31:0] GBM_MU_ITO_DT     = 32'sh00000000,
    parameter signed [31:0] GBM_SIGMA_SQRT_DT = 32'sh00000451,
    parameter        [31:0] GBM_SIGMA_INIT    = 32'h00000451,
    parameter        [31:0] GBM_ALPHA         = 32'h00FD70A4,
    parameter        [31:0] GBM_P0_RECIP      = 32'h00028F5C,
    parameter [31:0] LFSR_SEED_BASE    = 32'hCAFEBABE,
    parameter [31:0] LFSR_POLY         = 32'hB4BCD35C,
    parameter [8:0]  NEAR_NOISE_THRESH = 9'd16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] last_executed_price,
    input  wire        trade_valid,
    input  wire [15:0] active_agent_count,
    output wire [31:0] order_packet,
    output wire        order_valid,
    input  wire        order_ready,

    // Flash injection
    input  wire [31:0] inject_packet,
    input  wire        inject_trigger,
    input  wire [31:0] inject_count,
    output wire        inject_active,

    // External param memory ports — read-only from FPGA side.
    // HPS writes directly via Qsys AXI bridge, FPGA only reads.
    output wire [NUM_UNITS*10-1:0]  param_rd_addr,  ///< Read address per unit (10 bits each)
    input  wire [NUM_UNITS*32-1:0]  param_rd_data   ///< Read data per unit (32 bits each)
);
    localparam SLOTS_LOG2 = 10;  // log2(1024)

    wire [15:0] zig_gauss_out;
    wire        zig_valid_out;
    wire [31:0] gbm_price_out;
    wire [31:0] gbm_sigma_out;
    wire        gbm_price_valid;

    wire [NUM_UNITS-1:0]    unit_order_valid;
    wire [NUM_UNITS*32-1:0] unit_order_packet;
    wire [NUM_UNITS-1:0]    unit_order_granted;

    wire [31:0] arb_packet;
    wire        arb_valid;
    wire        arb_ready;
    wire        fifo_full;
    wire        fifo_almost_full;
    wire        fifo_empty;
    wire [31:0] fifo_dout;

    // Flash injection FSM
    reg [31:0]  inject_remaining;
    reg         inject_busy;
    reg [31:0]  inject_packet_reg;
    reg         inject_trigger_prev;
    wire inject_trigger_rise = inject_trigger && !inject_trigger_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inject_remaining    <= 32'd0;
            inject_busy         <= 1'b0;
            inject_packet_reg   <= 32'd0;
            inject_trigger_prev <= 1'b0;
        end else begin
            inject_trigger_prev <= inject_trigger;
            if (inject_trigger_rise && !inject_busy) begin
                inject_busy       <= 1'b1;
                inject_remaining  <= inject_count;
                inject_packet_reg <= inject_packet;
            end else if (inject_busy && order_ready) begin
                if (inject_remaining <= 32'd1) begin
                    inject_busy      <= 1'b0;
                    inject_remaining <= 32'd0;
                end else begin
                    inject_remaining <= inject_remaining - 32'd1;
                end
            end
        end
    end

    assign inject_active = inject_busy;

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

            wire [15:0] unit_param_addr;

            // Route agent read address out to the flattened external port.
            // Qsys on-chip memory s2 port drives param_rd_data back in.
            assign param_rd_addr[g*10 +: 10] = unit_param_addr[SLOTS_LOG2-1:0];

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
                .param_data          (param_rd_data[g*32 +: 32]),
                .active_agent_count  (active_agent_count),
                .order_packet        (unit_order_packet[g*32 +: 32]),
                .order_valid         (unit_order_valid[g]),
                .order_granted       (unit_order_granted[g])
            );
        end
    endgenerate

    order_arbiter #(
        .NUM_UNITS (NUM_UNITS),
        .PTR_WIDTH (PTR_WIDTH)
    ) u_arbiter (
        .clk             (clk),
        .rst_n           (rst_n),
        .order_valid_in  (unit_order_valid),
        .order_packet_in (unit_order_packet),
        .order_granted   (unit_order_granted),
        .order_packet    (arb_packet),
        .order_valid     (arb_valid),
        .order_ready     (arb_ready)
    );

    assign arb_ready = !fifo_almost_full && !fifo_full;

    assign order_valid  = inject_busy ? 1'b1              : !fifo_empty;
    assign order_packet = inject_busy ? inject_packet_reg : fifo_dout;

    order_fifo #(
        .DATA_WIDTH          (32),
        .DEPTH               (FIFO_DEPTH),
        .ALMOST_FULL_THRESH  (16)
    ) u_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (arb_valid && arb_ready),
        .din         (arb_packet),
        .full        (fifo_full),
        .almost_full (fifo_almost_full),
        .rd_en       (!inject_busy && !fifo_empty && order_ready),
        .dout        (fifo_dout),
        .empty       (fifo_empty)
    );

endmodule
