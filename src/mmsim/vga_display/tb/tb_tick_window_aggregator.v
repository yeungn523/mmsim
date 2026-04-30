`timescale 1ns/1ns

///
/// @file tb_tick_window_aggregator.v
/// @brief Self-checking test for tick_window_aggregator's window boundaries.
///
/// Four checks:
///   1. First trade overrides kPriceInit -- a single trade in the first window sets min == max to that trade's price.
///   2. Multi-trade window -- min/max equal the actual extremes across all in-window trades.
///   3. Closing-cycle trade joins window -- a trade arriving on the same cycle as window_end is included in that
///      window's min/max rather than rolling forward into the next window.
///   4. Empty window holds prior reading -- a window with no trades does not emit a stale kPriceInit; window_min/max
///      persist from the prior closed window so the chart stays flat instead of dropping a gap.
///
/// ModelSim:
///   vlog tick_window_aggregator.v tb_tick_window_aggregator.v
///   vsim -c -do "run -all; quit -f" tb_tick_window_aggregator
///

module tb_tick_window_aggregator;
    localparam integer kWindowCycles = 8;             // Small window for quick coverage.
    localparam [31:0]  kPriceInit    = 32'h64000000;  // $100 in Q8.24.
    localparam integer kClockPeriod  = 20;

    reg         clk;
    reg         rst_n;
    reg         trade_valid;
    reg  [31:0] trade_price;
    wire [31:0] window_min_price;
    wire [31:0] window_max_price;
    wire        window_valid;

    initial clk = 0;
    always #(kClockPeriod / 2) clk = ~clk;

    tick_window_aggregator #(
        .kWindowCycles (kWindowCycles),
        .kPriceInit    (kPriceInit)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .trade_valid      (trade_valid),
        .trade_price      (trade_price),
        .window_min_price (window_min_price),
        .window_max_price (window_max_price),
        .window_valid     (window_valid)
    );

    integer fail_count;

    task check_eq;
        input [31:0]  actual;
        input [31:0]  expected;
        input [255:0] label;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s -- expected %h, got %h", label, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Drives one trade pulse on the negedge so the DUT samples it cleanly on the next posedge.
    task fire_trade;
        input [31:0] price;
        begin
            @(negedge clk);
            trade_valid = 1'b1;
            trade_price = price;
            @(negedge clk);
            trade_valid = 1'b0;
            trade_price = 32'h0;
        end
    endtask

    // Advances one cycle without firing a trade.
    task idle_cycle;
        begin
            @(negedge clk);
            trade_valid = 1'b0;
        end
    endtask

    // Waits for the next window_valid pulse and stops on the cycle after it asserts so the captured outputs reflect
    // the closed window's results rather than the still-running accumulation.
    task wait_window_close;
        begin
            @(posedge window_valid);
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        fail_count  = 0;
        rst_n       = 1'b0;
        trade_valid = 1'b0;
        trade_price = 32'h0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Test 1: single trade overrides kPriceInit. Fires one trade early in the first window and lets it close
        // afterwards so the captured min/max reflect the trade rather than the reset seed.
        fire_trade(32'h62000000);  // $98
        repeat (kWindowCycles) idle_cycle;
        wait_window_close;
        check_eq(window_min_price, 32'h62000000, "first-window single-trade min");
        check_eq(window_max_price, 32'h62000000, "first-window single-trade max");

        // Test 2: multi-trade window. Fires three trades with distinct prices and checks that min/max bracket them.
        fire_trade(32'h64000000);  // $100, expected max
        fire_trade(32'h61000000);  // $97, expected min
        fire_trade(32'h63000000);  // $99
        repeat (kWindowCycles) idle_cycle;
        wait_window_close;
        check_eq(window_min_price, 32'h61000000, "multi-trade window min");
        check_eq(window_max_price, 32'h64000000, "multi-trade window max");

        // Test 3: trade on the closing cycle joins the current window. Idles down to one cycle before window_end then
        // fires on the boundary, expecting the new price to set min/max for the window that's about to close.
        repeat (kWindowCycles - 1) idle_cycle;
        fire_trade(32'h67000000);  // $103, only trade in this window
        wait_window_close;
        check_eq(window_min_price, 32'h67000000, "closing-cycle trade joins window (min)");
        check_eq(window_max_price, 32'h67000000, "closing-cycle trade joins window (max)");

        // Test 4: empty window holds prior reading. Lets a full window pass with no trades and confirms the previous
        // window's min/max persist instead of resetting to kPriceInit so the chart draws a flat segment.
        repeat (kWindowCycles) idle_cycle;
        wait_window_close;
        check_eq(window_min_price, 32'h67000000, "empty-window holds prior min");
        check_eq(window_max_price, 32'h67000000, "empty-window holds prior max");

        if (fail_count == 0) $display("=== PASS ===");
        else                 $display("=== FAIL: %0d check(s) failed ===", fail_count);
        $finish;
    end

endmodule
