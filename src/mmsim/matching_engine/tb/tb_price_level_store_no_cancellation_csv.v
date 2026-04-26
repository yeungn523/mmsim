`timescale 1ns/1ns

module tb_price_level_store_no_cancellation_csv;

    localparam kClockPeriod    = 20;
    localparam kPriceWidth     = 32;
    localparam kQuantityWidth  = 16;
    localparam kPriceRange     = 480;

    reg                        clock;
    reg                        reset_n;
    reg  [1:0]                 command;
    reg  [kPriceWidth-1:0]     command_price;
    reg  [kQuantityWidth-1:0]  command_quantity;
    reg                        command_valid;
    wire                       command_ready;

    wire [kQuantityWidth-1:0]  response_quantity;
    wire                       response_valid;

    wire [kPriceWidth-1:0]     best_price;
    wire [kQuantityWidth-1:0]  best_quantity;
    wire                       best_valid;

    price_level_store #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kIsBid         (1),
        .kPriceRange    (kPriceRange)
    ) dut (
        .clk               (clock),
        .rst_n             (reset_n),
        .command           (command),
        .command_price     (command_price),
        .command_quantity  (command_quantity),
        .command_valid     (command_valid),
        .command_ready     (command_ready),
        .response_quantity (response_quantity),
        .response_valid    (response_valid),
        .best_price        (best_price),
        .best_quantity     (best_quantity),
        .best_valid        (best_valid)
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

    integer input_file;
    integer output_file;
    integer read_command;
    integer read_price;
    integer read_quantity;
    integer scan_result;
    integer row_count;
    integer timeout;
    integer latency;
    integer total_latency;
    integer max_latency;
    integer max_latency_row;
    reg [8*256-1:0] header_line;

    initial begin
        $dumpfile("price_level_store_no_cancellation_csv_tb.vcd");
        $dumpvars(0, tb_price_level_store_no_cancellation_csv);

        input_file = $fopen("lob_no_cancellation_commands.csv", "r");
        if (input_file == 0) begin
            $display("[ERROR] Cannot open lob_no_cancellation_commands.csv -- run the golden model first");
            $finish;
        end

        output_file = $fopen("lob_no_cancellation_actual.csv", "w");
        if (output_file == 0) begin
            $display("[ERROR] Cannot open lob_no_cancellation_actual.csv for writing");
            $finish;
        end

        $fwrite(output_file,
            "command,price,quantity,response_quantity,best_price,best_quantity,best_valid\n"
        );

        scan_result = $fgets(header_line, input_file);

        reset_n          <= 1'b0;
        command_valid    <= 1'b0;
        command          <= 2'd0;
        command_price    <= 0;
        command_quantity <= 0;
        tick_n(4);
        reset_n <= 1'b1;
        tick_n(2);

        row_count       = 0;
        total_latency   = 0;
        max_latency     = 0;
        max_latency_row = 0;

        while (!$feof(input_file)) begin
            scan_result = $fscanf(input_file, "%d,%d,%d\n",
                read_command, read_price, read_quantity);

            if (scan_result != 3) begin
                if (!$feof(input_file))
                    $display("[WARNING] Skipped malformed line at row %0d (scan_result=%0d)",
                             row_count, scan_result);
            end else begin
                timeout = 0;
                while (!command_ready && timeout < 500) begin
                    tick;
                    timeout = timeout + 1;
                end
                if (timeout >= 500) begin
                    $display("[ERROR] command_ready timeout before row %0d", row_count);
                    $finish;
                end

                command          <= read_command[1:0];
                command_price    <= read_price[kPriceWidth-1:0];
                command_quantity <= read_quantity[kQuantityWidth-1:0];
                command_valid    <= 1'b1;
                tick;
                command_valid <= 1'b0;

                latency = 1;
                timeout = 0;
                while (!response_valid && timeout < 500) begin
                    tick;
                    timeout = timeout + 1;
                    latency = latency + 1;
                end
                if (timeout >= 500) begin
                    $display("[ERROR] response_valid timeout at row %0d", row_count);
                    $finish;
                end

                $display("[ROW %0d] cmd=%0d  price=%0d  qty=%0d  latency=%0d cycles",
                    row_count, read_command, read_price, read_quantity, latency);

                total_latency = total_latency + latency;
                if (latency > max_latency) begin
                    max_latency     = latency;
                    max_latency_row = row_count;
                end

                tick;

                $fwrite(output_file, "%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    read_command,
                    read_price,
                    read_quantity,
                    response_quantity,
                    best_price,
                    best_quantity,
                    best_valid
                );

                row_count = row_count + 1;

                timeout = 0;
                while (!command_ready && timeout < 500) begin
                    tick;
                    timeout = timeout + 1;
                end
                if (timeout >= 500) begin
                    $display("[ERROR] command_ready timeout after row %0d", row_count - 1);
                    $finish;
                end
                tick;
            end
        end

        $fclose(input_file);
        $fclose(output_file);

        $display("");
        $display("CSV replay complete: %0d commands processed", row_count);
        $display("  Input:  lob_no_cancellation_commands.csv");
        $display("  Output: lob_no_cancellation_actual.csv");
        $display("");
        $display("Latency summary:");
        $display("  Total cycles: %0d", total_latency);
        if (row_count > 0) begin
            $display("  Avg latency:  %0d cycles", total_latency / row_count);
        end
        $display("  Max latency:  %0d cycles (row %0d)", max_latency, max_latency_row);
        $finish;
    end

    initial begin
        #(kClockPeriod * 200000);
        $display("[ERROR] Watchdog timeout -- simulation hung");
        $finish;
    end

endmodule
