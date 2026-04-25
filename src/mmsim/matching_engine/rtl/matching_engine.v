`timescale 1ns/1ps

///
/// @file matching_engine.v
/// @brief Matches agent order packets against a two-sided limit order book backed by two
///        price_level_store_no_cancellation instances.
///
/// Order packet layout (must match agent_execution_unit.v):
///   bit  [31]       side        (0 = buy, 1 = sell)
///   bit  [30]       order_type  (0 = limit, 1 = market)
///   bits [29:28]    agent_type  (unused by the engine, carried through for observability)
///   bits [27:25]    reserved
///   bits [24:16]    price       (9-bit tick index, 0..kPriceRange-1)
///   bits [15:0]     volume      (16-bit unsigned share count)
///

module matching_engine #(
    parameter kPriceWidth    = 32,    ///< Bit width of the internal price field.
    parameter kQuantityWidth = 16,    ///< Bit width of the quantity field.
    parameter kPriceRange    = 480    ///< Number of addressable price ticks.
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Order packet input (valid/ready handshake).
    input  wire [31:0]                 order_packet,         ///< Packed agent order packet.
    input  wire                        order_valid,          ///< Asserts when order_packet is fresh.
    output reg                         order_ready,          ///< Asserts when the engine can accept a packet.

    // Trade execution output. One pulse per level consumed.
    output reg  [kPriceWidth-1:0]      trade_price,          ///< Execution price of this trade.
    output reg  [kQuantityWidth-1:0]   trade_quantity,       ///< Share count filled in this trade.
    output reg                         trade_side,           ///< Indicates the aggressor side: 0 = buy, 1 = sell.
    output reg                         trade_valid,          ///< Pulses high for one cycle per fill.

    // Last-trade reference. Holds the most recently executed trade price between pulses so
    // downstream agents (momentum, value) can read it without latching the trade bus themselves.
    output reg  [kPriceWidth-1:0]      last_trade_price,     ///< Most recent executed trade price.
    output reg                         last_trade_price_valid, ///< Asserts after the first trade executes.

    // Top-of-book state (combinational taps of the two book stores).
    output wire [kPriceWidth-1:0]      best_bid_price,        ///< Best resting bid price.
    output wire [kQuantityWidth-1:0]   best_bid_quantity,     ///< Aggregate share count at the best bid.
    output wire                        best_bid_valid,        ///< Asserts when at least one bid level holds shares.
    output wire [kPriceWidth-1:0]      best_ask_price,        ///< Best resting ask price.
    output wire [kQuantityWidth-1:0]   best_ask_quantity,     ///< Aggregate share count at the best ask.
    output wire                        best_ask_valid,        ///< Asserts when at least one ask level holds shares.

    // Cumulative counters for observability.
    output reg  [31:0]                 total_trades,          ///< Cumulative count of executed trades since reset.
    output reg  [31:0]                 total_volume           ///< Cumulative shares filled across all trades since reset.
);

    // Packet field decode.
    wire                       packet_side       = order_packet[31];
    wire                       packet_type       = order_packet[30];
    wire [kPriceWidth-1:0]     packet_price      = {{(kPriceWidth - 9){1'b0}}, order_packet[24:16]};
    wire [kQuantityWidth-1:0]  packet_volume     = order_packet[15:0];

    // Book command opcodes (must match price_level_store_no_cancellation).
    localparam [1:0] kCommandNop     = 2'd0;  ///< Skips the cycle without modifying the book.
    localparam [1:0] kCommandInsert  = 2'd1;  ///< Inserts a quantity at the supplied price.
    localparam [1:0] kCommandConsume = 2'd2;  ///< Consumes shares from the current best price.

    // Top-level FSM states.
    localparam [3:0] kStateIdle       = 4'd0;  ///< Waits for an incoming packet.
    localparam [3:0] kStateClassify   = 4'd1;  ///< Routes the next action based on the decoded packet.
    localparam [3:0] kStateMatchCheck = 4'd2;  ///< Inspects the opposite book for a crossable level.
    localparam [3:0] kStateMatchExec  = 4'd3;  ///< Issues a CONSUME on the opposite book.
    localparam [3:0] kStateMatchWait  = 4'd4;  ///< Awaits the consume response and emits a trade pulse.
    localparam [3:0] kStateInsert     = 4'd5;  ///< Issues an INSERT on the same-side book for limit remainder.
    localparam [3:0] kStateInsertWait = 4'd6;  ///< Awaits the insert response.

    reg [3:0] state;  ///< Holds the current top-level FSM state.

    // Latched packet fields for multi-cycle processing.
    reg                       working_is_buy;
    reg                       working_is_market;
    reg [kPriceWidth-1:0]     working_price;
    reg [kQuantityWidth-1:0]  working_remaining;
    reg [kPriceWidth-1:0]     working_trade_price;

    // Bid book interface
    reg  [1:0]                bid_command;
    reg  [kPriceWidth-1:0]    bid_command_price;
    reg  [kQuantityWidth-1:0] bid_command_quantity;
    reg                       bid_command_valid;
    wire                      bid_command_ready;
    wire [kQuantityWidth-1:0] bid_response_quantity;
    wire                      bid_response_valid;

    // Ask book interface
    reg  [1:0]                ask_command;
    reg  [kPriceWidth-1:0]    ask_command_price;
    reg  [kQuantityWidth-1:0] ask_command_quantity;
    reg                       ask_command_valid;
    wire                      ask_command_ready;
    wire [kQuantityWidth-1:0] ask_response_quantity;
    wire                      ask_response_valid;

    // Tracks whether a command is in flight so a duplicate submission never fires while the
    // store's FSM is still occupied processing the previous one.
    reg                       bid_in_flight;
    reg                       ask_in_flight;

    price_level_store_no_cancellation #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kIsBid         (1),
        .kPriceRange    (kPriceRange)
    ) bid_book (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (bid_command),
        .command_price     (bid_command_price),
        .command_quantity  (bid_command_quantity),
        .command_valid     (bid_command_valid),
        .command_ready     (bid_command_ready),
        .response_quantity (bid_response_quantity),
        .response_valid    (bid_response_valid),
        .best_price        (best_bid_price),
        .best_quantity     (best_bid_quantity),
        .best_valid        (best_bid_valid)
    );

    price_level_store_no_cancellation #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kIsBid         (0),
        .kPriceRange    (kPriceRange)
    ) ask_book (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (ask_command),
        .command_price     (ask_command_price),
        .command_quantity  (ask_command_quantity),
        .command_valid     (ask_command_valid),
        .command_ready     (ask_command_ready),
        .response_quantity (ask_response_quantity),
        .response_valid    (ask_response_valid),
        .best_price        (best_ask_price),
        .best_quantity     (best_ask_quantity),
        .best_valid        (best_ask_valid)
    );

    // Convenience wires naming the opposite side relative to the incoming order direction.
    wire [kPriceWidth-1:0] opposite_best_price = working_is_buy ? best_ask_price : best_bid_price;
    wire                   opposite_best_valid = working_is_buy ? best_ask_valid : best_bid_valid;

    // A limit buy crosses when the lowest ask is at or below the buyer's price. A limit sell
    // crosses when the highest bid is at or above the seller's price. Market orders always cross
    // whenever the opposite side holds any resting shares.
    wire limit_crosses = working_is_buy
        ? (opposite_best_price <= working_price)
        : (opposite_best_price >= working_price);
    wire can_match     = opposite_best_valid && (working_is_market || limit_crosses);

    always @(posedge clk) begin
        if (!rst_n) begin
            state                  <= kStateIdle;
            order_ready            <= 1'b1;
            trade_valid            <= 1'b0;
            trade_price            <= {kPriceWidth{1'b0}};
            trade_quantity         <= {kQuantityWidth{1'b0}};
            trade_side             <= 1'b0;
            last_trade_price       <= {kPriceWidth{1'b0}};
            last_trade_price_valid <= 1'b0;
            total_trades           <= 32'd0;
            total_volume           <= 32'd0;

            bid_command           <= kCommandNop;
            bid_command_price     <= {kPriceWidth{1'b0}};
            bid_command_quantity  <= {kQuantityWidth{1'b0}};
            bid_command_valid     <= 1'b0;
            bid_in_flight         <= 1'b0;

            ask_command           <= kCommandNop;
            ask_command_price     <= {kPriceWidth{1'b0}};
            ask_command_quantity  <= {kQuantityWidth{1'b0}};
            ask_command_valid     <= 1'b0;
            ask_in_flight         <= 1'b0;

            working_is_buy        <= 1'b0;
            working_is_market     <= 1'b0;
            working_price         <= {kPriceWidth{1'b0}};
            working_remaining     <= {kQuantityWidth{1'b0}};
            working_trade_price   <= {kPriceWidth{1'b0}};

        end else begin
            // Deasserts the single-cycle pulses by default; individual states reassert as needed.
            trade_valid       <= 1'b0;
            bid_command_valid <= 1'b0;
            ask_command_valid <= 1'b0;

            // Clears the in-flight flag when the book reasserts command_ready after completing.
            if (bid_in_flight && bid_command_ready) bid_in_flight <= 1'b0;
            if (ask_in_flight && ask_command_ready) ask_in_flight <= 1'b0;

            case (state)
                kStateIdle: begin
                    if (order_valid && order_ready) begin
                        working_is_buy    <= ~packet_side;   // packet_side 0 = buy, 1 = sell
                        working_is_market <= packet_type;    // packet_type 0 = limit, 1 = market
                        working_price     <= packet_price;
                        working_remaining <= packet_volume;
                        order_ready       <= 1'b0;
                        state             <= kStateClassify;
                    end
                end

                kStateClassify: begin
                    // Market orders always head for MatchCheck. Limit orders only try to match
                    // when they cross the spread; otherwise they go straight to insertion.
                    if (working_is_market) begin
                        state <= kStateMatchCheck;
                    end else if (opposite_best_valid && limit_crosses) begin
                        state <= kStateMatchCheck;
                    end else begin
                        state <= kStateInsert;
                    end
                end

                kStateMatchCheck: begin
                    // Drops out of the match loop when the incoming order is fully filled, the
                    // opposite side has no resting shares, or the next-best opposite price no
                    // longer crosses (relevant for limit orders only).
                    if (working_remaining == {kQuantityWidth{1'b0}}) begin
                        state <= working_is_market ? kStateIdle : kStateInsert;
                        if (working_is_market) order_ready <= 1'b1;
                    end else if (!can_match) begin
                        state <= working_is_market ? kStateIdle : kStateInsert;
                        if (working_is_market) order_ready <= 1'b1;
                    end else begin
                        state <= kStateMatchExec;
                    end
                end

                kStateMatchExec: begin
                    // Latches the opposite-side best price before issuing the consume so the
                    // trade pulse reports the fill price without needing to re-read the book.
                    working_trade_price <= opposite_best_price;

                    if (working_is_buy) begin
                        if (ask_command_ready && !ask_in_flight) begin
                            ask_command          <= kCommandConsume;
                            ask_command_price    <= {kPriceWidth{1'b0}};
                            ask_command_quantity <= working_remaining;
                            ask_command_valid    <= 1'b1;
                            ask_in_flight        <= 1'b1;
                            state                <= kStateMatchWait;
                        end
                    end else begin
                        if (bid_command_ready && !bid_in_flight) begin
                            bid_command          <= kCommandConsume;
                            bid_command_price    <= {kPriceWidth{1'b0}};
                            bid_command_quantity <= working_remaining;
                            bid_command_valid    <= 1'b1;
                            bid_in_flight        <= 1'b1;
                            state                <= kStateMatchWait;
                        end
                    end
                end

                kStateMatchWait: begin
                    if (working_is_buy && ask_response_valid) begin
                        if (ask_response_quantity != {kQuantityWidth{1'b0}}) begin
                            trade_valid            <= 1'b1;
                            trade_price            <= working_trade_price;
                            trade_quantity         <= ask_response_quantity;
                            trade_side             <= 1'b0;   // buy aggressor
                            last_trade_price       <= working_trade_price;
                            last_trade_price_valid <= 1'b1;
                            total_trades           <= total_trades + 32'd1;
                            total_volume           <= total_volume + {{(32 - kQuantityWidth){1'b0}}, ask_response_quantity};
                            working_remaining      <= working_remaining - ask_response_quantity;
                        end
                        state <= kStateMatchCheck;
                    end else if (!working_is_buy && bid_response_valid) begin
                        if (bid_response_quantity != {kQuantityWidth{1'b0}}) begin
                            trade_valid            <= 1'b1;
                            trade_price            <= working_trade_price;
                            trade_quantity         <= bid_response_quantity;
                            trade_side             <= 1'b1;   // sell aggressor
                            last_trade_price       <= working_trade_price;
                            last_trade_price_valid <= 1'b1;
                            total_trades           <= total_trades + 32'd1;
                            total_volume           <= total_volume + {{(32 - kQuantityWidth){1'b0}}, bid_response_quantity};
                            working_remaining      <= working_remaining - bid_response_quantity;
                        end
                        state <= kStateMatchCheck;
                    end
                end

                kStateInsert: begin
                    // Only reachable for limit orders. Inserts any unmatched remainder on the
                    // same-side book. Skips the insert if the remainder is zero.
                    if (working_remaining == {kQuantityWidth{1'b0}}) begin
                        order_ready <= 1'b1;
                        state       <= kStateIdle;
                    end else if (working_is_buy) begin
                        if (bid_command_ready && !bid_in_flight) begin
                            bid_command          <= kCommandInsert;
                            bid_command_price    <= working_price;
                            bid_command_quantity <= working_remaining;
                            bid_command_valid    <= 1'b1;
                            bid_in_flight        <= 1'b1;
                            state                <= kStateInsertWait;
                        end
                    end else begin
                        if (ask_command_ready && !ask_in_flight) begin
                            ask_command          <= kCommandInsert;
                            ask_command_price    <= working_price;
                            ask_command_quantity <= working_remaining;
                            ask_command_valid    <= 1'b1;
                            ask_in_flight        <= 1'b1;
                            state                <= kStateInsertWait;
                        end
                    end
                end

                kStateInsertWait: begin
                    if (working_is_buy && bid_response_valid) begin
                        order_ready <= 1'b1;
                        state       <= kStateIdle;
                    end else if (!working_is_buy && ask_response_valid) begin
                        order_ready <= 1'b1;
                        state       <= kStateIdle;
                    end
                end

                default: begin
                    state       <= kStateIdle;
                    order_ready <= 1'b1;
                end
            endcase
        end
    end

endmodule
