/**
 * @file
 *
 * @brief Provides a CSV-driven testbench for the price_level_store module.
 *
 * Reads command sequences from lob_commands.csv, replays each command against the DUT, and
 * writes the DUT's actual responses and book state to lob_actual.csv. A Python script then
 * diffs lob_actual.csv against lob_expected.csv (produced by the golden model) to verify
 * functional equivalence.
 *
 * File format for lob_commands.csv (header row + data rows):
 *     command,price,quantity,order_id
 *     1,100,25,1
 *     2,0,20,0
 *     3,0,0,2
 *
 * File format for lob_actual.csv (written by this testbench):
 *     command,price,quantity,order_id,response_order_id,response_quantity,response_found,
 *     best_price,best_quantity,best_valid
 */

`timescale 1ns/1ps

module tb_price_level_store_csv;

    localparam kClockPeriod    = 20;
    localparam kDepth          = 8;
    localparam kMaxOrders      = 16;
    localparam kPriceWidth     = 32;
    localparam kQuantityWidth  = 16;
    localparam kOrderIdWidth   = 16;
    localparam kOrderIdWidth   = 16;

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

    price_level_store #(
        .kDepth         (kDepth),
        .kMaxOrders     (kMaxOrders),
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth),
        .kIsBid         (1),
        .kPriceRange    (16)
    ) dut (
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

    // File handles
    integer input_file;
    integer output_file;

    // Per-row fields read from CSV
    integer read_command;
    integer read_price;
    integer read_quantity;
    integer read_order_id;

    // Scan result and row counter
    integer scan_result;
    integer row_count;
    integer timeout;

    // Temporary string for skipping the header line
    reg [8*256-1:0] header_line;

    initial begin
        $dumpfile("price_level_store_csv_tb.vcd");
        $dumpvars(0, tb_price_level_store_csv);

        // Opens the input commands file
        input_file = $fopen("lob_commands.csv", "r");
        if (input_file == 0) begin
            $display("[ERROR] Cannot open lob_commands.csv -- run the golden model first");
            $finish;
        end

        // Opens the output file for actual DUT responses
        output_file = $fopen("lob_actual.csv", "w");
        if (output_file == 0) begin
            $display("[ERROR] Cannot open lob_actual.csv for writing");
            $finish;
        end

        // Writes the CSV header to the output file
        $fwrite(output_file,
            "command,price,quantity,order_id,response_order_id,response_quantity,response_found,best_price,best_quantity,best_valid\n"
        );

        // Skips the input CSV header line
        scan_result = $fgets(header_line, input_file);

        // Resets the DUT
        reset_n       <= 1'b0;
        command_valid <= 1'b0;
        command       <= 3'd0;
        command_price <= 0;
        command_quantity <= 0;
        command_order_id <= 0;
        tick_n(4);
        reset_n <= 1'b1;
        tick_n(2);

        row_count = 0;

        // Reads and replays each command from the CSV
        while (!$feof(input_file)) begin
            scan_result = $fscanf(input_file, "%d,%d,%d,%d\n",
                read_command, read_price, read_quantity, read_order_id);

            if (scan_result != 4) begin
                // Skips malformed or empty lines
                if (!$feof(input_file))
                    $display("[WARNING] Skipped malformed line at row %0d (scan_result=%0d)",
                             row_count, scan_result);
            end else begin
                // Waits for the DUT to be ready
                timeout = 0;
                while (!command_ready && timeout < 500) begin
                    tick;
                    timeout = timeout + 1;
                end

                if (timeout >= 500) begin
                    $display("[ERROR] command_ready timeout at row %0d", row_count);
                    $finish;
                end

                // Drives the command
                command          <= read_command[2:0];
                command_price    <= read_price[kPriceWidth-1:0];
                command_quantity <= read_quantity[kQuantityWidth-1:0];
                command_order_id <= read_order_id[kOrderIdWidth-1:0];
                command_valid    <= 1'b1;
                tick;
                command_valid <= 1'b0;

                // Waits for response_valid to pulse and latches the response fields
                timeout = 0;
                while (!response_valid && timeout < 500) begin
                    tick;
                    timeout = timeout + 1;
                end
                if (timeout >= 500) begin
                    $display("[ERROR] response_valid timeout at row %0d", row_count);
                    $finish;
                end

                // Writes the DUT's actual response to the output CSV
                $fwrite(output_file, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    read_command,
                    read_price,
                    read_quantity,
                    read_order_id,
                    response_order_id,
                    response_quantity,
                    response_found,
                    best_price,
                    best_quantity,
                    best_valid
                );

                row_count = row_count + 1;

                // Waits for command_ready before accepting the next command
                timeout = 0;
                while (!command_ready && timeout < 500) begin
                    tick;
                    timeout = timeout + 1;
                end
                if (timeout >= 500) begin
                    $display("[ERROR] command_ready timeout at row %0d", row_count);
                    $finish;
                end
                tick;

                // Writes the DUT's actual response to the output CSV
                $fwrite(output_file, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    read_command,
                    read_price,
                    read_quantity,
                    read_order_id,
                    response_order_id,
                    response_quantity,
                    response_found,
                    best_price,
                    best_quantity,
                    best_valid
                );

                row_count = row_count + 1;
            end
        end

        $fclose(input_file);
        $fclose(output_file);

        $display("");
        $display("CSV replay complete: %0d commands processed", row_count);
        $display("  Input:  lob_commands.csv");
        $display("  Output: lob_actual.csv");
        $display("  Run the golden model to diff: verify_against_verilog(expected, actual)");
        $display("");
        $finish;
    end

    // Terminates the simulation if the testbench exceeds the expected runtime
    initial begin
        #(kClockPeriod * 200000);
        $display("[ERROR] Watchdog timeout -- simulation hung");
        $finish;
    end

endmodule
