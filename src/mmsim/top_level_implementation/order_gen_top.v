// order_gen_top.v
// Top-level order generation subsystem 


module order_gen_top #(
    // Structural parameters
    parameter NUM_UNITS       = 4,           // must be power of 2
    parameter PTR_WIDTH       = 2,            // log2(NUM_UNITS)
    parameter SLOTS_PER_UNIT  = 64,           // M10K slots per agent unit
    parameter FIFO_DEPTH      = 256,
    parameter FIFO_AF_THRESH  = 16,

    // GBM parameters 
    parameter signed [31:0] GBM_MU_ITO_DT      = 32'sh00000000,  // zero drift
    parameter signed [31:0] GBM_SIGMA_SQRT_DT   = 32'sh00000451,  // ~0.001 vol step
    parameter        [31:0] GBM_SIGMA_INIT       = 32'h00000451,
    parameter        [31:0] GBM_ALPHA            = 32'h00FD70A4,
    parameter        [31:0] GBM_P0_RECIP         = 32'h00028F5C,

    // Agent execution unit parameters
    parameter [31:0] LFSR_SEED_BASE   = 32'hCAFEBABE,  // unit i gets SEED_BASE + i
    parameter [31:0] LFSR_POLY        = 32'hB4BCD35C,
    parameter [8:0]  NEAR_NOISE_THRESH = 9'd16
)(
    input  wire        clk,
    input  wire        rst_n,

    // From matching engine
    input  wire [31:0] last_exec_price,   // Q8.24, registered on matching engine side
    input  wire        trade_valid,       // pulse on each execution

    // HPS runtime controls
    input  wire [15:0] active_agent_count,

    // M10K parameter table write port
    // addr[15:PTR_WIDTH+log2(SLOTS)] selects unit,
    // addr[SLOTS_PER_UNIT_LOG2-1:0] selects slot within unit
    // Specifically: addr[15:6] = unit index, addr[5:0] = slot (for 64 slots)
    input  wire        param_wr_en,
    input  wire [15:0] param_wr_addr,
    input  wire [31:0] param_wr_data,

    // FIFO read port
    input  wire        fifo_rd_en,
    output wire [31:0] fifo_dout,
    output wire        fifo_empty
);

    localparam SLOTS_LOG2 = 6;  // log2(64) — adjust if SLOTS_PER_UNIT changes

    wire [15:0] zig_gauss_out;
    wire        zig_valid_out;

    ziggurat_gaussian u_ziggurat (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (1'b1),
        // Seeds hardcoded 
        .seed0      (32'hDEADBEEF),
        .seed1      (32'hCAFEBABE),
        .seed2      (32'h12345678),
        .seed3      (32'hABCDEF01),
        .seed_valid (1'b0),
        .gauss_out  (zig_gauss_out),
        .valid_out  (zig_valid_out)
    );

    // GBM 
    wire [31:0] gbm_price_out;
    wire [31:0] gbm_sigma_out;
    wire        gbm_price_valid;

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
        // param_load tied off 
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

    wire [NUM_UNITS-1:0]     unit_order_valid;
    wire [NUM_UNITS*32-1:0]  unit_order_packet;
    wire [NUM_UNITS-1:0]     unit_order_granted;

    // Generate: NUM_UNITS agent_execution_unit instances
    genvar g;
    generate
        for (g = 0; g < NUM_UNITS; g = g + 1) begin : gen_agent_unit

            // Write port: HPS via param_wr_* (gated by unit select)
            // Read port:  agent_execution_unit param_addr/param_data
            wire        unit_wr_en;
            wire [5:0]  unit_wr_slot;   
            wire [15:0] unit_param_addr;

            assign unit_wr_en = param_wr_en &&
                                (param_wr_addr[15:SLOTS_LOG2] == g);
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
                .clk               (clk),
                .rst_n             (rst_n),
                .gbm_price         (gbm_price_out),
                .last_exec_price   (last_exec_price),
                .sigma             (gbm_sigma_out[15:0]),
                .trade_valid       (trade_valid),
                .param_addr        (unit_param_addr),
                .param_data        (unit_param_data_reg),
                .active_agent_count(active_agent_count),
                .order_packet      (unit_order_packet[g*32 +: 32]),
                .order_valid       (unit_order_valid[g]),
                .order_granted     (unit_order_granted[g])
            );

        end
    endgenerate

    wire fifo_almost_full;
    wire fifo_full;

    // Order arbiter
    wire        arb_fifo_wr_en;
    wire [31:0] arb_fifo_din;

    order_arbiter #(
        .NUM_UNITS (NUM_UNITS),
        .PTR_WIDTH (PTR_WIDTH)
    ) u_arbiter (
        .clk              (clk),
        .rst_n            (rst_n),
        .order_valid_in   (unit_order_valid),
        .order_packet_in  (unit_order_packet),
        .order_granted    (unit_order_granted),
        .fifo_wr_en       (arb_fifo_wr_en),
        .fifo_din         (arb_fifo_din),
        .fifo_almost_full (fifo_almost_full),
        .fifo_full        (fifo_full)
    );

    // Output FIFO
    order_fifo #(
        .DATA_WIDTH         (32),
        .DEPTH              (FIFO_DEPTH),
        .ALMOST_FULL_THRESH (FIFO_AF_THRESH)
    ) u_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (arb_fifo_wr_en),
        .din         (arb_fifo_din),
        .full        (fifo_full),
        .almost_full (fifo_almost_full),
        .rd_en       (fifo_rd_en),
        .dout        (fifo_dout),
        .empty       (fifo_empty)
    );

endmodule