///
/// @file gbm_logspace.v
/// @brief Geometric Brownian Motion price pipeline using log-space accumulation and an exp LUT.
///

module gbm_logspace #(
    parameter PRICE_WIDTH  = 32,                         ///< Bit width of the output price.
    parameter SIGMA_WIDTH  = 32,                         ///< Bit width of the output sigma.
    parameter Z_WIDTH      = 16,                         ///< Bit width of the input Gaussian sample.
    parameter L_FRAC       = 24,                         ///< Fractional bits of the log-price register.
    parameter SIGMA_FRAC   = 24,                         ///< Fractional bits of the sigma register.
    parameter Z_FRAC       = 12,                         ///< Fractional bits of the Gaussian sample.

    parameter signed [31:0] L_MIN_FIXED  = 32'sh00000000,    ///< Lower bound of the log-price LUT range.
    parameter signed [31:0] L_MAX_FIXED  = 32'sh058B6E14,    ///< Upper bound of the log-price LUT range.
    parameter        [31:0] L_STEP_FIXED = 32'h00002C5C,     ///< LUT step size in log-price units.
    parameter        [31:0] L_STEP_RECIP = 32'hB8AC68F6,     ///< Reciprocal of the LUT step for address scaling.

    parameter [31:0] PRICE_MIN = 32'h00000001,           ///< Minimum representable price clamp.
    parameter [31:0] PRICE_MAX = 32'hFFFFFFFF,           ///< Maximum representable price clamp.

    parameter signed [31:0] MU_ITO_DT_DEF     = 32'sh00000000,   ///< Default Ito-corrected drift per step.
    parameter signed [31:0] SIGMA_SQRT_DT_DEF = 32'sh00000451,   ///< Default sigma * sqrt(dt) coefficient.
    parameter        [31:0] SIGMA_INIT_DEF    = 32'h00000451,    ///< Default initial sigma estimate.
    parameter        [31:0] ALPHA_FP_DEF      = 32'h00FD70A4,    ///< Default EWMA smoothing factor.
    parameter        [31:0] P0_RECIP_DEF      = 32'h00028F5C,    ///< Default reciprocal of the reference price.
    parameter signed [31:0] L0_DEF            = 32'sh049AEC6F    ///< Default initial log-price.
)(
    input  wire        clk,                              ///< System clock.
    input  wire        rst_n,                            ///< Active-low asynchronous reset.

    input  wire        z_valid,                          ///< Pulses one cycle to inject a new Gaussian sample.
    input  wire signed [Z_WIDTH-1:0] z_in,               ///< Signed Gaussian sample driving the diffusion term.

    input  wire        param_load,                       ///< Loads runtime parameter overrides on a single-cycle pulse.
    input  wire signed [31:0] mu_ito_dt_in,              ///< Runtime override for MU_ITO_DT_DEF.
    input  wire signed [31:0] sigma_sqrt_dt_in,          ///< Runtime override for SIGMA_SQRT_DT_DEF.
    input  wire        [31:0] sigma_init_in,             ///< Runtime override for SIGMA_INIT_DEF.
    input  wire        [31:0] alpha_in,                  ///< Runtime override for ALPHA_FP_DEF.
    input  wire        [31:0] p0_recip_in,               ///< Runtime override for P0_RECIP_DEF.

    output reg  [PRICE_WIDTH-1:0] price_out,             ///< Latest GBM price (Q8.24 unsigned).
    output reg  [SIGMA_WIDTH-1:0] sigma_out,             ///< Latest sigma estimate (Q0.24 unsigned).
    output reg                    price_valid           ///< Pulses one cycle when price_out is valid.
);

    localparam [3:0]
        S_IDLE      = 4'd0,
        S_LATCH     = 4'd1,
        S_DIFF_MUL  = 4'd2,
        S_DIFF_SHF  = 4'd3,
        S_L_UPDATE  = 4'd4,
        S_LUT_ADDR  = 4'd5,
        S_LUT_RD    = 4'd6,
        S_PRICE_OUT = 4'd7,
        S_SIGMA_A   = 4'd8,
        S_SIGMA_B   = 4'd9,
        S_SIGMA_C   = 4'd10,
        S_SIGMA_D   = 4'd11,
        S_SIGMA_E   = 4'd12;

    reg [3:0] state;

    // Runtime registers
    reg signed [31:0] mu_ito_dt_reg;
    reg signed [31:0] sigma_sqrt_dt_reg;
    reg        [31:0] sigma_init_reg;
    reg        [31:0] alpha_reg;
    reg        [31:0] one_m_alpha_reg;
    reg        [31:0] p0_recip_reg;

    // Persistent state
    reg signed [31:0] L_reg;
    reg        [31:0] P_reg;
    reg        [31:0] sigma_reg;

    // Pipeline registers
    reg signed [15:0]  z_latch;
    reg signed [63:0]  diff_full;
    reg signed [31:0]  diffusion;
    reg signed [31:0]  L_new;
    reg        [12:0]  lut_addr;
    wire       [31:0]  lut_data;
    reg        [31:0]  P_new;
    reg        [31:0]  delta_P;
    reg        [63:0]  abs_ret_full;
    reg        [63:0]  alpha_full;
    reg        [31:0]  abs_ret_norm;
    reg        [31:0]  alpha_sigma;
    wire       [31:0]  abs_ret_scaled;
    reg        [63:0]  one_m_alpha_full;
    reg        [31:0]  one_m_alpha_ret;
    wire       [32:0]  sigma_sum;

    assign abs_ret_scaled = abs_ret_norm + (abs_ret_norm >> 2);
    assign sigma_sum      = {1'b0, alpha_sigma} + {1'b0, one_m_alpha_ret};

    wire signed [31:0] L_offset_wire;
    assign L_offset_wire  = L_new - $signed(L_MIN_FIXED);

    wire [63:0] addr_full_wire;
    wire [63:0] addr_mult_wire;
    assign addr_mult_wire = {32'd0, L_offset_wire} * {32'd0, L_STEP_RECIP};
    assign addr_full_wire = ($signed(L_offset_wire) > 32'sh0) ? addr_mult_wire : 64'd0;

    wire signed [33:0] L_sum_wire;
    assign L_sum_wire = $signed({{2{L_reg[31]}}, L_reg})
                      + $signed({{2{mu_ito_dt_reg[31]}}, mu_ito_dt_reg})
                      + $signed({{2{diffusion[31]}}, diffusion});

    // M10K ROM
    `ifdef SYNTHESIS
        altsyncram #(
            .operation_mode  ("ROM"),
            .width_a         (32),
            .widthad_a       (13),
            .numwords_a      (8192),
            .outdata_reg_a   ("UNREGISTERED"),
            .init_file       ("lut/exp_lut.mif"),
            .lpm_hint        ("ENABLE_RUNTIME_MOD=NO"),
            .lpm_type        ("altsyncram")
        ) exp_rom (
            .clock0     (clk),
            .address_a  (lut_addr),
            .q_a        (lut_data)
        );
    `else
        `include "lut/exp_lut.vh"
        reg [31:0] lut_data_sim;
        assign lut_data = lut_data_sim;
        always @(posedge clk) begin
            lut_data_sim <= exp_lut_lookup(lut_addr);
        end
    `endif

    // Parameter Load
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mu_ito_dt_reg     <= MU_ITO_DT_DEF;
            sigma_sqrt_dt_reg <= SIGMA_SQRT_DT_DEF;
            sigma_init_reg    <= SIGMA_INIT_DEF;
            alpha_reg         <= ALPHA_FP_DEF;
            one_m_alpha_reg   <= (1 << SIGMA_FRAC) - ALPHA_FP_DEF;
            p0_recip_reg      <= P0_RECIP_DEF;
        end else if (param_load) begin
            mu_ito_dt_reg     <= mu_ito_dt_in;
            sigma_sqrt_dt_reg <= sigma_sqrt_dt_in;
            sigma_init_reg    <= sigma_init_in;
            alpha_reg         <= alpha_in;
            one_m_alpha_reg   <= (1 << SIGMA_FRAC) - alpha_in;
            p0_recip_reg      <= p0_recip_in;
        end
    end

    // Pipeline Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            price_valid       <= 1'b0;
            price_out         <= 32'h64000000;
            sigma_out         <= SIGMA_INIT_DEF;
            L_reg             <= 32'sh049AEC6F;
            P_reg             <= 32'h64000000;
            sigma_reg         <= SIGMA_INIT_DEF;
            z_latch           <= 16'sd0;
            diff_full         <= 64'sd0;
            diffusion         <= 32'sd0;
            L_new             <= 32'sh049AEC6F;
            lut_addr          <= 13'd0;
            P_new             <= 32'h64000000;
            delta_P           <= 32'd0;
            abs_ret_full      <= 64'd0;
            alpha_full        <= 64'd0;
            abs_ret_norm      <= 32'd0;
            alpha_sigma       <= 32'd0;
            one_m_alpha_full  <= 64'd0;
            one_m_alpha_ret   <= 32'd0;
        end else begin
            price_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (z_valid) begin
                        z_latch <= z_in;
                        state   <= S_LATCH;
                    end
                end

                S_LATCH: begin
                    diff_full <= $signed(sigma_sqrt_dt_reg) * $signed(z_latch);
                    state     <= S_DIFF_MUL;
                end

                S_DIFF_MUL: begin
                    diffusion <= ($signed(diff_full) + 64'sh800) >>> 12;
                    state     <= S_DIFF_SHF;
                end

                S_DIFF_SHF: begin
                    if ($signed(L_sum_wire) < $signed({{2{L_MIN_FIXED[31]}}, L_MIN_FIXED}))
                        L_new <= L_MIN_FIXED;
                    else if ($signed(L_sum_wire) > $signed({{2{L_MAX_FIXED[31]}}, L_MAX_FIXED}))
                        L_new <= L_MAX_FIXED;
                    else
                        L_new <= L_sum_wire[31:0];
                    state <= S_L_UPDATE;
                end

                S_L_UPDATE: begin
                    if ($signed(L_offset_wire) <= 32'sh0)
                        lut_addr <= 13'd0;
                    else if (|addr_full_wire[63:58])
                        lut_addr <= 13'd8191;
                    else
                        lut_addr <= addr_full_wire[57:45];
                    state <= S_LUT_ADDR;
                end

                S_LUT_ADDR: state <= S_LUT_RD;

                S_LUT_RD: begin
                    P_new <= lut_data;
                    state <= S_PRICE_OUT;
                end

                S_PRICE_OUT: begin
                    delta_P    <= (P_new >= P_reg) ? (P_new - P_reg) : (P_reg - P_new);
                    alpha_full <= alpha_reg * sigma_reg;
                    state      <= S_SIGMA_A;
                end

                S_SIGMA_A: begin
                    abs_ret_full <= delta_P * p0_recip_reg;
                    state        <= S_SIGMA_B;
                end

                S_SIGMA_B: begin
                    abs_ret_norm   <= (abs_ret_full + 64'd8388608) >> 24;
                    alpha_sigma    <= (alpha_full   + 64'd8388608) >> 24;
                    state          <= S_SIGMA_C;
                end

                S_SIGMA_C: begin
                    one_m_alpha_full <= one_m_alpha_reg * abs_ret_scaled;
                    state            <= S_SIGMA_D;
                end

                S_SIGMA_D: begin
                    one_m_alpha_ret <= (one_m_alpha_full + 64'd8388608) >> 24;
                    state           <= S_SIGMA_E;
                end

                S_SIGMA_E: begin
                    if (sigma_sum < {1'b0, sigma_init_reg}) begin
                        sigma_reg <= sigma_init_reg;
                        sigma_out <= sigma_init_reg;
                    end else if (sigma_sum[32]) begin
                        sigma_reg <= {32{1'b1}};
                        sigma_out <= {32{1'b1}};
                    end else begin
                        sigma_reg <= sigma_sum[31:0];
                        sigma_out <= sigma_sum[31:0];
                    end

                    L_reg       <= L_new;
                    P_reg       <= P_new;
                    price_out   <= P_new;
                    price_valid <= 1'b1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
