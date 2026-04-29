`timescale 1ns/1ns

///
/// @file tick_window_aggregator.v
/// @brief Aggregates per-window min/max trade prices and emits one sample per fixed wall-clock window.
///
/// Anchors windows to wall clock rather than trade count so each chart column covers the same elapsed time. Bursty
/// windows show wide min/max spans, quiet windows show narrow ones, and every trade contributes to its window's span.
///

module tick_window_aggregator #(
    parameter integer kWindowCycles = 50000,               ///< Cycles per sample window (50000 @ 50 MHz = 1 ms/column).
    parameter [31:0]  kPriceInit    = 32'h64000000         ///< Q8.24 seed used at reset and on empty windows ($100).
)(
    input  wire        clk,                                ///< Source clock (matching engine domain).
    input  wire        rst_n,                              ///< Active-low asynchronous reset.
    input  wire        trade_valid,                        ///< Single-cycle pulse on each executed trade.
    input  wire [31:0] trade_price,                        ///< Q8.24 price for the trade landing this cycle.
    output reg  [31:0] window_min_price,                   ///< Minimum price observed in the just-closed window.
    output reg  [31:0] window_max_price,                   ///< Maximum price observed in the just-closed window.
    output reg         window_valid                        ///< Asserts for one cycle when window_min/max are valid.
);

    localparam integer kCounterWidth = (kWindowCycles <= 1) ? 1 : $clog2(kWindowCycles);

    // Holds the running min/max for the in-progress window. The seen flag lets the first trade overwrite kPriceInit.
    reg [kCounterWidth-1:0] cycle_counter;
    reg [31:0]              acc_min_price;
    reg [31:0]              acc_max_price;
    reg                     acc_seen_trade;

    // Merges the arriving trade into min/max so a trade on the closing cycle joins the current window.
    wire [31:0] merged_min  = (!acc_seen_trade)            ? trade_price :
                              (trade_price < acc_min_price) ? trade_price : acc_min_price;
    wire [31:0] merged_max  = (!acc_seen_trade)            ? trade_price :
                              (trade_price > acc_max_price) ? trade_price : acc_max_price;
    wire        merged_seen = acc_seen_trade | trade_valid;

    wire        window_end  = (cycle_counter == kWindowCycles[kCounterWidth-1:0] - 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter    <= {kCounterWidth{1'b0}};
            acc_min_price    <= kPriceInit;
            acc_max_price    <= kPriceInit;
            acc_seen_trade   <= 1'b0;
            window_min_price <= kPriceInit;
            window_max_price <= kPriceInit;
            window_valid     <= 1'b0;
        end else begin
            window_valid <= window_end;

            if (window_end) begin
                // Holds the prior reading on empty windows so the chart shows a flat segment instead of a gap.
                window_min_price <= merged_seen ? (trade_valid ? merged_min : acc_min_price) : window_min_price;
                window_max_price <= merged_seen ? (trade_valid ? merged_max : acc_max_price) : window_max_price;
                acc_min_price    <= kPriceInit;
                acc_max_price    <= kPriceInit;
                acc_seen_trade   <= 1'b0;
                cycle_counter    <= {kCounterWidth{1'b0}};
            end else begin
                cycle_counter <= cycle_counter + 1'b1;
                if (trade_valid) begin
                    acc_min_price  <= merged_min;
                    acc_max_price  <= merged_max;
                    acc_seen_trade <= 1'b1;
                end
            end
        end
    end

endmodule
