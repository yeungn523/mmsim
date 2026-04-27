// agent_execution_unit.v
// FSM: kStateLoad -> kStateWait -> kStateExecute -> kStateEmit
// Cycles through all active agent slots, one slot per 4 clocks
//
// Packet format (32-bit, fire-and-forget into arbiter FIFO):
//   bit  [31]       side        (0=buy, 1=sell)
//   bit  [30]       order_type  (0=limit, 1=market)
//   bits [29:28]    agent_type  (00=noise, 01=mm, 10=momentum, 11=value)
//   bits [27:25]    reserved    (0)
//   bits [24:16]    price       (9-bit tick index, 0-479, direct LOB address)
//   bits [15:0]     volume      (unsigned 16-bit)
//
// Fixed-point reference:
//   gbm_price / last_exec_price : Q8.24 unsigned 32-bit
//   sigma                       : Q0.16 unsigned 16-bit
//   price tick extraction       : gbm_price[31:23] = 9 bits covering 0-511
//                                 1 tick = 0.5 GBM price units (intentional)
//                                 clamp to 479 before emitting
module agent_execution_unit #(
    parameter         NUM_AGENT_SLOTS   = 64,
    parameter [31:0]  LFSR_POLY         = 32'hB4BCD35C,
    parameter [31:0]  LFSR_SEED         = 32'hCAFEBABE,
    parameter [8:0]   NEAR_NOISE_THRESH = 9'd16
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] gbm_price,           // Q8.24 unsigned
    input  wire [31:0] last_exec_price,     // Q8.24 unsigned
    input  wire [15:0] sigma,               // Q0.16 unsigned

    input  wire        trade_valid,         // single-cycle pulse on every execution

    output reg  [15:0] param_addr,
    input  wire [31:0] param_data,

    input  wire [15:0] active_agent_count,

    output reg  [31:0] order_packet,
    output reg         order_valid,         // single-cycle pulse, not a level

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


    // exec_price_shift_reg[0] = most recent, [3] = oldest
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
    assign gbm_tick = (gbm_price[31:23] > 9'd479) ? 9'd479 : gbm_price[31:23];

    // Value Investor Combinational Logic 
    wire [8:0] last_exec_tick;
    assign last_exec_tick = (last_exec_price[31:23] > 9'd479) 
                            ? 9'd479 : last_exec_price[31:23];

    wire signed [10:0] signed_gbm;
    wire signed [10:0] signed_exec;
    assign signed_gbm  = {2'b00, gbm_tick};
    assign signed_exec = {2'b00, last_exec_tick};

    wire signed [10:0] divergence;
    assign divergence = signed_gbm - signed_exec;

    wire [9:0] abs_div;
    assign abs_div = divergence[10] 
                    ? (~divergence[9:0] + 10'd1) 
                    : divergence[9:0];

    // Momentum Trader Combinational Logic 
    wire [8:0] oldest_exec_tick;
    assign oldest_exec_tick = (exec_price_shift_reg_3[31:23] > 9'd479) ? 9'd479 : exec_price_shift_reg_3[31:23];

    wire signed [10:0] signed_exec_3;
    assign signed_exec_3 = {2'b00, oldest_exec_tick};

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
        offset_ticks = (offset_raw > 10'd479) ? 9'd479 : offset_raw[8:0];

        case (calc_agent_type)

            2'b00: begin  // NOISE TRADER
                if (calc_side == 1'b0)
                    final_price = (gbm_tick > offset_ticks) ? (gbm_tick - offset_ticks) : 9'd0;
                else
                    final_price = ((gbm_tick + offset_ticks) > 9'd479) ? 9'd479 : (gbm_tick + offset_ticks);
                
                calc_order_type = (offset_ticks < NEAR_NOISE_THRESH) ? 1'b1 : 1'b0;
            end

            2'b01: begin  // MARKET MAKER
                if (calc_side == 1'b0)
                    final_price = (last_exec_tick > latched_params[18:10])
                                    ? (last_exec_tick - latched_params[18:10]) : 9'd0;
                else
                    final_price = ((last_exec_tick + latched_params[18:10]) > 9'd479)
                                    ? 9'd479 : (last_exec_tick + latched_params[18:10]);
                calc_order_type = 1'b0;
            end

            2'b10: begin  // MOMENTUM TRADER
                final_price     = last_exec_tick; 
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
                // Put slot address on M10K read port
                kStateLoad: begin
                    order_valid <= 1'b0;
                    if (active_agent_count == 16'd0) begin
                        state <= kStateLoad;
                    end else begin
                        param_addr <= slot_counter;
                        state      <= kStateWait;
                    end
                end

                // M10K synchronous read latency cycle
                kStateWait: begin
                    order_valid <= 1'b0;
                    state <= kStateExecute;
                end

                // param_data now valid, latch params, run agent logic,
                // set up DSP inputs. DSP product ready in kStateEmit.
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
                                
                                // Route to DSP for volume scaling
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
                                
                                // Route to DSP for volume scaling
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

                // DSP product valid, assemble packet, advance slot counter
                kStateEmit: begin
                    if (emit_flag) begin

                        order_valid <= 1'b1;

                        // Assemble packet (re-driven every cycle while stalled, safe since
                        // all inputs are registered and stable in kStateEmit)
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

                        // Advance only on grant, last NBA wins, cleanly deasserts valid
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
                        // No emission, deassert and advance immediately
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