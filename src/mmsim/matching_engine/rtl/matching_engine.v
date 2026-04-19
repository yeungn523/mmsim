/**
 * @file
 *
 * @brief Provides the matching engine that processes incoming order packets against a
 * price-priority, time-priority limit order book for a single stock.
 *
 * Instantiates two price_level_store modules (bid side and ask side). Incoming orders are
 * matched against the opposite book side; any unmatched remainder is inserted into the
 * same-side book. Trade executions are reported on the trade output interface. The engine
 * accepts one order at a time via a valid/ready handshake.
 */

`timescale 1ns/1ps

module matching_engine #(
    parameter kDepth         = 16,  ///< Maximum price levels per book side.
    parameter kMaxOrders     = 64,  ///< Maximum individual orders per book side.
    parameter kPriceWidth    = 32,  ///< Bit width of the price field (unsigned ticks).
    parameter kQuantityWidth = 16,  ///< Bit width of the quantity field.
    parameter kOrderIdWidth  = 16   ///< Bit width of the order identifier field.
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Order input interface (valid/ready handshake)
    input  wire [2:0]                  order_type,           ///< Specifies the order type code.
    input  wire [kOrderIdWidth-1:0]    order_id,             ///< Provides the order's unique identifier.
    input  wire [kPriceWidth-1:0]      order_price,          ///< Provides the order's limit price in ticks.
    input  wire [kQuantityWidth-1:0]   order_quantity,        ///< Provides the order's share count.
    input  wire                        order_valid,           ///< Asserts when a new order is available.
    output reg                         order_ready,           ///< Asserts when the engine can accept an order.

    // Trade execution output
    output reg  [kOrderIdWidth-1:0]    trade_aggressor_id,    ///< Reports the aggressive order's identifier.
    output reg  [kOrderIdWidth-1:0]    trade_resting_id,      ///< Reports the resting order's identifier.
    output reg  [kPriceWidth-1:0]      trade_price,           ///< Reports the execution price (resting order's price).
    output reg  [kQuantityWidth-1:0]   trade_quantity,         ///< Reports the number of shares traded.
    output reg                         trade_valid,            ///< Pulses high for one cycle per trade execution.

    // Top-of-book state (directly wired from the book stores)
    output wire [kPriceWidth-1:0]      best_bid_price,        ///< Provides the highest resting bid price.
    output wire [kQuantityWidth-1:0]   best_bid_quantity,      ///< Provides the aggregate quantity at the best bid.
    output wire                        best_bid_valid,         ///< Determines whether the bid book has orders.
    output wire [kPriceWidth-1:0]      best_ask_price,        ///< Provides the lowest resting ask price.
    output wire [kQuantityWidth-1:0]   best_ask_quantity,      ///< Provides the aggregate quantity at the best ask.
    output wire                        best_ask_valid,         ///< Determines whether the ask book has orders.

    // Statistics
    output reg  [31:0]                 total_trades,           ///< Counts the total number of trade executions.
    output reg  [31:0]                 total_volume            ///< Accumulates the total shares traded.
);

    // Order type codes
    localparam kTypeLimitBuy   = 3'd1;  ///< Specifies a limit buy order.
    localparam kTypeLimitSell  = 3'd2;  ///< Specifies a limit sell order.
    localparam kTypeMarketBuy  = 3'd3;  ///< Specifies a market buy order.
    localparam kTypeMarketSell = 3'd4;  ///< Specifies a market sell order.
    localparam kTypeCancel     = 3'd5;  ///< Specifies an order cancellation.

    // FSM state encoding
    localparam kStateIdle       = 4'd0;  ///< Waits for a new order on the input interface.
    localparam kStateClassify   = 4'd1;  ///< Determines the order's side and routing.
    localparam kStateMatchCheck = 4'd2;  ///< Checks the opposite book for a matchable price.
    localparam kStateMatchExec  = 4'd3;  ///< Initiates a consume command on the opposite book.
    localparam kStateMatchWait  = 4'd4;  ///< Waits for the opposite book's consume to complete.
    localparam kStateInsert     = 4'd5;  ///< Initiates an insert command on the same-side book.
    localparam kStateInsertWait = 4'd6;  ///< Waits for the same-side book's insert to complete.
    localparam kStateCancel     = 4'd7;  ///< Forwards a cancel command to both book sides.
    localparam kStateCancelWait = 4'd8;  ///< Waits for both cancel operations to complete.

    // Price level store command codes (must match the price_level_store module)
    localparam kCommandNop     = 3'd0;
    localparam kCommandInsert  = 3'd1;
    localparam kCommandConsume = 3'd2;
    localparam kCommandCancel  = 3'd3;

    reg [3:0] state;

    // Latched order fields
    reg [2:0]                  working_type;
    reg [kOrderIdWidth-1:0]    working_id;
    reg [kPriceWidth-1:0]      working_price;
    reg [kQuantityWidth-1:0]   working_remaining;  ///< Tracks the unfilled portion of the order.
    reg                        working_is_buy;     ///< Determines whether the latched order is a buy.
    reg                        working_is_market;  ///< Determines whether the latched order is a market order.

    // Bid book interface signals
    reg  [2:0]                 bid_command;
    reg  [kPriceWidth-1:0]     bid_command_price;
    reg  [kQuantityWidth-1:0]  bid_command_quantity;
    reg  [kOrderIdWidth-1:0]   bid_command_order_id;
    reg                        bid_command_valid;
    wire                       bid_command_ready;
    wire [kOrderIdWidth-1:0]   bid_response_order_id;
    wire [kQuantityWidth-1:0]  bid_response_quantity;
    wire                       bid_response_valid;
    wire                       bid_response_found;

    // Ask book interface signals
    reg  [2:0]                 ask_command;
    reg  [kPriceWidth-1:0]     ask_command_price;
    reg  [kQuantityWidth-1:0]  ask_command_quantity;
    reg  [kOrderIdWidth-1:0]   ask_command_order_id;
    reg                        ask_command_valid;
    wire                       ask_command_ready;
    wire [kOrderIdWidth-1:0]   ask_response_order_id;
    wire [kQuantityWidth-1:0]  ask_response_quantity;
    wire                       ask_response_valid;
    wire                       ask_response_found;

    // Cancel tracking (both sides must complete)
    reg                        cancel_bid_done;
    reg                        cancel_ask_done;
    reg                        cancel_bid_found;

    // Tracks whether a command is awaiting book completion. Asserts when a command is issued and
    // deasserts when command_ready transitions from low back to high.
    reg                        bid_in_flight;  ///< Determines whether a bid-book command is in flight.
    reg                        ask_in_flight;  ///< Determines whether an ask-book command is in flight.

    // Bid book (descending price sort, highest at index 0)
    price_level_store #(
        .kDepth         (kDepth),
        .kMaxOrders     (kMaxOrders),
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth),
        .kIsBid         (1)
    ) bid_book (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (bid_command),
        .command_price     (bid_command_price),
        .command_quantity  (bid_command_quantity),
        .command_order_id  (bid_command_order_id),
        .command_valid     (bid_command_valid),
        .command_ready     (bid_command_ready),
        .response_order_id (bid_response_order_id),
        .response_quantity (bid_response_quantity),
        .response_valid    (bid_response_valid),
        .response_found    (bid_response_found),
        .best_price        (best_bid_price),
        .best_quantity     (best_bid_quantity),
        .best_valid        (best_bid_valid),
        .full              ()
    );

    // Ask book (ascending price sort, lowest at index 0)
    price_level_store #(
        .kDepth         (kDepth),
        .kMaxOrders     (kMaxOrders),
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth),
        .kIsBid         (0)
    ) ask_book (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (ask_command),
        .command_price     (ask_command_price),
        .command_quantity  (ask_command_quantity),
        .command_order_id  (ask_command_order_id),
        .command_valid     (ask_command_valid),
        .command_ready     (ask_command_ready),
        .response_order_id (ask_response_order_id),
        .response_quantity (ask_response_quantity),
        .response_valid    (ask_response_valid),
        .response_found    (ask_response_found),
        .best_price        (best_ask_price),
        .best_quantity     (best_ask_quantity),
        .best_valid        (best_ask_valid),
        .full              ()
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= kStateIdle;
            order_ready       <= 1'b1;
            trade_valid       <= 1'b0;
            trade_aggressor_id <= {kOrderIdWidth{1'b0}};
            trade_resting_id  <= {kOrderIdWidth{1'b0}};
            trade_price       <= {kPriceWidth{1'b0}};
            trade_quantity    <= {kQuantityWidth{1'b0}};
            total_trades      <= 32'd0;
            total_volume      <= 32'd0;

            bid_command       <= kCommandNop;
            bid_command_valid <= 1'b0;
            bid_command_price <= {kPriceWidth{1'b0}};
            bid_command_quantity <= {kQuantityWidth{1'b0}};
            bid_command_order_id <= {kOrderIdWidth{1'b0}};

            ask_command       <= kCommandNop;
            ask_command_valid <= 1'b0;
            ask_command_price <= {kPriceWidth{1'b0}};
            ask_command_quantity <= {kQuantityWidth{1'b0}};
            ask_command_order_id <= {kOrderIdWidth{1'b0}};

            cancel_bid_done   <= 1'b0;
            cancel_ask_done   <= 1'b0;
            cancel_bid_found  <= 1'b0;

            bid_in_flight     <= 1'b0;
            ask_in_flight     <= 1'b0;
            
        end else begin
            // Deasserts single-cycle pulses
            trade_valid       <= 1'b0;
            bid_command_valid <= 1'b0;
            ask_command_valid <= 1'b0;

            // Clears the in-flight flag when the book's command_ready reasserts
            if (bid_in_flight && bid_command_ready)
                bid_in_flight <= 1'b0;
            if (ask_in_flight && ask_command_ready)
                ask_in_flight <= 1'b0;

            case (state)
                kStateIdle: begin
                    if (order_valid && order_ready) begin
                        working_type      <= order_type;
                        working_id        <= order_id;
                        working_price     <= order_price;
                        working_remaining <= order_quantity;
                        order_ready       <= 1'b0;
                        state             <= kStateClassify;
                    end
                end

                // Determines the order's side and whether it is a market order
                kStateClassify: begin
                    case (working_type)
                        kTypeLimitBuy: begin
                            working_is_buy    <= 1'b1;
                            working_is_market <= 1'b0;
                            state             <= kStateMatchCheck;
                        end
                        kTypeLimitSell: begin
                            working_is_buy    <= 1'b0;
                            working_is_market <= 1'b0;
                            state             <= kStateMatchCheck;
                        end
                        kTypeMarketBuy: begin
                            working_is_buy    <= 1'b1;
                            working_is_market <= 1'b1;
                            state             <= kStateMatchCheck;
                        end
                        kTypeMarketSell: begin
                            working_is_buy    <= 1'b0;
                            working_is_market <= 1'b1;
                            state             <= kStateMatchCheck;
                        end
                        kTypeCancel: begin
                            state <= kStateCancel;
                        end
                        default: begin
                            // Ignores unknown order types
                            order_ready <= 1'b1;
                            state       <= kStateIdle;
                        end
                    endcase
                end

                // Checks whether the opposite book has a price that crosses the incoming order
                kStateMatchCheck: begin
                    if (working_remaining == 0) begin
                        // Terminates when previous match iterations fully filled the order.
                        order_ready <= 1'b1;
                        state       <= kStateIdle;
                    end else if (working_is_buy) begin
                        // Checks whether the best ask crosses the buy order's price.
                        if (best_ask_valid && (working_is_market || best_ask_price <= working_price)) begin
                            state <= kStateMatchExec;
                        end else begin
                            // Handles the no-match case.
                            if (working_is_market) begin
                                // Discards unfilled market order remainder
                                order_ready <= 1'b1;
                                state       <= kStateIdle;
                            end else begin
                                state <= kStateInsert;
                            end
                        end
                    end else begin
                        // Checks whether the best bid crosses the sell order's price.
                        if (best_bid_valid && (working_is_market || best_bid_price >= working_price)) begin
                            state <= kStateMatchExec;
                        end else begin
                            if (working_is_market) begin
                                order_ready <= 1'b1;
                                state       <= kStateIdle;
                            end else begin
                                state <= kStateInsert;
                            end
                        end
                    end
                end

                // Sends a consume command to the opposite book for the matchable quantity
                kStateMatchExec: begin
                    begin
                        reg [kQuantityWidth-1:0] fill_quantity;

                        if (working_is_buy) begin
                            // Consumes from the ask book
                            fill_quantity = (working_remaining < best_ask_quantity)
                                            ? working_remaining : best_ask_quantity;

                            ask_command          <= kCommandConsume;
                            ask_command_quantity  <= fill_quantity;
                            ask_command_valid     <= 1'b1;
                            ask_in_flight         <= 1'b1;

                            trade_price <= best_ask_price;
                        end else begin
                            // Consumes from the bid book
                            fill_quantity = (working_remaining < best_bid_quantity)
                                            ? working_remaining : best_bid_quantity;

                            bid_command          <= kCommandConsume;
                            bid_command_quantity  <= fill_quantity;
                            bid_command_valid     <= 1'b1;
                            bid_in_flight         <= 1'b1;

                            trade_price <= best_bid_price;
                        end

                        trade_aggressor_id <= working_id;
                        trade_quantity     <= fill_quantity;
                    end

                    state <= kStateMatchWait;
                end

                // Waits for the opposite book's consume to complete, then emits the trade.
                // The in-flight flag is cleared when command_ready reasserts (see top of always).
                kStateMatchWait: begin
                    if (working_is_buy && !ask_in_flight && ask_command_ready) begin
                        trade_resting_id  <= ask_response_order_id;
                        trade_valid       <= 1'b1;
                        working_remaining <= working_remaining - trade_quantity;
                        total_trades      <= total_trades + 1;
                        total_volume      <= total_volume + {16'd0, trade_quantity};

                        // Loops back to check for more matches at the next price level
                        state <= kStateMatchCheck;
                    end else if (!working_is_buy && !bid_in_flight && bid_command_ready) begin
                        trade_resting_id  <= bid_response_order_id;
                        trade_valid       <= 1'b1;
                        working_remaining <= working_remaining - trade_quantity;
                        total_trades      <= total_trades + 1;
                        total_volume      <= total_volume + {16'd0, trade_quantity};

                        state <= kStateMatchCheck;
                    end
                end

                // Inserts the unmatched remainder into the same-side book
                kStateInsert: begin
                    if (working_is_buy && !bid_in_flight && bid_command_ready) begin
                        bid_command          <= kCommandInsert;
                        bid_command_price    <= working_price;
                        bid_command_quantity <= working_remaining;
                        bid_command_order_id <= working_id;
                        bid_command_valid    <= 1'b1;
                        bid_in_flight        <= 1'b1;
                        state                <= kStateInsertWait;
                    end else if (!working_is_buy && !ask_in_flight && ask_command_ready) begin
                        ask_command          <= kCommandInsert;
                        ask_command_price    <= working_price;
                        ask_command_quantity <= working_remaining;
                        ask_command_order_id <= working_id;
                        ask_command_valid    <= 1'b1;
                        ask_in_flight        <= 1'b1;
                        state                <= kStateInsertWait;
                    end
                end

                // Waits for the insert to complete. The in-flight flag ensures command_ready is
                // observed transitioning low then high rather than remaining in its pre-command
                // high state.
                kStateInsertWait: begin
                    if (working_is_buy && !bid_in_flight && bid_command_ready) begin
                        order_ready <= 1'b1;
                        state       <= kStateIdle;
                    end else if (!working_is_buy && !ask_in_flight && ask_command_ready) begin
                        order_ready <= 1'b1;
                        state       <= kStateIdle;
                    end
                end

                // Sends cancel commands to both book sides simultaneously
                kStateCancel: begin
                    if (!bid_in_flight && !ask_in_flight
                        && bid_command_ready && ask_command_ready) begin
                        bid_command          <= kCommandCancel;
                        bid_command_order_id <= working_id;
                        bid_command_valid    <= 1'b1;
                        bid_in_flight        <= 1'b1;

                        ask_command          <= kCommandCancel;
                        ask_command_order_id <= working_id;
                        ask_command_valid    <= 1'b1;
                        ask_in_flight        <= 1'b1;

                        cancel_bid_done  <= 1'b0;
                        cancel_ask_done  <= 1'b0;
                        cancel_bid_found <= 1'b0;

                        state <= kStateCancelWait;
                    end
                end

                // Waits for both cancel operations to report completion. Exits only after both
                // sides have cleared their in-flight flag (meaning the store dropped ready to
                // work and brought it back up) and their done flags are set.
                kStateCancelWait: begin
                    if (!bid_in_flight && bid_command_ready && !cancel_bid_done) begin
                        cancel_bid_done  <= 1'b1;
                        cancel_bid_found <= bid_response_found;
                    end
                    if (!ask_in_flight && ask_command_ready && !cancel_ask_done) begin
                        cancel_ask_done <= 1'b1;
                    end

                    if (cancel_bid_done && cancel_ask_done) begin
                        order_ready <= 1'b1;
                        state       <= kStateIdle;
                    end
                end

                default: begin
                    order_ready <= 1'b1;
                    state       <= kStateIdle;
                end
            endcase
        end
    end

endmodule
