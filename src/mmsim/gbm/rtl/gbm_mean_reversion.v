// Sequences gbm_logspace through CRASH (negative mu, theta=0) and RECOVERY (mu=0, theta>0) phases on each
// shock_trigger rising edge, leaving theta=0 at all other times so baseline GBM dynamics stay byte-identical.

module gbm_mean_reversion #(
    // Sets per-step Q8.24 signed log-space drift for the mu_ito_dt path; CRASH magnitude scales with crash depth.
    parameter signed [31:0] MU_NORMAL_DEF  = 32'sh00000000,
    parameter signed [31:0] MU_CRASH_DEF   = 32'shFFFFB7EA,
    // Sets the OU pull strength theta·dt (Q0.24); ACTIVE engages during RECOVERY, NORMAL disables outside it.
    parameter        [31:0] THETA_NORMAL_DEF = 32'h00000000,
    parameter        [31:0] THETA_ACTIVE_DEF = 32'h0003D70A,
    // Sets each phase's duration in price_valid pulses (one pulse per GBM step).
    parameter [31:0] CRASH_STEPS_DEF    = 32'd200,
    parameter [31:0] RECOVERY_STEPS_DEF = 32'd250
)(
    input  wire        clk,
    input  wire        rst_n,

    // Edge-detects shock_trigger so a held-high PIO bit fires exactly one crash+recovery sequence per rising edge.
    input  wire        shock_trigger,
    // Counts one GBM step per price_valid pulse from gbm_logspace.
    input  wire        price_valid,

    // Drives gbm_logspace's param_load alongside mu_ito_dt_in and theta_in; pulsed only at phase transitions.
    output reg         param_load,
    output reg  signed [31:0] mu_ito_dt_out,
    output reg         [31:0] theta_out,

    // Asserts high for the entire CRASH+RECOVERY duration so the UI can render a status indicator.
    output wire        shock_active
);

    localparam [1:0]
        S_IDLE     = 2'd0,
        S_CRASH    = 2'd1,
        S_RECOVERY = 2'd2;

    reg [1:0]  state;
    reg [31:0] step_cnt;
    reg        trig_prev;

    wire trig_rise = shock_trigger && !trig_prev;

    assign shock_active = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            step_cnt      <= 32'd0;
            trig_prev     <= 1'b0;
            param_load    <= 1'b0;
            mu_ito_dt_out <= MU_NORMAL_DEF;
            theta_out     <= THETA_NORMAL_DEF;
        end else begin
            trig_prev  <= shock_trigger;
            param_load <= 1'b0;  // default; pulsed only at phase transitions

            case (state)
                S_IDLE: begin
                    if (trig_rise) begin
                        mu_ito_dt_out <= MU_CRASH_DEF;
                        theta_out     <= THETA_NORMAL_DEF;
                        param_load    <= 1'b1;
                        step_cnt      <= 32'd0;
                        state         <= S_CRASH;
                    end
                end

                S_CRASH: begin
                    if (price_valid) begin
                        if (step_cnt + 32'd1 >= CRASH_STEPS_DEF) begin
                            mu_ito_dt_out <= MU_NORMAL_DEF;
                            theta_out     <= THETA_ACTIVE_DEF;
                            param_load    <= 1'b1;
                            step_cnt      <= 32'd0;
                            state         <= S_RECOVERY;
                        end else begin
                            step_cnt <= step_cnt + 32'd1;
                        end
                    end
                end

                S_RECOVERY: begin
                    if (price_valid) begin
                        if (step_cnt + 32'd1 >= RECOVERY_STEPS_DEF) begin
                            mu_ito_dt_out <= MU_NORMAL_DEF;
                            theta_out     <= THETA_NORMAL_DEF;
                            param_load    <= 1'b1;
                            state         <= S_IDLE;
                        end else begin
                            step_cnt <= step_cnt + 32'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
