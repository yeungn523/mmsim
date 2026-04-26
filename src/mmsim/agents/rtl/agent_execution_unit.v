`timescale 1ns/1ns

///
/// @file agent_execution_unit.v
/// @brief Time-multiplexed agent execution unit that round-robins through agent slots and emits
///        order packets into the matching engine's Accept FIFO.

/// Order packet layout (must match matching_engine.v):
///   bit  [31]       side        (0 = buy, 1 = sell)
///   bit  [30]       order_type  (0 = limit, 1 = market)
///   bits [29:28]    agent_type  (00 = noise, 01 = mm, 10 = momentum, 11 = value)
///   bits [27:25]    reserved    (driven to zero)
///   bits [24:16]    price       (9-bit tick index, 0..479, direct LOB address)
///   bits [15:0]     volume      (16-bit unsigned share count)
///
/// Fixed-point conventions:
///   gbm_price / last_exec_price : Q8.24 unsigned 32-bit
///   sigma                       : Q0.16 unsigned 16-bit
///   tick extraction from price  : bits [31:23] of the Q8.24 word, clamped to 479 before emit.
///                                 One tick equals 0.5 GBM price units (intentional).
///
module agent_execution_unit #(
    parameter         NUM_AGENT_SLOTS   = 64,             ///< Number of agent slots in the parameter M10K.
    parameter [31:0]  LFSR_POLY         = 32'hB4BCD35C,   ///< Galois feedback polynomial for the internal LFSR.
    parameter [31:0]  LFSR_SEED         = 32'hCAFEBABE,   ///< Initial seed for the internal LFSR.
    parameter [8:0]   NEAR_NOISE_THRESH = 9'd16           ///< Offset below which noise traders emit market orders.
)(
    input  wire        clk,                 ///< System clock.
    input  wire        rst_n,               ///< Active-low asynchronous reset.

    // Reference price feeds shared by every agent type.
    input  wire [31:0] gbm_price,           ///< Geometric Brownian motion reference price (Q8.24 unsigned).
    input  wire [31:0] last_exec_price,     ///< Most recent execution price from the matching engine (Q8.24 unsigned).
    input  wire [15:0] sigma,               ///< Volatility scaling parameter (Q0.16 unsigned).

    input  wire        trade_valid,         ///< Pulses one cycle on every matching engine execution.

    // Reads the per-slot parameter word out of the external M10K with one cycle of read latency.
    output reg  [15:0] param_addr,          ///< Drives the read address into the parameter M10K.
    input  wire [31:0] param_data,          ///< Parameter word returned by the M10K (one cycle after param_addr).

    input  wire [15:0] active_agent_count,  ///< Number of slots the FSM round-robins through before wrapping.

    // Single-packet handoff into the matching engine's Accept FIFO.
    output reg  [31:0] order_packet,        ///< Order packet payload assembled in kStateEmit.
    output reg         order_valid          ///< Pulses one cycle when order_packet is valid (not a level).
);

    // Encodes the four FSM substates of the slot pipeline.
    localparam [1:0] kStateLoad    = 2'b00;  ///< Drives slot_counter onto the parameter M10K read port.
    localparam [1:0] kStateWait    = 2'b01;  ///< Covers the M10K synchronous read latency cycle.
    localparam [1:0] kStateExecute = 2'b10;  ///< Latches param_data, runs the agent decision, prepares DSP operands.
    localparam [1:0] kStateEmit    = 2'b11;  ///< Assembles the packet, pulses order_valid, advances the slot counter.

    reg [1:0] state;

    // Provides one shared 32-bit pseudo-random sample per cycle. Different bit slices feed the
    // probability gate, side bit, offset multiplier, and volume multiplier within the same cycle.
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

    // Captures the four most recent execution prices reported by the matching engine. Index 0 is
    // the newest, index 3 is the oldest. Shifts on every trade_valid pulse so successive trades
    // populate the register without skips.
    reg [31:0] exec_price_shift_reg_0;
    reg [31:0] exec_price_shift_reg_1;
    reg [31:0] exec_price_shift_reg_2;
    reg [31:0] exec_price_shift_reg_3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exec_price_shift_reg_0 <= 32'd0;
            exec_price_shift_reg_1 <= 32'd0;
            exec_price_shift_reg_2 <= 32'd0;
            exec_price_shift_reg_3 <= 32'd0;
        end else if (trade_valid) begin
            exec_price_shift_reg_0 <= last_exec_price;
            exec_price_shift_reg_1 <= exec_price_shift_reg_0;
            exec_price_shift_reg_2 <= exec_price_shift_reg_1;
            exec_price_shift_reg_3 <= exec_price_shift_reg_2;
        end
    end

    // Tracks the slot the FSM is currently processing; wraps at active_agent_count.
    reg [15:0] slot_counter;

    // Latches the M10K read response so kStateEmit can reference it after the FSM advances.
    reg [31:0] latched_params;
    reg        emit_flag;          ///< Held high when the current slot will produce a packet in kStateEmit.
    reg        calc_side;          ///< Buy (0) or sell (1) decision computed in kStateExecute.
    reg        calc_order_type;    ///< Limit (0) or market (1) decision; driven combinationally per agent type.
    reg [15:0] calc_volume;        ///< Order share count latched in kStateExecute, packed into the packet in kStateEmit.
    reg [1:0]  calc_agent_type;    ///< Agent type latched from param_data[31:30]; routes the price assembly.

    // Holds the noise trader's combinational price-offset intermediates and the final 9-bit tick
    // emitted on bits [24:16] of the order packet.
    reg [9:0]  offset_raw;
    reg [8:0]  offset_ticks;
    reg [8:0]  final_price;

    // Drives the shared combinational multiplier reused across noise, momentum, and value branches.
    reg [9:0]  dsp_a;
    reg [9:0]  dsp_b;
    wire [19:0] dsp_product;
    assign dsp_product = dsp_a * dsp_b;

    // Extracts the 9-bit tick from the GBM reference price and clamps it to the LOB range.
    wire [8:0] gbm_tick;
    assign gbm_tick = (gbm_price[31:23] > 9'd479) ? 9'd479 : gbm_price[31:23];

    // Extracts the 9-bit tick from the most recent execution price for value, momentum, and
    // market maker agents.
    wire [8:0] last_exec_tick;
    assign last_exec_tick = (exec_price_shift_reg_0[31:23] > 9'd479) ? 9'd479 : exec_price_shift_reg_0[31:23];

    // Provides signed 11-bit views of gbm_tick and last_exec_tick so the value investor can compute
    // a signed divergence without overflow.
    wire signed [10:0] signed_gbm;
    wire signed [10:0] signed_exec;
    assign signed_gbm  = {2'b00, gbm_tick};
    assign signed_exec = {2'b00, last_exec_tick};

    // Computes the value investor's signed divergence and its absolute magnitude.
    wire signed [10:0] divergence;
    assign divergence = signed_gbm - signed_exec;

    wire [9:0] abs_div;
    assign abs_div = (divergence < 0) ? -divergence[9:0] : divergence[9:0];

    // Extracts the 9-bit tick from the four-cycles-old execution price that anchors the momentum
    // trader's trend window.
    wire [8:0] oldest_exec_tick;
    assign oldest_exec_tick = (exec_price_shift_reg_3[31:23] > 9'd479) ? 9'd479 : exec_price_shift_reg_3[31:23];

    wire signed [10:0] signed_exec_3;
    assign signed_exec_3 = {2'b00, oldest_exec_tick};

    // Computes the momentum trader's signed delta between the newest and oldest execution prices.
    wire signed [10:0] momentum_delta;
    assign momentum_delta = signed_exec - signed_exec_3;

    wire [9:0] abs_mom;
    assign abs_mom = (momentum_delta < 0) ? -momentum_delta[9:0] : momentum_delta[9:0];

    // Assembles final_price and calc_order_type combinationally based on the latched agent type.
    always @(*) begin
        // Defaults to the noise trader's offset arithmetic so unused branches keep stable inputs.
        offset_raw   = dsp_product[19:10];
        offset_ticks = (offset_raw > 10'd479) ? 9'd479 : offset_raw[8:0];

        case (calc_agent_type)

            // Noise trader: GBM tick offset by a randomized magnitude.
            2'b00: begin
                if (calc_side == 1'b0)
                    final_price = (gbm_tick > offset_ticks) ? (gbm_tick - offset_ticks) : 9'd0;
                else
                    final_price = ((gbm_tick + offset_ticks) > 9'd479) ? 9'd479 : (gbm_tick + offset_ticks);

                calc_order_type = (offset_ticks < NEAR_NOISE_THRESH) ? 1'b1 : 1'b0;
            end

            // Market maker: limit quote at the last execution tick offset by a per-slot half-spread.
            2'b01: begin
                if (calc_side == 1'b0)
                    final_price = (last_exec_tick > latched_params[18:10])
                                      ? (last_exec_tick - latched_params[18:10]) : 9'd0;
                else
                    final_price = ((last_exec_tick + latched_params[18:10]) > 9'd479)
                                      ? 9'd479 : (last_exec_tick + latched_params[18:10]);
                calc_order_type = 1'b0;
            end

            // Momentum trader: market order at the most recent execution tick.
            2'b10: begin
                final_price     = last_exec_tick;
                calc_order_type = 1'b1;
            end

            // Value investor: limit order at the GBM reference tick.
            2'b11: begin
                final_price     = gbm_tick;
                calc_order_type = 1'b0;
            end

            default: begin
                final_price     = gbm_tick;
                calc_order_type = 1'b0;
            end
        endcase
    end

    // Drives the four-state slot pipeline that round-robins through every active agent.
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
            // Deasserts order_valid by default so the pulse spans only the cycle that drives it
            // high in kStateEmit.
            order_valid <= 1'b0;

            case (state)
                // Drives the current slot index onto the parameter M10K read port.
                kStateLoad: begin
                    param_addr <= slot_counter;
                    state      <= kStateWait;
                end

                // Covers the M10K's one-cycle synchronous read latency.
                kStateWait: begin
                    state <= kStateExecute;
                end

                // Latches the parameter word, runs the per-agent decision, and routes operands into
                // the shared combinational multiplier so dsp_product is settled by kStateEmit.
                kStateExecute: begin
                    latched_params  <= param_data;
                    calc_agent_type <= param_data[31:30];
                    emit_flag       <= 1'b0;

                    case (param_data[31:30])

                        // Noise trader.
                        // param[29:20] : emission probability threshold
                        // param[19:10] : maximum price offset in ticks
                        // param[9:0]   : maximum volume cap
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

                        // Market maker.
                        // param[29:20] : emission probability threshold
                        // param[19:10] : half-spread in ticks
                        // param[9:0]   : fixed volume
                        2'b01: begin
                            if (lfsr_out[9:0] < param_data[29:20]) begin
                                emit_flag   <= 1'b1;
                                calc_side   <= lfsr_out[10];
                                calc_volume <= {6'd0, param_data[9:0]};
                            end else begin
                                emit_flag <= 1'b0;
                            end
                        end

                        // Momentum trader.
                        // param[29:20] : trend threshold
                        // param[19:10] : aggression scale
                        // param[9:0]   : maximum volume cap
                        2'b10: begin
                            if (abs_mom > param_data[29:20]) begin
                                emit_flag <= 1'b1;
                                // Buys (0) when the recent trend is positive, sells (1) otherwise.
                                calc_side <= (momentum_delta > 0) ? 1'b0 : 1'b1;

                                // Routes absolute momentum and aggression scale into the multiplier.
                                dsp_a <= abs_mom;
                                dsp_b <= param_data[19:10];
                            end else begin
                                emit_flag <= 1'b0;
                            end
                        end

                        // Value investor.
                        // param[29:20] : divergence threshold
                        // param[19:10] : aggression scale
                        // param[9:0]   : maximum volume cap
                        2'b11: begin
                            if (abs_div > param_data[29:20]) begin
                                emit_flag <= 1'b1;
                                // Buys (0) when GBM exceeds last execution (undervalued), sells (1) otherwise.
                                calc_side <= (divergence > 0) ? 1'b0 : 1'b1;

                                // Routes absolute divergence and aggression scale into the multiplier.
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

                // Assembles the order packet from the latched per-agent state, pulses order_valid,
                // and advances the round-robin slot counter.
                kStateEmit: begin
                    if (emit_flag) begin
                        case (calc_agent_type)

                            // Noise trader.
                            2'b00: begin
                                order_valid  <= 1'b1;
                                order_packet <= {
                                    calc_side,
                                    calc_order_type,
                                    calc_agent_type,
                                    3'b000,
                                    final_price,
                                    calc_volume
                                };
                            end

                            // Market maker.
                            2'b01: begin
                                order_valid  <= 1'b1;
                                order_packet <= {
                                    calc_side,
                                    calc_order_type,
                                    calc_agent_type,
                                    3'b000,
                                    final_price,
                                    calc_volume
                                };
                            end

                            // Momentum trader.
                            2'b10: begin
                                order_valid  <= 1'b1;
                                order_packet <= {
                                    calc_side,
                                    calc_order_type,
                                    calc_agent_type,
                                    3'b000,
                                    final_price,
                                    // Caps the share count at param[9:0] via min((dsp_product >> 10) + 1, cap).
                                    ( (dsp_product[19:10] + 10'd1) > latched_params[9:0] ) ?
                                        {6'd0, latched_params[9:0]} :
                                        ({6'd0, dsp_product[19:10]} + 16'd1)
                                };
                            end

                            // Value investor.
                            2'b11: begin
                                order_valid  <= 1'b1;
                                order_packet <= {
                                    calc_side,
                                    calc_order_type,
                                    calc_agent_type,
                                    3'b000,
                                    final_price,
                                    // Caps the share count at param[9:0] via min((dsp_product >> 10) + 1, cap).
                                    ( (dsp_product[19:10] + 10'd1) > latched_params[9:0] ) ?
                                        {6'd0, latched_params[9:0]} :
                                        ({6'd0, dsp_product[19:10]} + 16'd1)
                                };
                            end

                            default: begin
                                order_valid <= 1'b0;
                            end
                        endcase
                    end

                    // Advances the round-robin slot counter and wraps at active_agent_count. Holds
                    // at zero when no agents are active so the FSM stays parked on slot zero.
                    if (active_agent_count == 16'd0) begin
                        slot_counter <= 16'd0;
                    end else if (slot_counter >= active_agent_count - 16'd1) begin
                        slot_counter <= 16'd0;
                    end else begin
                        slot_counter <= slot_counter + 16'd1;
                    end

                    state <= kStateLoad;
                end

                default: state <= kStateLoad;
            endcase
        end
    end

endmodule
