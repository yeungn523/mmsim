// =============================================================================
// gbm_euler.v - GBM Price Pipeline: Euler-Maruyama
// =============================================================================

module gbm_euler #(
    parameter PRICE_WIDTH  = 32,
    parameter SIGMA_WIDTH  = 32,
    parameter Z_WIDTH      = 16,
    parameter PRICE_FRAC   = 24,
    parameter SIGMA_FRAC   = 24,
    parameter Z_FRAC       = 12,

    parameter [31:0] PRICE_MIN = 32'h00000001,
    parameter [31:0] PRICE_MAX = 32'hFFFFFFFF,

    // Constants
    parameter signed [31:0] MU_ITO_FP_DEF  = 32'sh00000000,
    parameter        [31:0] SIGMA_INIT_DEF = 32'h00000451,
    parameter        [31:0] ALPHA_FP_DEF   = 32'h00FD70A4,
    parameter        [31:0] P0_RECIP_DEF   = 32'h00028F5C,
    parameter        [31:0] P0_INIT_DEF    = 32'h64000000
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        z_valid,
    input  wire signed [Z_WIDTH-1:0] z_in,

    input  wire        param_load,
    input  wire signed [31:0] mu_ito_in,
    input  wire        [31:0] sigma_init_in,
    input  wire        [31:0] alpha_in,
    input  wire        [31:0] p0_recip_in,

    output reg  [PRICE_WIDTH-1:0] price_out,
    output reg  [SIGMA_WIDTH-1:0] sigma_out,
    output reg                    price_valid
);

    // FSM States
    localparam [3:0]
        S_IDLE      = 4'd0,
        S_LATCH     = 4'd1,
        S_DRIFT_MUL = 4'd2,
        S_DRIFT_SHF = 4'd3,
        S_PSIG_MUL  = 4'd4,
        S_PSIG_SHF  = 4'd5,
        S_DIFF_MUL  = 4'd6,
        S_DIFF_SHF  = 4'd7,
        S_DIFF_ADD  = 4'd8,
        S_SIGMA_A   = 4'd9,
        S_SIGMA_B   = 4'd10,
        S_SIGMA_C   = 4'd11,
        S_SIGMA_D   = 4'd12,
        S_SIGMA_E   = 4'd13,
        S_SIGMA_F   = 4'd14;

    reg [3:0] state;

    // Registers
    reg signed [31:0] mu_ito_reg;
    reg        [31:0] sigma_init_reg, alpha_reg, one_m_alpha_reg, p0_recip_reg;
    reg        [31:0] P_reg, sigma_reg;

    // Pipeline Registers
    reg signed [15:0] z_latch;
    reg signed [63:0] drift_full, diff_full;
    reg signed [31:0] drift, diffusion;
    reg        [63:0] P_sigma_full, abs_ret_full, alpha_full, one_m_alpha_full;
    reg        [31:0] P_sigma, P_new, delta_P, abs_ret_norm, alpha_sigma, abs_ret_scaled, one_m_alpha_ret;
    reg signed [33:0] P_sum;
    reg        [32:0] sigma_sum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mu_ito_reg      <= MU_ITO_FP_DEF;
            sigma_init_reg  <= SIGMA_INIT_DEF;
            alpha_reg       <= ALPHA_FP_DEF;
            one_m_alpha_reg <= (1 << SIGMA_FRAC) - ALPHA_FP_DEF;
            p0_recip_reg    <= P0_RECIP_DEF;
        end else if (param_load) begin
            mu_ito_reg      <= mu_ito_in;
            sigma_init_reg  <= sigma_init_in;
            alpha_reg       <= alpha_in;
            one_m_alpha_reg <= (1 << SIGMA_FRAC) - alpha_in;
            p0_recip_reg    <= p0_recip_in;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            price_valid       <= 1'b0;
            price_out         <= P0_INIT_DEF;
            sigma_out         <= SIGMA_INIT_DEF;
            P_reg             <= P0_INIT_DEF;
            sigma_reg         <= SIGMA_INIT_DEF;
            z_latch           <= 16'sd0;
            drift_full        <= 64'sd0;
            drift             <= 32'sd0;
            P_sigma_full      <= 64'd0;
            P_sigma           <= 32'd0;
            diff_full         <= 64'sd0;
            diffusion         <= 32'sd0;
            P_sum             <= 34'sd0;
            P_new             <= P0_INIT_DEF;
            delta_P           <= 32'd0;
            abs_ret_full      <= 64'd0;
            alpha_full        <= 64'd0;
            abs_ret_norm      <= 32'd0;
            alpha_sigma       <= 32'd0;
            abs_ret_scaled    <= 32'd0;
            one_m_alpha_full  <= 64'd0;
            one_m_alpha_ret   <= 32'd0;
            sigma_sum         <= 33'd0;
        end else begin
            price_valid <= 1'b0;

            case (state)
                S_IDLE: if (z_valid) begin
                    z_latch <= z_in;
                    state   <= S_LATCH;
                end

                S_LATCH: begin
                    drift_full <= $signed({1'b0, P_reg}) * $signed(mu_ito_reg);
                    state      <= S_DRIFT_MUL;
                end

                S_DRIFT_MUL: begin
                    drift <= ($signed(drift_full) + 64'sh800000) >>> 24;
                    P_sigma_full <= P_reg * sigma_reg;
                    state <= S_DRIFT_SHF;
                end

                S_DRIFT_SHF: begin
                    P_sigma <= (P_sigma_full + 64'd8388608) >> 24;
                    state   <= S_PSIG_MUL;
                end

                S_PSIG_MUL: begin
                    diff_full <= $signed({1'b0, P_sigma}) * $signed(z_latch);
                    state     <= S_PSIG_SHF;
                end

                S_PSIG_SHF: begin
                    diffusion <= ($signed(diff_full) + 48'sh800) >>> 12;
                    state     <= S_DIFF_MUL;
                end

                S_DIFF_MUL: begin
                    P_sum <= $signed({2'b00, P_reg})
                           + $signed({{2{drift[31]}},     drift})
                           + $signed({{2{diffusion[31]}}, diffusion});
                    state <= S_DIFF_SHF;
                end

                S_DIFF_SHF: begin
                    if (P_sum[33])
                        P_new <= PRICE_MIN;
                    else if (P_sum[32])
                        P_new <= PRICE_MAX;
                    else if (P_sum[31:0] < PRICE_MIN)
                        P_new <= PRICE_MIN;
                    else
                        P_new <= P_sum[31:0];
                    state <= S_DIFF_ADD;
                end

                S_DIFF_ADD: begin
                    delta_P <= (P_new >= P_reg) ? (P_new - P_reg) : (P_reg - P_new);
                    alpha_full <= alpha_reg * sigma_reg;
                    state <= S_SIGMA_A;
                end

                S_SIGMA_A: begin
                    abs_ret_full <= delta_P * p0_recip_reg;
                    state <= S_SIGMA_B;
                end

                S_SIGMA_B: begin
                    abs_ret_norm <= (abs_ret_full + 64'd8388608) >> 24;
                    alpha_sigma  <= (alpha_full   + 64'd8388608) >> 24;
                    state        <= S_SIGMA_C;
                end

                S_SIGMA_C: begin
                    abs_ret_scaled <= abs_ret_norm + (abs_ret_norm >> 2);
                    state          <= S_SIGMA_D;
                end

                S_SIGMA_D: begin
                    one_m_alpha_full <= one_m_alpha_reg * abs_ret_scaled;
                    state            <= S_SIGMA_E;
                end

                S_SIGMA_E: begin
                    one_m_alpha_ret <= (one_m_alpha_full + 64'd8388608) >> 24;
                    state           <= S_SIGMA_F;
                end

                S_SIGMA_F: begin
                    sigma_sum <= {1'b0, alpha_sigma} + {1'b0, one_m_alpha_ret};

                    if (({1'b0, alpha_sigma} + {1'b0, one_m_alpha_ret}) < {1'b0, sigma_init_reg}) begin
                        sigma_reg <= sigma_init_reg;
                        sigma_out <= sigma_init_reg;
                    end else if (alpha_sigma[31] & one_m_alpha_ret[31]) begin
                        sigma_reg <= {32{1'b1}};
                        sigma_out <= {32{1'b1}};
                    end else begin
                        sigma_reg <= alpha_sigma + one_m_alpha_ret;
                        sigma_out <= alpha_sigma + one_m_alpha_ret;
                    end

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