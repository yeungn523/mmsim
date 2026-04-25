`timescale 1ns/1ps

// CSV-driven testbench for the matching_engine module. Reads raw 32-bit packet values from
// matching_engine_packets.csv, replays each against the DUT, and writes two outputs:
//   matching_engine_actual.csv        -- post-packet book snapshot, one row per packet
//   matching_engine_trades_actual.csv -- one row per trade pulse, for cross-check with the
//                                        golden model's trade_expected CSV

module tb_matching_engine_csv;

    localparam kClockPeriod   = 20;
    localparam kPriceWidth    = 32;
    localparam kQuantityWidth = 16;
    localparam kPriceRange    = 480;

    reg                        clock;
    reg                        reset_n;

    reg  [31:0]                order_packet;
    reg                        order_valid;
    wire                       order_ready;

    wire [kPriceWidth-1:0]     trade_price;
    wire [kQuantityWidth-1:0]  trade_quantity;
    wire                       trade_side;
    wire                       trade_valid;
    wire [kPriceWidth-1:0]     last_trade_price;
    wire                       last_trade_price_valid;

    wire [kPriceWidth-1:0]     best_bid_price;
    wire [kQuantityWidth-1:0]  best_bid_quantity;
    wire                       best_bid_valid;
    wire [kPriceWidth-1:0]     best_ask_price;
    wire [kQuantityWidth-1:0]  best_ask_quantity;
    wire                       best_ask_valid;

    wire [31:0]                total_trades;
    wire [31:0]                total_volume;

    matching_engine #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kPriceRange    (kPriceRange)
    ) dut (
        .clk                (clock),
        .rst_n              (reset_n),
        .order_packet       (order_packet),
        .order_valid        (order_valid),
        .order_ready        (order_ready),
        .trade_price            (trade_price),
        .trade_quantity         (trade_quantity),
        .trade_side             (trade_side),
        .trade_valid            (trade_valid),
        .last_trade_price       (last_trade_price),
        .last_trade_price_valid (last_trade_price_valid),
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
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) tick;
        end
    endtask

    // Per-trade logging. Counts trades within a single packet so the CSV's trade_index matches
    // the golden model's convention.
    integer trades_file;
    integer current_step;
    integer trade_index;
    reg     in_packet;

    always @(posedge clock) begin
        if (reset_n && trade_valid) begin
            $fwrite(trades_file, "%0d,%0d,%0d,%0d,%0d\n",
                current_step, trade_index, trade_price, trade_quantity, trade_side);
            trade_index <= trade_index + 1;
        end
    end

    integer packets_file;
    integer actual_file;
    integer scan_result;
    integer timeout;
    integer trade_count;
    integer total_fill_quantity;
    reg [8*512-1:0] header_line;
    reg [31:0] read_packet;

    initial begin
        $dumpfile("matching_engine_csv_tb.vcd");
        $dumpvars(0, tb_matching_engine_csv);

        packets_file = $fopen("matching_engine_packets.csv", "r");
        if (packets_file == 0) begin
            $display("[ERROR] Cannot open matching_engine_packets.csv -- run the golden model first");
            $finish;
        end

        actual_file = $fopen("matching_engine_actual.csv", "w");
        if (actual_file == 0) begin
            $display("[ERROR] Cannot open matching_engine_actual.csv for writing");
            $finish;
        end

        trades_file = $fopen("matching_engine_trades_actual.csv", "w");
        if (trades_file == 0) begin
            $display("[ERROR] Cannot open matching_engine_trades_actual.csv for writing");
            $finish;
        end

        $fwrite(actual_file,
            "step,packet_hex,side,order_type,agent_type,price,volume,"
            "trade_count,total_fill_quantity,"
            "best_bid_price,best_bid_quantity,best_bid_valid,"
            "best_ask_price,best_ask_quantity,best_ask_valid,"
            "last_trade_price,last_trade_price_valid,"
            "total_trades,total_volume\n"
        );
        $fwrite(trades_file, "step,trade_index,trade_price,trade_quantity,trade_side\n");

        // Skip header
        scan_result = $fgets(header_line, packets_file);

        reset_n       <= 1'b0;
        order_valid   <= 1'b0;
        order_packet  <= 32'd0;
        current_step   = 0;
        trade_index    = 0;
        trade_count    = 0;
        total_fill_quantity = 0;
        tick_n(4);
        reset_n <= 1'b1;
        tick_n(2);

        while (!$feof(packets_file)) begin
            scan_result = $fscanf(packets_file, "%h\n", read_packet);
            if (scan_result != 1) begin
                if (!$feof(packets_file))
                    $display("[WARNING] Skipped malformed line at step %0d", current_step);
            end else begin
                // Resets the per-packet trade counters before driving.
                trade_index        = 0;
                trade_count        = 0;
                total_fill_quantity = 0;

                // Waits for the engine to be ready, then drives the packet.
                timeout = 0;
                while (!order_ready && timeout < 2000) begin
                    tick;
                    timeout = timeout + 1;
                end

                order_packet <= read_packet;
                order_valid  <= 1'b1;
                tick;
                order_valid  <= 1'b0;

                // Waits for the engine to complete (order_ready returns high) while capturing
                // any trade pulses into the trades CSV via the always block above.
                timeout = 0;
                while (!order_ready && timeout < 2000) begin
                    tick;
                    if (trade_valid) begin
                        trade_count         = trade_count + 1;
                        total_fill_quantity = total_fill_quantity + trade_quantity;
                    end
                    timeout = timeout + 1;
                end
                if (timeout >= 2000) begin
                    $display("[ERROR] Packet processing timeout at step %0d", current_step);
                    $finish;
                end

                // Extra settle tick so book-state outputs reflect the last write.
                tick;

                $fwrite(actual_file,
                    "%0d,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    current_step,
                    read_packet,
                    read_packet[31],
                    read_packet[30],
                    read_packet[29:28],
                    read_packet[24:16],
                    read_packet[15:0],
                    trade_count,
                    total_fill_quantity,
                    best_bid_price,
                    best_bid_quantity,
                    best_bid_valid,
                    best_ask_price,
                    best_ask_quantity,
                    best_ask_valid,
                    last_trade_price,
                    last_trade_price_valid,
                    total_trades,
                    total_volume
                );

                current_step = current_step + 1;
            end
        end

        $fclose(packets_file);
        $fclose(actual_file);
        $fclose(trades_file);

        $display("");
        $display("CSV replay complete: %0d packets processed", current_step);
        $display("  Input:  matching_engine_packets.csv");
        $display("  Output: matching_engine_actual.csv");
        $display("  Output: matching_engine_trades_actual.csv");
        $finish;
    end

    initial begin
        #(kClockPeriod * 500000);
        $display("[ERROR] Watchdog timeout -- simulation hung");
        $finish;
    end

endmodule
