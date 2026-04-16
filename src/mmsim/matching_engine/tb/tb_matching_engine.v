/**
 * @file
 *
 * @brief Provides a unit testbench for the matching_engine module, verifying trade execution,
 * book insertion, price-time priority, market order handling, partial fills, and cancellations.
 */

`timescale 1ns/1ps

module tb_matching_engine;

    localparam kClockPeriod    = 20;
    localparam kDepth          = 8;
    localparam kMaxOrders      = 16;
    localparam kPriceWidth     = 32;
    localparam kQuantityWidth  = 16;
    localparam kOrderIdWidth   = 16;

    // Order type codes (must match matching_engine)
    localparam kTypeLimitBuy   = 3'd1;
    localparam kTypeLimitSell  = 3'd2;
    localparam kTypeMarketBuy  = 3'd3;
    localparam kTypeMarketSell = 3'd4;
    localparam kTypeCancel     = 3'd5;

    reg                        clock;
    reg                        reset_n;

    reg  [2:0]                 order_type;
    reg  [kOrderIdWidth-1:0]   order_id;
    reg  [kPriceWidth-1:0]     order_price;
    reg  [kQuantityWidth-1:0]  order_quantity;
    reg                        order_valid;
    wire                       order_ready;

    wire [kOrderIdWidth-1:0]   trade_aggressor_id;
    wire [kOrderIdWidth-1:0]   trade_resting_id;
    wire [kPriceWidth-1:0]     trade_price;
    wire [kQuantityWidth-1:0]  trade_quantity;
    wire                       trade_valid;

    wire [kPriceWidth-1:0]     best_bid_price;
    wire [kQuantityWidth-1:0]  best_bid_quantity;
    wire                       best_bid_valid;
    wire [kPriceWidth-1:0]     best_ask_price;
    wire [kQuantityWidth-1:0]  best_ask_quantity;
    wire                       best_ask_valid;

    wire [31:0]                total_trades;
    wire [31:0]                total_volume;

    integer pass_count;
    integer fail_count;
    integer test_number;

    // Captures the most recent trade for verification
    reg [kOrderIdWidth-1:0]    last_trade_aggressor;
    reg [kOrderIdWidth-1:0]    last_trade_resting;
    reg [kPriceWidth-1:0]      last_trade_price;
    reg [kQuantityWidth-1:0]   last_trade_quantity;
    reg                        trade_occurred;

    matching_engine #(
        .kDepth         (kDepth),
        .kMaxOrders     (kMaxOrders),
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth)
    ) dut (
        .clk                (clock),
        .rst_n             (reset_n),
        .order_type        (order_type),
        .order_id          (order_id),
        .order_price       (order_price),
        .order_quantity    (order_quantity),
        .order_valid       (order_valid),
        .order_ready       (order_ready),
        .trade_aggressor_id (trade_aggressor_id),
        .trade_resting_id  (trade_resting_id),
        .trade_price       (trade_price),
        .trade_quantity    (trade_quantity),
        .trade_valid       (trade_valid),
        .best_bid_price    (best_bid_price),
        .best_bid_quantity (best_bid_quantity),
        .best_bid_valid    (best_bid_valid),
        .best_ask_price    (best_ask_price),
        .best_ask_quantity (best_ask_quantity),
        .best_ask_valid    (best_ask_valid),
        .total_trades      (total_trades),
        .total_volume      (total_volume)
    );

    initial clock = 0;
    always #(kClockPeriod / 2) clock = ~clock;

    // Captures trade events as they occur
    always @(posedge clock) begin
        if (trade_valid) begin
            last_trade_aggressor <= trade_aggressor_id;
            last_trade_resting   <= trade_resting_id;
            last_trade_price     <= trade_price;
            last_trade_quantity  <= trade_quantity;
            trade_occurred       <= 1'b1;
        end
    end

    task tick;
        @(posedge clock); #1;
    endtask

    task tick_n;
        input integer count;
        integer iteration;
        begin
            for (iteration = 0; iteration < count; iteration = iteration + 1) tick;
        end
    endtask

    task do_reset;
        begin
            reset_n       <= 1'b0;
            order_valid   <= 1'b0;
            order_type    <= 3'd0;
            order_id      <= 0;
            order_price   <= 0;
            order_quantity <= 0;
            trade_occurred <= 1'b0;
            tick_n(4);
            reset_n <= 1'b1;
            tick_n(2);
        end
    endtask

    /// Submits an order and waits for the engine to finish processing it.
    task submit_order;
        input [2:0]                target_type;
        input [kOrderIdWidth-1:0]  target_id;
        input [kPriceWidth-1:0]    target_price;
        input [kQuantityWidth-1:0] target_quantity;
        integer timeout;
        begin
            // Waits for the engine to be ready
            timeout = 0;
            while (!order_ready && timeout < 500) begin
                tick;
                timeout = timeout + 1;
            end
            if (timeout >= 500) begin
                $display("[FAIL] submit_order: order_ready timeout");
                fail_count = fail_count + 1;
            end

            trade_occurred <= 1'b0;

            order_type     <= target_type;
            order_id       <= target_id;
            order_price    <= target_price;
            order_quantity <= target_quantity;
            order_valid    <= 1'b1;
            tick;
            order_valid <= 1'b0;

            // Waits for the engine to finish processing
            timeout = 0;
            while (!order_ready && timeout < 500) begin
                tick;
                timeout = timeout + 1;
            end
            if (timeout >= 500) begin
                $display("[FAIL] submit_order: completion timeout");
                fail_count = fail_count + 1;
            end
            tick;
        end
    endtask

    task PASS;
        input [511:0] name;
        begin
            $display("[PASS] Test %0d: %0s", test_number, name);
            pass_count = pass_count + 1;
        end
    endtask

    task FAIL;
        input [511:0] name;
        input [63:0]  got;
        input [63:0]  expected;
        begin
            $display("[FAIL] Test %0d: %0s  (got=%0d, expected=%0d)", test_number, name, got, expected);
            fail_count = fail_count + 1;
        end
    endtask

    initial begin
        $dumpfile("matching_engine_tb.vcd");
        $dumpvars(0, tb_matching_engine);

        pass_count = 0;
        fail_count = 0;

        // Test 1: Verifies that both books are empty after reset
        test_number = 1;
        do_reset;
        if (!best_bid_valid && !best_ask_valid && total_trades == 0)
            PASS("Reset: both books empty, zero trades");
        else
            FAIL("Reset state", best_bid_valid, 0);

        // Test 2: Inserts a limit buy, verifies it rests in the bid book
        test_number = 2;
        submit_order(kTypeLimitBuy, 16'd1, 32'd100, 16'd50);
        if (best_bid_valid && best_bid_price == 32'd100 && best_bid_quantity == 16'd50
            && !best_ask_valid && !trade_occurred)
            PASS("Limit buy rests in bid book, no trade");
        else
            FAIL("Limit buy rest", best_bid_price, 100);

        // Test 3: Inserts a limit sell above the bid, verifies no trade
        test_number = 3;
        submit_order(kTypeLimitSell, 16'd2, 32'd110, 16'd30);
        if (best_ask_valid && best_ask_price == 32'd110 && best_ask_quantity == 16'd30
            && best_bid_price == 32'd100 && !trade_occurred)
            PASS("Limit sell above bid: no trade, both sides populated");
        else
            FAIL("Limit sell no trade", best_ask_price, 110);

        // Test 4: Sends a sell at the bid price, verifies a trade at the resting bid's price
        test_number = 4;
        submit_order(kTypeLimitSell, 16'd3, 32'd100, 16'd20);
        if (trade_occurred && last_trade_price == 32'd100 && last_trade_quantity == 16'd20
            && last_trade_aggressor == 16'd3 && last_trade_resting == 16'd1)
            PASS("Sell at bid price: trade at 100, qty=20");
        else
            FAIL("Sell at bid trade", last_trade_price, 100);

        // Test 5: Verifies the bid book's remaining quantity after partial fill
        test_number = 5;
        if (best_bid_valid && best_bid_price == 32'd100 && best_bid_quantity == 16'd30)
            PASS("Bid remainder: 30 shares at 100");
        else
            FAIL("Bid remainder", best_bid_quantity, 30);

        // Test 6: Sends a sell below the bid, verifies trade at the resting bid's price
        test_number = 6;
        submit_order(kTypeLimitSell, 16'd4, 32'd95, 16'd10);
        if (trade_occurred && last_trade_price == 32'd100 && last_trade_quantity == 16'd10)
            PASS("Sell below bid: trade at resting price 100");
        else
            FAIL("Sell below bid", last_trade_price, 100);

        // Test 7: Sends a buy above the ask, verifies trade at the resting ask's price
        test_number = 7;
        submit_order(kTypeLimitBuy, 16'd5, 32'd120, 16'd15);
        if (trade_occurred && last_trade_price == 32'd110 && last_trade_quantity == 16'd15)
            PASS("Buy above ask: trade at resting price 110");
        else
            FAIL("Buy above ask", last_trade_price, 110);

        // Test 8: Verifies the ask book's remaining quantity
        test_number = 8;
        if (best_ask_valid && best_ask_price == 32'd110 && best_ask_quantity == 16'd15)
            PASS("Ask remainder: 15 shares at 110");
        else
            FAIL("Ask remainder", best_ask_quantity, 15);

        // Test 9: Market buy consumes from the ask book
        test_number = 9;
        submit_order(kTypeMarketBuy, 16'd6, 32'd0, 16'd10);
        if (trade_occurred && last_trade_price == 32'd110 && last_trade_quantity == 16'd10)
            PASS("Market buy: traded 10 at ask price 110");
        else
            FAIL("Market buy", last_trade_price, 110);

        // Test 10: Market sell consumes from the bid book
        test_number = 10;
        submit_order(kTypeMarketSell, 16'd7, 32'd0, 16'd5);
        if (trade_occurred && last_trade_price == 32'd100 && last_trade_quantity == 16'd5)
            PASS("Market sell: traded 5 at bid price 100");
        else
            FAIL("Market sell", last_trade_price, 100);

        // Test 11: Market buy with no ask book results in no trade and order discarded
        test_number = 11;
        do_reset;
        submit_order(kTypeLimitBuy, 16'd10, 32'd100, 16'd50);
        submit_order(kTypeMarketBuy, 16'd11, 32'd0, 16'd20);
        if (!trade_occurred && best_bid_valid && best_bid_quantity == 16'd50)
            PASS("Market buy with empty ask: no trade, order discarded");
        else
            FAIL("Market buy empty ask", trade_occurred, 0);

        // Test 12: Cancels a resting bid order
        test_number = 12;
        submit_order(kTypeCancel, 16'd10, 32'd0, 16'd0);
        if (!best_bid_valid)
            PASS("Cancel bid order: bid book now empty");
        else
            FAIL("Cancel bid", best_bid_valid, 0);

        // Test 13: Sweeps multiple ask price levels with a large buy
        test_number = 13;
        do_reset;
        submit_order(kTypeLimitSell, 16'd20, 32'd100, 16'd10);
        submit_order(kTypeLimitSell, 16'd21, 32'd105, 16'd15);
        submit_order(kTypeLimitSell, 16'd22, 32'd110, 16'd20);

        // Sends a buy that should sweep all three levels (10 + 15 + 20 = 45, buying 30)
        submit_order(kTypeLimitBuy, 16'd23, 32'd110, 16'd30);
        // Should have consumed 10@100 + 15@105 + 5@110
        if (total_trades == 3 && total_volume == 30)
            PASS("Multi-level sweep: 3 trades, 30 total volume");
        else
            FAIL("Multi-level sweep trades", total_trades, 3);

        // Test 14: Verifies the ask book state after the sweep
        test_number = 14;
        if (best_ask_valid && best_ask_price == 32'd110 && best_ask_quantity == 16'd15)
            PASS("After sweep: ask remainder 15 at 110");
        else
            FAIL("After sweep ask", best_ask_quantity, 15);

        // Test 15: Verifies the buy order was fully filled (no bid book entry)
        test_number = 15;
        if (!best_bid_valid)
            PASS("Aggressive buy fully filled: no bid book entry");
        else
            FAIL("Buy fully filled", best_bid_valid, 0);

        // Test 16: Partial sweep with remainder inserted into the book
        test_number = 16;
        do_reset;
        submit_order(kTypeLimitSell, 16'd30, 32'd100, 16'd10);
        submit_order(kTypeLimitBuy, 16'd31, 32'd105, 16'd25);
        // Should trade 10@100, then insert remaining 15@105 into bid book
        if (best_bid_valid && best_bid_price == 32'd105 && best_bid_quantity == 16'd15)
            PASS("Partial match: remainder 15 rests in bid book at 105");
        else
            FAIL("Partial match remainder", best_bid_quantity, 15);

        // Test 17: Verifies trade statistics accumulate correctly
        test_number = 17;
        if (total_trades == 1 && total_volume == 10)
            PASS("Statistics: 1 trade, 10 volume");
        else
            FAIL("Statistics", total_trades, 1);

        // Test 18: Cancel a nonexistent order does not corrupt the book
        test_number = 18;
        submit_order(kTypeCancel, 16'd9999, 32'd0, 16'd0);
        if (best_bid_valid && best_bid_price == 32'd105 && best_bid_quantity == 16'd15)
            PASS("Cancel nonexistent: book unchanged");
        else
            FAIL("Cancel nonexistent", best_bid_quantity, 15);

        $display("");
        $display("=========================================");
        $display("  RESULTS: %0d passed, %0d failed", pass_count, fail_count);
        $display("=========================================");
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("");
        $finish;
    end

    // Terminates the simulation if the testbench exceeds the expected runtime
    initial begin
        #(kClockPeriod * 100000);
        $display("[FAIL] Watchdog timeout -- simulation hung");
        $finish;
    end

endmodule
