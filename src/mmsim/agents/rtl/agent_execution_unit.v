// Round-robins through agent slots and emits order packets, time-multiplexing one execution unit
// across all agents.

module agent_execution_unit #(
    parameter         NUM_AGENT_SLOTS   = 64,
    parameter [31:0]  LFSR_POLY         = 32'hB4BCD35C,
    parameter [31:0]  LFSR_SEED         = 32'hCAFEBABE,
    // Sets the offset below which noise traders emit market orders.
    parameter [8:0]   NEAR_NOISE_THRESH = 9'd16,
    // Shifts a Q8.24 price right to obtain the 9-bit tick (23 yields $0.50 per tick).
    parameter integer TICK_SHIFT_BITS    = 23,
    // Caps tick at the highest valid index (price_level_store kPriceRange - 1).
    parameter [8:0]   MAX_TICK          = 9'd479
)(
    input  wire        clk,
    input  wire        rst_n,

    // Receives gbm_price and last_executed_price as Q8.24 unsigned and sigma as Q0.16 unsigned.
    input  wire [31:0] gbm_price,
    input  wire [31:0] last_executed_price,
    input  wire [15:0] sigma,

    input  wire        trade_valid,

    // param_data lags param_addr by one cycle (M10K synchronous read).
    output reg  [15:0] param_addr,
    input  wire [31:0] param_data,

    input  wire [15:0] active_agent_count,

    output reg  [31:0] order_packet,
    output reg         order_valid,

    input  wire        order_granted
);

    localparam [1:0] kStateLoad    = 2'b00;
    localparam [1:0] kStateWait    = 2'b01;
    localparam [1:0] kStateExecute = 2'b10;
    localparam [1:0] kStateEmit    = 2'b11;

    reg [1:0] state;

    // Internal LFSR
    wire [31:0] lfsr_out;
    galois_lfsr #(
        .POLY (LFSR_POLY),
        .SEED (LFSR_SEED)
    ) u_agent_lfsr (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (1'b1),
        .seed_load  (32'b0),
        .seed_valid (1'b0),
        .out        (lfsr_out)
    );


    // executed_price_shift_reg[0] = most recent, [3] = oldest
    reg [31:0] executed_price_shift_reg_0;
    reg [31:0] executed_price_shift_reg_1;
    reg [31:0] executed_price_shift_reg_2;
    reg [31:0] executed_price_shift_reg_3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            executed_price_shift_reg_0 <= 32'd0;
            executed_price_shift_reg_1 <= 32'd0;
            executed_price_shift_reg_2 <= 32'd0;
            executed_price_shift_reg_3 <= 32'd0;
        end else if (trade_valid) begin
            executed_price_shift_reg_0 <= last_executed_price;
            executed_price_shift_reg_1 <= executed_price_shift_reg_0;
            executed_price_shift_reg_2 <= executed_price_shift_reg_1;
            executed_price_shift_reg_3 <= executed_price_shift_reg_2;
        end
    end

    reg [15:0] slot_counter;

    reg [31:0] latched_params;
    reg        emit_flag;
    reg        calc_side;
    reg        calc_order_type;
    reg [15:0] calc_volume;
    reg [1:0]  calc_agent_type;

    reg [9:0]  offset_raw;
    reg [8:0]  offset_ticks;
    reg [8:0]  final_price;

    reg [9:0]  dsp_a;
    reg [9:0]  dsp_b;
    wire [19:0] dsp_product;
    assign dsp_product = dsp_a * dsp_b;

    wire [8:0] gbm_tick;
    assign gbm_tick = (gbm_price[31:TICK_SHIFT_BITS] > MAX_TICK) ? MAX_TICK : gbm_price[31:TICK_SHIFT_BITS];

    // Value Investor Combinational Logic
    wire [8:0] last_executed_tick;
    assign last_executed_tick = (last_executed_price[31:TICK_SHIFT_BITS] > MAX_TICK)
                            ? MAX_TICK : last_executed_price[31:TICK_SHIFT_BITS];

    wire signed [10:0] signed_gbm;
    wire signed [10:0] signed_exec;
    assign signed_gbm  = {2'b00, gbm_tick};
    assign signed_exec = {2'b00, last_executed_tick};

    wire signed [10:0] divergence;
    assign divergence = signed_gbm - signed_exec;

    wire [9:0] abs_div;
    assign abs_div = divergence[10]
                    ? (~divergence[9:0] + 10'd1)
                    : divergence[9:0];

    // Momentum Trader Combinational Logic
    wire [8:0] oldest_executed_tick;
    assign oldest_executed_tick = (executed_price_shift_reg_3[31:TICK_SHIFT_BITS] > MAX_TICK) ? MAX_TICK : executed_price_shift_reg_3[31:TICK_SHIFT_BITS];

    wire signed [10:0] signed_exec_3;
    assign signed_exec_3 = {2'b00, oldest_executed_tick};

    wire signed [10:0] momentum_delta;
    assign momentum_delta = signed_exec - signed_exec_3;

    wire [9:0] abs_mom;
    assign abs_mom = momentum_delta[10]
                    ? (~momentum_delta[9:0] + 10'd1)
                    : momentum_delta[9:0];

    // Combinational price assembly based on Agent Type
    always @(*) begin
        // Noise trader offset math (default)
        offset_raw   = dsp_product[19:10];
        offset_ticks = (offset_raw > {1'b0, MAX_TICK}) ? MAX_TICK : offset_raw[8:0];

        case (calc_agent_type)

            2'b00: begin  // NOISE TRADER
                if (calc_side == 1'b0)
                    final_price = (gbm_tick > offset_ticks) ? (gbm_tick - offset_ticks) : 9'd0;
                else
                    final_price = ((gbm_tick + offset_ticks) > MAX_TICK) ? MAX_TICK : (gbm_tick + offset_ticks);

                calc_order_type = (offset_ticks < NEAR_NOISE_THRESH) ? 1'b1 : 1'b0;
            end

            2'b01: begin  // MARKET MAKER
                if (calc_side == 1'b0)
                    final_price = (last_executed_tick > latched_params[18:10])
                                    ? (last_executed_tick - latched_params[18:10]) : 9'd0;
                else
                    final_price = ((last_executed_tick + latched_params[18:10]) > MAX_TICK)
                                    ? MAX_TICK : (last_executed_tick + latched_params[18:10]);
                calc_order_type = 1'b0;
            end

            2'b10: begin  // MOMENTUM TRADER
                final_price     = last_executed_tick;
                calc_order_type = 1'b1;
            end

            2'b11: begin  // VALUE INVESTOR
                final_price     = gbm_tick;
                calc_order_type = 1'b0;
            end

            default: begin
                final_price     = gbm_tick;
                calc_order_type = 1'b0;
            end
        endcase
    end

    // Main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= kStateLoad;
            slot_counter    <= 16'd0;
            param_addr      <= 16'd0;
            order_valid     <= 1'b0;
            order_packet    <= 32'd0;
            emit_flag       <= 1'b0;
            latched_params  <= 32'd0;
            calc_side       <= 1'b0;
            calc_volume     <= 16'd0;
            calc_agent_type <= 2'b00;
            dsp_a           <= 10'd0;
            dsp_b           <= 10'd0;
        end else begin

            case (state)
                // Puts the slot address on the M10K read port.
                kStateLoad: begin
                    order_valid <= 1'b0;
                    if (active_agent_count == 16'd0) begin
                        state <= kStateLoad;
                    end else begin
                        param_addr <= slot_counter;
                        state      <= kStateWait;
                    end
                end

                // Absorbs the M10K synchronous read latency.
                kStateWait: begin
                    order_valid <= 1'b0;
                    state <= kStateExecute;
                end

                // Latches params, runs agent logic, and sets up DSP inputs; product is ready in kStateEmit.
                kStateExecute: begin
                    order_valid <= 1'b0;
                    latched_params  <= param_data;
                    calc_agent_type <= param_data[31:30];
                    emit_flag       <= 1'b0;

                    case (param_data[31:30])

                        // NOISE TRADER
                        // param1 [29:20] : emission probability threshold
                        // param2 [19:10] : max price offset in ticks
                        // param3 [9:0]   : max volume cap
                        2'b00: begin
                            if (lfsr_out[9:0] < param_data[29:20]) begin
                                emit_flag   <= 1'b1;
                                calc_side   <= lfsr_out[10];
                                dsp_a       <= lfsr_out[20:11];
                                dsp_b       <= param_data[19:10];
                                calc_volume <= (({10'd0, lfsr_out[30:21]} * param_data[9:0]) >> 10) + 16'd1;
                            end else begin
                                emit_flag <= 1'b0;
                            end
                        end

                        // MARKET MAKER
                        // param1 [29:20] : emission probability threshold
                        // param2 [19:10] : half-spread in ticks
                        // param3 [9:0]   : fixed volume
                        2'b01: begin
                            if (lfsr_out[9:0] < param_data[29:20]) begin
                                emit_flag   <= 1'b1;
                                calc_side   <= lfsr_out[10];
                                calc_volume <= {6'd0, param_data[9:0]};
                            end else begin
                                emit_flag <= 1'b0;
                            end
                        end

                        // MOMENTUM TRADER
                        // param1 [29:20] : trend threshold
                        // param2 [19:10] : aggression scale
                        // param3 [9:0]   : max volume cap
                        2'b10: begin
                            if (abs_mom > param_data[29:20]) begin
                                emit_flag <= 1'b1;
                                // delta > 0 means price is rising -> Buy (0)
                                // delta < 0 means price is falling -> Sell (1)
                                calc_side <= (momentum_delta > 0) ? 1'b0 : 1'b1;

                                // Routes to the DSP for volume scaling.
                                dsp_a <= abs_mom;
                                dsp_b <= param_data[19:10];
                            end else begin
                                emit_flag <= 1'b0;
                            end
                        end

                        // VALUE INVESTOR
                        // param1 [29:20] : divergence threshold
                        // param2 [19:10] : aggression scale
                        // param3 [9:0]   : max volume cap
                        2'b11: begin
                            if (abs_div > param_data[29:20]) begin
                                emit_flag <= 1'b1;
                                // divergence > 0 means GBM > Exec (undervalued -> Buy: 0)
                                // divergence < 0 means GBM < Exec (overvalued -> Sell: 1)
                                calc_side <= (divergence > 0) ? 1'b0 : 1'b1;

                                // Routes to the DSP for volume scaling.
                                dsp_a <= abs_div;
                                dsp_b <= param_data[19:10];
                            end else begin
                                emit_flag <= 1'b0;
                            end
                        end

                        default: begin
                            emit_flag <= 1'b0;
                        end
                    endcase

                    state <= kStateEmit;
                end

                // Assembles the packet on a valid DSP product and advances the slot counter.
                kStateEmit: begin
                    if (emit_flag) begin

                        order_valid <= 1'b1;

                        // Re-drives the packet each cycle while stalled; safe since all inputs are registered.
                        case (calc_agent_type)
                            2'b00: begin
                                order_packet <= {
                                    calc_side, calc_order_type, calc_agent_type,
                                    3'b000, final_price, calc_volume
                                };
                            end
                            2'b01: begin
                                order_packet <= {
                                    calc_side, calc_order_type, calc_agent_type,
                                    3'b000, final_price, calc_volume
                                };
                            end
                            2'b10: begin
                                order_packet <= {
                                    calc_side, calc_order_type, calc_agent_type,
                                    3'b000, final_price,
                                    ((dsp_product[19:10] + 10'd1) > latched_params[9:0]) ?
                                        {6'd0, latched_params[9:0]} :
                                        ({6'd0, dsp_product[19:10]} + 16'd1)
                                };
                            end
                            2'b11: begin
                                order_packet <= {
                                    calc_side, calc_order_type, calc_agent_type,
                                    3'b000, final_price,
                                    ((dsp_product[19:10] + 10'd1) > latched_params[9:0]) ?
                                        {6'd0, latched_params[9:0]} :
                                        ({6'd0, dsp_product[19:10]} + 16'd1)
                                };
                            end
                            default: begin
                                order_packet <= 32'd0;
                            end
                        endcase

                        // Advances only on grant; last NBA wins and cleanly deasserts valid.
                        if (order_granted) begin
                            order_valid  <= 1'b0;
                            if (active_agent_count == 16'd0) begin
                                slot_counter <= 16'd0;
                            end else if (slot_counter >= active_agent_count - 16'd1) begin
                                slot_counter <= 16'd0;
                            end else begin
                                slot_counter <= slot_counter + 16'd1;
                            end
                            state <= kStateLoad;
                        end

                    end else begin
                        // No emission: deasserts valid and advances immediately.
                        order_valid <= 1'b0;
                        if (active_agent_count == 16'd0) begin
                            slot_counter <= 16'd0;
                        end else if (slot_counter >= active_agent_count - 16'd1) begin
                            slot_counter <= 16'd0;
                        end else begin
                            slot_counter <= slot_counter + 16'd1;
                        end
                        state <= kStateLoad;
                    end
                end
                default: state <= kStateLoad;
            endcase
        end
    end

endmodule
