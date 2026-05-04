// Composes the GBM source, agent units, and arbiter into the top-level order generation subsystem.

module order_gen_top #(
    parameter NUM_UNITS       = 16,
    parameter PTR_WIDTH       = 4,                               // log2(NUM_UNITS)
    parameter SLOTS_PER_UNIT  = 1024,
    parameter FIFO_DEPTH      = 256,
    parameter signed [31:0] GBM_MU_ITO_DT     = 32'sh00000000,
	 parameter signed [31:0] GBM_SIGMA_SQRT_DT = 32'sh00000008,
	 parameter        [31:0] GBM_SIGMA_INIT    = 32'h00000100,
    parameter        [31:0] GBM_ALPHA         = 32'h00FD70A4,
    parameter        [31:0] GBM_P0_RECIP      = 32'h00028F5C,
    parameter [31:0] LFSR_SEED_BASE    = 32'hCAFEBABE,
    parameter [31:0] LFSR_POLY         = 32'hB4BCD35C,
    parameter [8:0]  NEAR_NOISE_THRESH = 9'd5,
    // Initial GBM price held to agents when gbm_enable is low; must match
    // matching_engine kInitialPrice and GBM_P0_RECIP to avoid divergence on startup.
    parameter [31:0] GBM_P0_HELD       = 32'h64000000   // tick 200 in Q8.24
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        gbm_enable,       // gates GBM price output to agents; held at GBM_P0_HELD when low
    input  wire [31:0] last_executed_price,
    input  wire        trade_valid,
    input  wire [15:0] active_agent_count,
	 input  wire [31:0] gbm_step_period,
	 input  wire [31:0] agent_step_period,
    output wire [31:0] price_out,
    output wire [31:0] order_packet,
    output wire        order_valid,
    input  wire        order_ready,

    // Flash injection
    input  wire [31:0] inject_packet,
    input  wire        inject_trigger,
    input  wire [31:0] inject_count,
    output wire        inject_active,

    // Exposes external param memory read-only to the FPGA; HPS writes via the Qsys AXI bridge.
    output wire [NUM_UNITS*10-1:0]  param_rd_addr,
    input  wire [NUM_UNITS*32-1:0]  param_rd_data
);
    localparam SLOTS_LOG2 = 10;  // log2(1024)

    wire [15:0] zig_gauss_out;
    wire        zig_valid_out;
    wire [31:0] gbm_price_out;
    wire [31:0] gbm_sigma_out;
    wire        gbm_price_valid;

    // Gates GBM price to agents — holds at tick 200 until gbm_enable asserted.
    // Ziggurat always runs so it has valid outputs ready the moment enable goes high;
    // GBM steps internally but agents see exactly GBM_P0_HELD until enabled.
    wire [31:0] gbm_price_gated = gbm_enable ? gbm_price_out : GBM_P0_HELD;

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
	 
	 reg [31:0] gbm_throttle_counter;
    wire       gbm_step_en = (gbm_throttle_counter >= gbm_step_period);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            gbm_throttle_counter <= 32'd0;
        else if (gbm_step_en)
            gbm_throttle_counter <= 32'd0;
        else
            gbm_throttle_counter <= gbm_throttle_counter + 32'd1;
    end
    wire z_valid_gated = zig_valid_out && gbm_step_en;

    // Ziggurat always enabled so it stays warm and produces valid Gaussian samples
    // immediately when gbm_enable goes high; gating en instead would cause a pipeline
    // bubble on the first enable cycle and agents would see gbm_price=0 transiently.
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
        .z_valid          (zig_valid_gated),
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

            // Routes agent read address to the flattened external port; Qsys s2 drives data back.
            assign param_rd_addr[g*10 +: 10] = unit_param_addr[SLOTS_LOG2-1:0];

            agent_execution_unit #(
                .NUM_AGENT_SLOTS   (SLOTS_PER_UNIT),
                .LFSR_POLY         (LFSR_POLY),
                .LFSR_SEED         (LFSR_SEED_BASE + g),
                .NEAR_NOISE_THRESH (NEAR_NOISE_THRESH)
            ) u_agent (
                .clk                 (clk),
                .rst_n               (rst_n),
                // Uses gated price so agents see exactly tick 200 until gbm_enable
                // asserted, preventing value investor divergence on startup.
                .gbm_price           (gbm_price_gated),
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

    // Agent throttle — token-based rate limiter on matching engine consumption.
    // Generates one token every agent_step_period cycles; token held until
    // matching engine accepts the order, preventing dropped orders.
    reg [31:0] agent_throttle_counter;
    wire       agent_step_en = (agent_throttle_counter >= agent_step_period);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            agent_throttle_counter <= 32'd0;
        else if (agent_step_en)
            agent_throttle_counter <= 32'd0;
        else
            agent_throttle_counter <= agent_throttle_counter + 32'd1;
    end

    reg agent_throttle_allow;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            agent_throttle_allow <= 1'b0;
        else if (agent_step_en)
            agent_throttle_allow <= 1'b1;
        else if (!inject_busy && !fifo_empty && agent_throttle_allow && order_ready)
            agent_throttle_allow <= 1'b0;
    end

    assign order_valid  = inject_busy ? 1'b1 : (!fifo_empty && agent_throttle_allow);
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
        .rd_en       (!inject_busy && !fifo_empty && agent_throttle_allow && order_ready),
        .dout        (fifo_dout),
        .empty       (fifo_empty)
    );
	 
	 assign price_out = gbm_price_gated;

endmodule
