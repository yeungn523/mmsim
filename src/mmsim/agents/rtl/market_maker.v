`timescale 1ns/1ps

module market_maker #(
    parameter kPriceWidth          = 32,      ///< Bit width of the price field (unsigned ticks).
    parameter kQuantityWidth       = 16,      ///< Bit width of the quantity field.
    parameter kOrderIdWidth        = 16,      ///< Bit width of the order identifier field.
    parameter kPriceRange          = 2048,    ///< Number of addressable price ticks.
    parameter kOrderIdBase         = 16'd10000, ///< Lowest order_id this agent will issue.
    parameter kOrderIdSpan         = 16'd16384, ///< Size of this agent's reserved order_id block.
    parameter kAnchorPrice         = 32'd1024,  ///< Cold-start fair price when book and tape are empty.
    parameter kOrderQuantity       = 16'd10,    ///< Shares per posted quote.
    parameter kHalfSpreadTicks     = 16'd2,     ///< Nominal half-spread around fair price.
    parameter kRequoteThreshold    = 16'd1,     ///< Fair-price drift (in ticks) that triggers a requote.
    parameter kSkewEnable          = 1'b0,      ///< 0 = fixed spread (v1), 1 = inventory-skewed (v2).
    parameter kSkewShiftBits       = 4'd3,      ///< Arithmetic right shift applied to inventory to form skew.
    parameter kMaxSkewTicks        = 16'd16     ///< Saturates the absolute value of the inventory skew.
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // Book observation (combinational taps of matching_engine top-of-book outputs)
    input  wire [kPriceWidth-1:0]      best_bid_price,       ///< Highest resting bid price in the engine.
    input  wire [kQuantityWidth-1:0]   best_bid_quantity,    ///< Aggregate quantity at the best bid.
    input  wire                        best_bid_valid,       ///< Determines whether the bid book is nonempty.
    input  wire [kPriceWidth-1:0]      best_ask_price,       ///< Lowest resting ask price in the engine.
    input  wire [kQuantityWidth-1:0]   best_ask_quantity,    ///< Aggregate quantity at the best ask.
    input  wire                        best_ask_valid,       ///< Determines whether the ask book is nonempty.

    // Trade snoop (combinational taps of matching_engine trade bus)
    input  wire                        trade_valid,          ///< Pulses high for one cycle per executed trade.
    input  wire [kOrderIdWidth-1:0]    trade_aggressor_id,   ///< Aggressive order identifier for this trade.
    input  wire [kOrderIdWidth-1:0]    trade_resting_id,     ///< Resting order identifier for this trade.
    input  wire [kPriceWidth-1:0]      trade_price,          ///< Execution price for this trade.
    input  wire [kQuantityWidth-1:0]   trade_quantity,       ///< Number of shares executed in this trade.

    // Arbiter handshake (the arbiter muxes one agent's order fields onto the engine each cycle)
    output reg                         order_request,        ///< Asserts when this agent has an order to submit.
    input  wire                        order_grant,          ///< Arbiter grants submission on this cycle.

    // Order submission fields (muxed by the arbiter onto the engine's order port)
    output reg  [2:0]                  order_type,           ///< Order type code (see localparams below).
    output reg  [kOrderIdWidth-1:0]    order_id,             ///< Unique identifier for the submitted order.
    output reg  [kPriceWidth-1:0]      order_price,          ///< Limit price of the submitted order.
    output reg  [kQuantityWidth-1:0]   order_quantity        ///< Share count of the submitted order.
);

    // Order type codes (must match matching_engine.v)
    localparam [2:0] kTypeLimitBuy   = 3'd1;
    localparam [2:0] kTypeLimitSell  = 3'd2;
    localparam [2:0] kTypeCancel     = 3'd5;

    // FSM states
    localparam [3:0] kStateInit         = 4'd0;  ///< Post-reset; transitions to seeding next cycle.
    localparam [3:0] kStateSeedBid      = 4'd1;  ///< Drives the initial bid to seed an empty book.
    localparam [3:0] kStateSeedAsk      = 4'd2;  ///< Drives the initial ask to seed an empty book.
    localparam [3:0] kStateQuoting      = 4'd3;  ///< Steady state; evaluates triggers each cycle.
    localparam [3:0] kStateReplenishBid = 4'd4;  ///< Posts a single bid when the bid side has gone missing.
    localparam [3:0] kStateReplenishAsk = 4'd5;  ///< Posts a single ask when the ask side has gone missing.
    localparam [3:0] kStateCancelBid    = 4'd6;  ///< First cycle of a requote: cancels our current bid.
    localparam [3:0] kStateCancelAsk    = 4'd7;  ///< Second cycle of a requote: cancels our current ask.
    localparam [3:0] kStatePostBid      = 4'd8;  ///< Third cycle of a requote: posts the new bid.
    localparam [3:0] kStatePostAsk      = 4'd9;  ///< Fourth cycle of a requote: posts the new ask.

    // Registered FSM state and per-agent bookkeeping
    reg [3:0]                   state;
    reg [kOrderIdWidth-1:0]     next_order_id;         ///< Monotonic counter within the reserved ID block.

    reg [kOrderIdWidth-1:0]     active_bid_id;         ///< Identifier of the currently resting bid.
    reg [kQuantityWidth-1:0]    active_bid_remaining;  ///< Shares remaining on the currently resting bid.
    reg [kPriceWidth-1:0]       active_bid_price;      ///< Price of the currently resting bid.

    reg [kOrderIdWidth-1:0]     active_ask_id;         ///< Identifier of the currently resting ask.
    reg [kQuantityWidth-1:0]    active_ask_remaining;  ///< Shares remaining on the currently resting ask.
    reg [kPriceWidth-1:0]       active_ask_price;      ///< Price of the currently resting ask.

    reg signed [15:0]           net_inventory;         ///< Positive = long, negative = short.
    reg [kPriceWidth-1:0]       last_trade_price;      ///< Most recently observed trade price on the bus.
    reg                         last_trade_price_valid;///< Determines whether last_trade_price is meaningful.
    reg [kPriceWidth-1:0]       last_quoted_fair;      ///< Fair price at the moment of the most recent post.
    reg                         last_quoted_fair_valid;///< Determines whether last_quoted_fair is meaningful.

    // Combinational fair price ladder
    wire [kPriceWidth-1:0]      midpoint_price = (best_bid_price + best_ask_price) >> 1;
    wire [kPriceWidth-1:0]      fair_price =
          (best_bid_valid && best_ask_valid) ? midpoint_price
        :  last_trade_price_valid            ? last_trade_price
        :                                      kAnchorPrice;

    // Inventory skew. Shifts the half-spread asymmetrically so the agent quotes more aggressively
    // on the side that reduces its absolute inventory, bleeding off directional exposure.
    wire signed [15:0]          skew_raw    = net_inventory >>> kSkewShiftBits;
    wire signed [15:0]          skew_positive_cap = ($signed(kMaxSkewTicks));
    wire signed [15:0]          skew_negative_cap = -$signed(kMaxSkewTicks);
    wire signed [15:0]          skew_saturated =
          (skew_raw > skew_positive_cap) ? skew_positive_cap
        : (skew_raw < skew_negative_cap) ? skew_negative_cap
        :                                  skew_raw;
    wire signed [15:0]          skew = kSkewEnable ? skew_saturated : 16'sd0;

    wire [15:0]                 skew_abs = (skew < 0) ? -skew : skew;
    wire [15:0]                 bid_half_spread = (skew > 0) ? (kHalfSpreadTicks + skew_abs) : kHalfSpreadTicks;
    wire [15:0]                 ask_half_spread = (skew < 0) ? (kHalfSpreadTicks + skew_abs) : kHalfSpreadTicks;

    // Clamped quote prices. Keeps both quotes strictly inside the engine's addressable tick range.
    wire [kPriceWidth-1:0]      proposed_bid = (fair_price > {{(kPriceWidth-16){1'b0}}, bid_half_spread})
                                                ? (fair_price - {{(kPriceWidth-16){1'b0}}, bid_half_spread})
                                                : 32'd1;
    wire [kPriceWidth-1:0]      proposed_ask_sum = fair_price + {{(kPriceWidth-16){1'b0}}, ask_half_spread};
    wire [kPriceWidth-1:0]      new_bid_price    = (proposed_bid == 32'd0) ? 32'd1 : proposed_bid;
    wire [kPriceWidth-1:0]      new_ask_price    = (proposed_ask_sum >= kPriceRange) ? (kPriceRange - 1)
                                                                                     : proposed_ask_sum;

    // Drift detection for requote trigger
    wire [kPriceWidth-1:0]      drift_abs = (fair_price > last_quoted_fair)
                                            ? (fair_price - last_quoted_fair)
                                            : (last_quoted_fair - fair_price);
    wire                        drift_triggers_requote =
          last_quoted_fair_valid
       && (drift_abs >= {{(kPriceWidth-16){1'b0}}, kRequoteThreshold});

    // Quote liveness derived from the remaining share count. A quote is live whenever at least one
    // share of the posted quantity is still resting on the book; the flag deasserts only when the
    // order is fully consumed or explicitly cancelled.
    wire active_bid_valid = (active_bid_remaining != {kQuantityWidth{1'b0}});
    wire active_ask_valid = (active_ask_remaining != {kQuantityWidth{1'b0}});

    // Own-fill detection from the trade snoop bus
    wire bid_fill_event = trade_valid && active_bid_valid && (trade_resting_id == active_bid_id);
    wire ask_fill_event = trade_valid && active_ask_valid && (trade_resting_id == active_ask_id);

    // Next-order-id helper that wraps within the reserved block
    wire [kOrderIdWidth-1:0]    next_after = (next_order_id + 16'd1);
    wire [kOrderIdWidth-1:0]    wrapped_next = (next_after >= (kOrderIdBase + kOrderIdSpan))
                                                ? kOrderIdBase
                                                : next_after;

    always @(posedge clk) begin
        if (!rst_n) begin
            state                  <= kStateInit;
            next_order_id          <= kOrderIdBase;

            active_bid_id          <= {kOrderIdWidth{1'b0}};
            active_bid_remaining   <= {kQuantityWidth{1'b0}};
            active_bid_price       <= {kPriceWidth{1'b0}};
            active_ask_id          <= {kOrderIdWidth{1'b0}};
            active_ask_remaining   <= {kQuantityWidth{1'b0}};
            active_ask_price       <= {kPriceWidth{1'b0}};

            net_inventory          <= 16'sd0;
            last_trade_price       <= {kPriceWidth{1'b0}};
            last_trade_price_valid <= 1'b0;
            last_quoted_fair       <= {kPriceWidth{1'b0}};
            last_quoted_fair_valid <= 1'b0;

            order_request          <= 1'b0;
            order_type             <= 3'd0;
            order_id               <= {kOrderIdWidth{1'b0}};
            order_price            <= {kPriceWidth{1'b0}};
            order_quantity         <= {kQuantityWidth{1'b0}};

        end else begin
            // Fill attribution from the trade snoop bus. Runs in every non-reset cycle so inventory
            // and quote liveness stay accurate regardless of the FSM's current action state.
            if (trade_valid) begin
                last_trade_price       <= trade_price;
                last_trade_price_valid <= 1'b1;
                if (bid_fill_event) begin
                    net_inventory        <= net_inventory + $signed({1'b0, trade_quantity});
                    // Saturates to zero when a trade consumes the whole remaining quantity so the
                    // subtraction never underflows on a final fill.
                    active_bid_remaining <= (trade_quantity >= active_bid_remaining)
                                            ? {kQuantityWidth{1'b0}}
                                            : (active_bid_remaining - trade_quantity);
                end
                if (ask_fill_event) begin
                    net_inventory        <= net_inventory - $signed({1'b0, trade_quantity});
                    active_ask_remaining <= (trade_quantity >= active_ask_remaining)
                                            ? {kQuantityWidth{1'b0}}
                                            : (active_ask_remaining - trade_quantity);
                end
            end

            case (state)
                // Waits one cycle after reset before driving the seed bid so that combinational
                // inputs from the engine have settled.
                kStateInit: begin
                    order_request <= 1'b0;
                    state         <= kStateSeedBid;
                end

                // Drives the initial bid. Advances only when the arbiter grants this cycle.
                kStateSeedBid: begin
                    order_request  <= 1'b1;
                    order_type     <= kTypeLimitBuy;
                    order_id       <= next_order_id;
                    order_price    <= new_bid_price;
                    order_quantity <= kOrderQuantity;
                    if (order_grant) begin
                        active_bid_id        <= next_order_id;
                        active_bid_remaining <= kOrderQuantity;
                        active_bid_price     <= new_bid_price;
                        next_order_id    <= wrapped_next;
                        order_request    <= 1'b0;
                        state            <= kStateSeedAsk;
                    end
                end

                // Drives the initial ask. Locks in last_quoted_fair so the requote trigger has a baseline.
                kStateSeedAsk: begin
                    order_request  <= 1'b1;
                    order_type     <= kTypeLimitSell;
                    order_id       <= next_order_id;
                    order_price    <= new_ask_price;
                    order_quantity <= kOrderQuantity;
                    if (order_grant) begin
                        active_ask_id          <= next_order_id;
                        active_ask_remaining   <= kOrderQuantity;
                        active_ask_price       <= new_ask_price;
                        next_order_id          <= wrapped_next;
                        last_quoted_fair       <= fair_price;
                        last_quoted_fair_valid <= 1'b1;
                        order_request          <= 1'b0;
                        state                  <= kStateQuoting;
                    end
                end

                // Steady state. Priority-ordered trigger evaluation chooses the next action state.
                kStateQuoting: begin
                    order_request <= 1'b0;
                    if (bid_fill_event || !active_bid_valid) begin
                        state <= kStateReplenishBid;
                    end else if (ask_fill_event || !active_ask_valid) begin
                        state <= kStateReplenishAsk;
                    end else if (!best_bid_valid) begin
                        state <= kStateReplenishBid;
                    end else if (!best_ask_valid) begin
                        state <= kStateReplenishAsk;
                    end else if (drift_triggers_requote) begin
                        state <= kStateCancelBid;
                    end
                end

                kStateReplenishBid: begin
                    order_request  <= 1'b1;
                    order_type     <= kTypeLimitBuy;
                    order_id       <= next_order_id;
                    order_price    <= new_bid_price;
                    order_quantity <= kOrderQuantity;
                    if (order_grant) begin
                        active_bid_id        <= next_order_id;
                        active_bid_remaining <= kOrderQuantity;
                        active_bid_price     <= new_bid_price;
                        next_order_id    <= wrapped_next;
                        order_request    <= 1'b0;
                        state            <= kStateQuoting;
                    end
                end

                kStateReplenishAsk: begin
                    order_request  <= 1'b1;
                    order_type     <= kTypeLimitSell;
                    order_id       <= next_order_id;
                    order_price    <= new_ask_price;
                    order_quantity <= kOrderQuantity;
                    if (order_grant) begin
                        active_ask_id        <= next_order_id;
                        active_ask_remaining <= kOrderQuantity;
                        active_ask_price     <= new_ask_price;
                        next_order_id    <= wrapped_next;
                        order_request    <= 1'b0;
                        state            <= kStateQuoting;
                    end
                end

                // Requote sequence: cancel both sides, then repost both sides. Skips canceling
                // a side whose quote has already been consumed (active_*_valid == 0).
                kStateCancelBid: begin
                    if (active_bid_valid) begin
                        order_request  <= 1'b1;
                        order_type     <= kTypeCancel;
                        order_id       <= active_bid_id;
                        order_price    <= {kPriceWidth{1'b0}};
                        order_quantity <= {kQuantityWidth{1'b0}};
                        if (order_grant) begin
                            active_bid_remaining <= {kQuantityWidth{1'b0}};
                            order_request        <= 1'b0;
                            state                <= kStateCancelAsk;
                        end
                    end else begin
                        order_request <= 1'b0;
                        state         <= kStateCancelAsk;
                    end
                end

                kStateCancelAsk: begin
                    if (active_ask_valid) begin
                        order_request  <= 1'b1;
                        order_type     <= kTypeCancel;
                        order_id       <= active_ask_id;
                        order_price    <= {kPriceWidth{1'b0}};
                        order_quantity <= {kQuantityWidth{1'b0}};
                        if (order_grant) begin
                            active_ask_remaining <= {kQuantityWidth{1'b0}};
                            order_request        <= 1'b0;
                            state                <= kStatePostBid;
                        end
                    end else begin
                        order_request <= 1'b0;
                        state         <= kStatePostBid;
                    end
                end

                kStatePostBid: begin
                    order_request  <= 1'b1;
                    order_type     <= kTypeLimitBuy;
                    order_id       <= next_order_id;
                    order_price    <= new_bid_price;
                    order_quantity <= kOrderQuantity;
                    if (order_grant) begin
                        active_bid_id        <= next_order_id;
                        active_bid_remaining <= kOrderQuantity;
                        active_bid_price     <= new_bid_price;
                        next_order_id    <= wrapped_next;
                        order_request    <= 1'b0;
                        state            <= kStatePostAsk;
                    end
                end

                kStatePostAsk: begin
                    order_request  <= 1'b1;
                    order_type     <= kTypeLimitSell;
                    order_id       <= next_order_id;
                    order_price    <= new_ask_price;
                    order_quantity <= kOrderQuantity;
                    if (order_grant) begin
                        active_ask_id          <= next_order_id;
                        active_ask_remaining   <= kOrderQuantity;
                        active_ask_price       <= new_ask_price;
                        next_order_id          <= wrapped_next;
                        last_quoted_fair       <= fair_price;
                        last_quoted_fair_valid <= 1'b1;
                        order_request          <= 1'b0;
                        state                  <= kStateQuoting;
                    end
                end

                default: begin
                    order_request <= 1'b0;
                    state         <= kStateQuoting;
                end
            endcase
        end
    end

endmodule
