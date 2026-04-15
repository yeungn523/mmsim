/**
 * @file
 *
 * @brief Provides a unit testbench for the price_level_store module, verifying insert, consume,
 * cancel, sort order, FIFO ordering, and full/empty edge cases.
 */

`timescale 1ns/1ps

module tb_price_level_store;

    localparam kClockPeriod = 20;
    localparam kDepth       = 8;
    localparam kMaxOrders   = 16;
    localparam kPriceWidth      = 32;
    localparam kQuantityWidth   = 16;
    localparam kOrderIdWidth    = 16;

    // Command codes (must match the price_level_store module)
    localparam kCommandNop     = 3'd0;
    localparam kCommandInsert  = 3'd1;
    localparam kCommandConsume = 3'd2;
    localparam kCommandCancel  = 3'd3;

    reg                        clock;
    reg                        reset_n;
    reg  [2:0]                 command;
    reg  [kPriceWidth-1:0]     command_price;
    reg  [kQuantityWidth-1:0]  command_quantity;
    reg  [kOrderIdWidth-1:0]   command_order_id;
    reg                        command_valid;
    wire                       command_ready;

    wire [kOrderIdWidth-1:0]   response_order_id;
    wire [kQuantityWidth-1:0]  response_quantity;
    wire                       response_valid;
    wire                       response_found;

    wire [kPriceWidth-1:0]     best_price;
    wire [kQuantityWidth-1:0]  best_quantity;
    wire                       best_valid;
    wire                       full;

    integer pass_count;
    integer fail_count;
    integer test_number;

    price_level_store #(
        .kDepth         (kDepth),
        .kMaxOrders     (kMaxOrders),
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth),
        .kIsBid         (1)
    ) dut_bid (
        .clk               (clock),
        .rst_n             (reset_n),
        .command           (command),
        .command_price     (command_price),
        .command_quantity  (command_quantity),
        .command_order_id  (command_order_id),
        .command_valid     (command_valid),
        .command_ready     (command_ready),
        .response_order_id (response_order_id),
        .response_quantity (response_quantity),
        .response_valid    (response_valid),
        .response_found    (response_found),
        .best_price        (best_price),
        .best_quantity     (best_quantity),
        .best_valid        (best_valid),
        .full              (full)
    );

    initial clock = 0;
    always #(kClockPeriod / 2) clock = ~clock;

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
            reset_n          <= 1'b0;
            command_valid    <= 1'b0;
            command          <= kCommandNop;
            command_price    <= 0;
            command_quantity <= 0;
            command_order_id <= 0;
            tick_n(4);
            reset_n <= 1'b1;
            tick_n(2);
        end
    endtask

    /// Submits a command and waits for the store to complete processing.
    task submit_command;
        input [2:0]                target_command;
        input [kPriceWidth-1:0]    target_price;
        input [kQuantityWidth-1:0] target_quantity;
        input [kOrderIdWidth-1:0]  target_order_id;
        integer timeout;
        begin
            timeout = 0;
            while (!command_ready && timeout < 200) begin
                tick;
                timeout = timeout + 1;
            end

            if (timeout >= 200) begin
                $display("[FAIL] submit_command: command_ready timeout");
                fail_count = fail_count + 1;
            end

            command          <= target_command;
            command_price    <= target_price;
            command_quantity <= target_quantity;
            command_order_id <= target_order_id;
            command_valid    <= 1'b1;
            tick;
            command_valid <= 1'b0;

            timeout = 0;
            while (!command_ready && timeout < 200) begin
                tick;
                timeout = timeout + 1;
            end

            if (timeout >= 200) begin
                $display("[FAIL] submit_command: completion timeout");
                fail_count = fail_count + 1;
            end
            tick;
        end
    endtask

    task PASS;
        input [255:0] name;
        begin
            $display("[PASS] Test %0d: %0s", test_number, name);
            pass_count = pass_count + 1;
        end
    endtask

    task FAIL;
        input [255:0] name;
        input [63:0]  got;
        input [63:0]  expected;
        begin
            $display("[FAIL] Test %0d: %0s  (got=%0d, expected=%0d)", test_number, name, got, expected);
            fail_count = fail_count + 1;
        end
    endtask

    initial begin
        $dumpfile("price_level_store_tb.vcd");
        $dumpvars(0, tb_price_level_store);

        pass_count = 0;
        fail_count = 0;

        // Test 1: Verifies that the book is empty after reset
        test_number = 1;
        do_reset;
        if (!best_valid && !full)
            PASS("Reset: book empty, not full");
        else
            FAIL("Reset: book empty", {31'b0, best_valid}, 0);

        // Test 2: Verifies that a single insertion becomes the best price
        test_number = 2;
        submit_command(kCommandInsert, 32'd100, 16'd10, 16'd1);
        if (best_valid && best_price == 32'd100 && best_quantity == 16'd10)
            PASS("Single insert: best=100 quantity=10");
        else
            FAIL("Single insert", best_price, 100);

        // Test 3: Verifies that a higher bid price becomes the new best
        test_number = 3;
        submit_command(kCommandInsert, 32'd110, 16'd5, 16'd2);
        if (best_price == 32'd110 && best_quantity == 16'd5)
            PASS("Higher price becomes new best bid");
        else
            FAIL("Higher price best", best_price, 110);

        // Test 4: Verifies that a lower bid price does not change the best
        test_number = 4;
        submit_command(kCommandInsert, 32'd90, 16'd20, 16'd3);
        if (best_price == 32'd110 && best_quantity == 16'd5)
            PASS("Lower price: best unchanged");
        else
            FAIL("Lower price best unchanged", best_price, 110);

        // Test 5: Verifies that inserting at the same price aggregates quantity
        test_number = 5;
        submit_command(kCommandInsert, 32'd110, 16'd15, 16'd4);
        if (best_price == 32'd110 && best_quantity == 16'd20)
            PASS("Same price: quantity aggregated to 20");
        else
            FAIL("Same price aggregate", best_quantity, 20);

        // Test 6: Verifies that a partial consume reduces the best quantity
        test_number = 6;
        submit_command(kCommandConsume, 32'd0, 16'd3, 16'd0);
        if (best_price == 32'd110 && best_quantity == 16'd17)
            PASS("Partial consume: best quantity now 17");
        else
            FAIL("Partial consume", best_quantity, 17);

        // Test 7: Verifies that consuming an entire level promotes the next best
        test_number = 7;
        submit_command(kCommandConsume, 32'd0, 16'd17, 16'd0);
        if (best_valid && best_price == 32'd100 && best_quantity == 16'd10)
            PASS("Full consume: level removed, next best=100");
        else
            FAIL("Full consume level remove", best_price, 100);

        // Test 8: Verifies that cancelling a known order identifier succeeds
        test_number = 8;
        submit_command(kCommandCancel, 32'd0, 16'd0, 16'd1);
        if (response_found && response_order_id == 16'd1)
            PASS("Cancel order_id=1 found");
        else
            FAIL("Cancel order_id=1", response_found, 1);

        // Test 9: Verifies the book state after cancelling the only order at a price level
        test_number = 9;
        if (best_valid && best_price == 32'd90 && best_quantity == 16'd20)
            PASS("After cancel: best=90 quantity=20");
        else
            FAIL("After cancel best", best_price, 90);

        // Test 10: Verifies that cancelling a nonexistent order identifier reports not found
        test_number = 10;
        submit_command(kCommandCancel, 32'd0, 16'd0, 16'd99);
        if (!response_found)
            PASS("Cancel nonexistent: not found");
        else
            FAIL("Cancel nonexistent", response_found, 0);

        // Test 11: Verifies that consuming from an empty book produces no error
        test_number = 11;
        submit_command(kCommandConsume, 32'd0, 16'd20, 16'd0);
        submit_command(kCommandConsume, 32'd0, 16'd5, 16'd0);
        if (!best_valid)
            PASS("Consume from empty: book empty");
        else
            FAIL("Consume from empty", best_valid, 0);

        // Test 12: Verifies that filling all price level slots maintains correct sort order
        test_number = 12;
        do_reset;
        begin : fill_block
            integer price_index;
            for (price_index = 0; price_index < kDepth; price_index = price_index + 1) begin
                submit_command(kCommandInsert, (price_index + 1) * 10, 16'd1, price_index[15:0]);
            end
        end
        if (best_price == kDepth * 10 && best_quantity == 16'd1)
            PASS("Fill all levels: best price correct");
        else
            FAIL("Fill all levels", best_price, kDepth * 10);

        // Test 13: Verifies that inserting a new level when all slots are full is rejected
        test_number = 13;
        submit_command(kCommandInsert, 32'd5, 16'd1, 16'd100);
        if (best_price == kDepth * 10)
            PASS("Book full: extra level rejected");
        else
            FAIL("Book full rejection", best_price, kDepth * 10);

        // Test 14: Verifies FIFO ordering by consuming orders at the same price level
        test_number = 14;
        do_reset;
        submit_command(kCommandInsert, 32'd500, 16'd10, 16'd201);
        submit_command(kCommandInsert, 32'd500, 16'd20, 16'd202);
        submit_command(kCommandInsert, 32'd500, 16'd30, 16'd203);
        submit_command(kCommandConsume, 32'd0, 16'd10, 16'd0);
        if (response_order_id == 16'd201)
            PASS("FIFO: first consume returns order_id=201");
        else
            FAIL("FIFO order", response_order_id, 201);

        // Test 15: Verifies aggregate quantity after consuming the first FIFO order
        test_number = 15;
        if (best_quantity == 16'd50)
            PASS("After FIFO consume: quantity=50 remaining");
        else
            FAIL("FIFO remaining quantity", best_quantity, 50);

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
        #(kClockPeriod * 50000);
        $display("[FAIL] Watchdog timeout -- simulation hung");
        $finish;
    end

endmodule
