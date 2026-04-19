/**
 * @file
 *
 * @brief Provides a CSV-driven testbench for the matching_engine module.
 *
 * Reads order packets from matching_engine_orders.csv, replays each order against the DUT, and
 * writes trade executions to matching_engine_trades_actual.csv and the post-order book state to
 * matching_engine_book_state_actual.csv. A Python script diffs the actual CSVs against the
 * expected CSVs (produced by the golden model) to verify functional equivalence.
 *
 * Input CSV format (matching_engine_orders.csv):
 *     order_type,order_id,price,quantity
 *
 * Output CSV formats:
 *     matching_engine_trades_actual.csv:
 *         step,aggressor_id,resting_id,trade_price,trade_quantity
 *     matching_engine_book_state_actual.csv:
 *         step,order_type,order_id,order_price,order_quantity,
 *         best_bid_price,best_bid_quantity,best_bid_valid,
 *         best_ask_price,best_ask_quantity,best_ask_valid,
 *         total_trades,total_volume
 */

`timescale 1ns/1ps

module tb_matching_engine_csv;

    localparam kClockPeriod    = 20;
    localparam kDepth          = 8;
    localparam kMaxOrders      = 16;
    localparam kPriceWidth     = 32;
    localparam kQuantityWidth  = 16;
    localparam kOrderIdWidth   = 16;

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

    matching_engine #(
        .kDepth         (kDepth),
        .kMaxOrders     (kMaxOrders),
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth)
    ) dut (
        .clk                (clock),
        .rst_n              (reset_n),
        .order_type         (order_type),
        .order_id           (order_id),
        .order_price        (order_price),
        .order_quantity     (order_quantity),
        .order_valid        (order_valid),
        .order_ready        (order_ready),
        .trade_aggressor_id (trade_aggressor_id),
        .trade_resting_id   (trade_resting_id),
        .trade_price        (trade_price),
        .trade_quantity     (trade_quantity),
        .trade_valid        (trade_valid),
        .best_bid_price     (best_bid_price),
        .best_bid_quantity  (best_bid_quantity),
        .best_bid_valid     (best_bid_valid),
        .best_ask_price     (best_ask_price),
        .best_ask_quantity  (best_ask_quantity),
        .best_ask_valid     (best_ask_valid),
        .total_trades       (total_trades),
        .total_volume       (total_volume)
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

    // Captures trade executions live into the trades CSV as they occur
    integer trades_file;
    integer current_step;

    always @(posedge clock) begin
        if (trade_valid && reset_n) begin
            $fwrite(trades_file, "%0d,%0d,%0d,%0d,%0d\n",
                current_step,
                trade_aggressor_id,
                trade_resting_id,
                trade_price,
                trade_quantity
            );
        end
    end

    integer input_file;
    integer book_state_file;
    integer read_order_type;
    integer read_order_id;
    integer read_price;
    integer read_quantity;
    integer scan_result;
    integer timeout;
    reg [8*256-1:0] header_line;

    initial begin
        $dumpfile("matching_engine_csv_tb.vcd");
        $dumpvars(0, tb_matching_engine_csv);

        input_file = $fopen("matching_engine_orders.csv", "r");
        if (input_file == 0) begin
            $display("[ERROR] Cannot open matching_engine_orders.csv -- run the golden model first");
            $finish;
        end

        trades_file = $fopen("matching_engine_trades_actual.csv", "w");
        if (trades_file == 0) begin
            $display("[ERROR] Cannot open matching_engine_trades_actual.csv for writing");
            $finish;
        end

        book_state_file = $fopen("matching_engine_book_state_actual.csv", "w");
        if (book_state_file == 0) begin
            $display("[ERROR] Cannot open matching_engine_book_state_actual.csv for writing");
            $finish;
        end

        $fwrite(trades_file,
            "step,aggressor_id,resting_id,trade_price,trade_quantity\n");
        $fwrite(book_state_file,
            "step,order_type,order_id,order_price,order_quantity,best_bid_price,best_bid_quantity,best_bid_valid,best_ask_price,best_ask_quantity,best_ask_valid,total_trades,total_volume\n");

        scan_result = $fgets(header_line, input_file);

        reset_n        <= 1'b0;
        order_valid    <= 1'b0;
        order_type     <= 3'd0;
        order_id       <= 0;
        order_price    <= 0;
        order_quantity <= 0;
        current_step   = 0;
        tick_n(4);
        reset_n <= 1'b1;
        tick_n(2);

        while (!$feof(input_file)) begin
            scan_result = $fscanf(input_file, "%d,%d,%d,%d\n",
                read_order_type, read_order_id, read_price, read_quantity);

            if (scan_result != 4) begin
                if (!$feof(input_file))
                    $display("[WARNING] Skipped malformed line at step %0d (scan_result=%0d)",
                             current_step, scan_result);
            end else begin
                timeout = 0;
                while (!order_ready && timeout < 5000) begin
                    tick;
                    timeout = timeout + 1;
                end
                if (timeout >= 5000) begin
                    $display("[ERROR] order_ready timeout at step %0d", current_step);
                    $finish;
                end

                order_type     <= read_order_type[2:0];
                order_id       <= read_order_id[kOrderIdWidth-1:0];
                order_price    <= read_price[kPriceWidth-1:0];
                order_quantity <= read_quantity[kQuantityWidth-1:0];
                order_valid    <= 1'b1;
                tick;
                order_valid <= 1'b0;

                timeout = 0;
                while (!order_ready && timeout < 5000) begin
                    tick;
                    timeout = timeout + 1;
                end
                if (timeout >= 5000) begin
                    $display("[ERROR] Completion timeout at step %0d", current_step);
                    $finish;
                end
                tick;

                // Writes the post-order book state to the book state CSV
                $fwrite(book_state_file, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    current_step,
                    read_order_type,
                    read_order_id,
                    read_price,
                    read_quantity,
                    best_bid_price,
                    best_bid_quantity,
                    best_bid_valid,
                    best_ask_price,
                    best_ask_quantity,
                    best_ask_valid,
                    total_trades,
                    total_volume
                );

                current_step = current_step + 1;
            end
        end

        $fclose(input_file);
        $fclose(trades_file);
        $fclose(book_state_file);

        $display("");
        $display("CSV replay complete: %0d orders processed", current_step);
        $display("  Input:  matching_engine_orders.csv");
        $display("  Output: matching_engine_trades_actual.csv");
        $display("  Output: matching_engine_book_state_actual.csv");
        $display("");
        $finish;
    end

    // Terminates the simulation if the testbench exceeds the expected runtime
    initial begin
        #(kClockPeriod * 500000);
        $display("[ERROR] Watchdog timeout -- simulation hung");
        $finish;
    end

endmodule
