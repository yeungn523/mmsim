`timescale 1ns/1ps

// Pipelined CSV testbench for the matching_engine. Issues packets back-to-back whenever the
// engine asserts order_ready, then logs one CSV row per retired packet using order_retire_valid
// and the engine's per-packet trade aggregates.
//   matching_engine_actual.csv        -- post-packet book snapshot, one row per packet
//   matching_engine_trades_actual.csv -- one row per trade pulse

module tb_matching_engine_csv;

    localparam kClockPeriod   = 20;
    localparam kPriceWidth    = 32;
    localparam kQuantityWidth = 16;
    localparam kPriceRange    = 480;
    localparam kQueueDepth    = 65536;

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

    wire                       order_retire_valid;
    wire [kQuantityWidth-1:0]  order_retire_trade_count;
    wire [kQuantityWidth-1:0]  order_retire_fill_quantity;

    matching_engine #(
        .kPriceWidth      (kPriceWidth),
        .kQuantityWidth   (kQuantityWidth),
        .kPriceRange      (kPriceRange),
        .kAcceptFifoDepth (32)
    ) dut (
        .clk                        (clock),
        .rst_n                      (reset_n),
        .order_packet               (order_packet),
        .order_valid                (order_valid),
        .order_ready                (order_ready),
        .trade_price                (trade_price),
        .trade_quantity             (trade_quantity),
        .trade_side                 (trade_side),
        .trade_valid                (trade_valid),
        .last_trade_price           (last_trade_price),
        .last_trade_price_valid     (last_trade_price_valid),
        .best_bid_price             (best_bid_price),
        .best_bid_quantity          (best_bid_quantity),
        .best_bid_valid             (best_bid_valid),
        .best_ask_price             (best_ask_price),
        .best_ask_quantity          (best_ask_quantity),
        .best_ask_valid             (best_ask_valid),
        .order_retire_valid         (order_retire_valid),
        .order_retire_trade_count   (order_retire_trade_count),
        .order_retire_fill_quantity (order_retire_fill_quantity)
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

    // In-flight packet queue. Issuance enqueues at issue_tail; the retire pulse advances
    // issue_head. Stage B and Stage C serialize handoff via the B-to-C register, so packets
    // retire in the order they were issued.
    reg [31:0] issued_packets [0:kQueueDepth-1];
    integer    issue_head;
    integer    issue_tail;
    integer    trade_index;

    // Throughput counters, sampled across the full run for the end-of-sim summary.
    integer    busy_cycles;       ///< Cycles elapsed between reset release and final retire.
    integer    issue_count;       ///< Cycles on which a packet was accepted into the FIFO.
    integer    retire_count;      ///< Packets that completed Stage C.
    integer    backpressure_cycles; ///< Cycles the engine deasserted order_ready (FIFO full).
    integer    trade_pulse_count; ///< Total trade_valid pulses observed.

    integer packets_file;
    integer actual_file;
    integer trades_file;
    integer throughput_file;
    integer scan_result;
    integer current_step;
    reg [8*512-1:0] header_line;
    reg [31:0] read_packet;

    // Logs every trade pulse and writes one row per retired packet. A trade pulse coincident
    // with a retire belongs to the packet just becoming head, so the step lookup shifts.
    always @(posedge clock) begin
        if (!reset_n) begin
            issue_head          <= 0;
            trade_index         <= 0;
            busy_cycles         <= 0;
            issue_count         <= 0;
            retire_count        <= 0;
            backpressure_cycles <= 0;
            trade_pulse_count   <= 0;
        end else begin
            busy_cycles <= busy_cycles + 1;
            if (order_valid && order_ready) issue_count <= issue_count + 1;
            if (!order_ready)               backpressure_cycles <= backpressure_cycles + 1;
            if (order_retire_valid)         retire_count <= retire_count + 1;
            if (trade_valid)                trade_pulse_count <= trade_pulse_count + 1;

            if (trade_valid) begin
                $fwrite(trades_file, "%0d,%0d,%0d,%0d,%0d\n",
                    order_retire_valid ? (issue_head + 1) : issue_head,
                    order_retire_valid ? 0 : trade_index,
                    trade_price,
                    trade_quantity,
                    trade_side);
            end

            if (order_retire_valid) begin
                $fwrite(actual_file,
                    "%0d,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    issue_head,
                    issued_packets[issue_head],
                    issued_packets[issue_head][31],
                    issued_packets[issue_head][30],
                    issued_packets[issue_head][29:28],
                    issued_packets[issue_head][24:16],
                    issued_packets[issue_head][15:0],
                    order_retire_trade_count,
                    order_retire_fill_quantity,
                    best_bid_price,
                    best_bid_quantity,
                    best_bid_valid,
                    best_ask_price,
                    best_ask_quantity,
                    best_ask_valid,
                    last_trade_price,
                    last_trade_price_valid);
                issue_head  <= issue_head + 1;
                trade_index <= trade_valid ? 1 : 0;
            end else if (trade_valid) begin
                trade_index <= trade_index + 1;
            end
        end
    end

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
            "last_trade_price,last_trade_price_valid\n"
        );
        $fwrite(trades_file, "step,trade_index,trade_price,trade_quantity,trade_side\n");

        scan_result = $fgets(header_line, packets_file);

        reset_n      <= 1'b0;
        order_valid  <= 1'b0;
        order_packet <= 32'd0;
        current_step  = 0;
        issue_tail    = 0;
        tick_n(4);
        reset_n <= 1'b1;
        tick_n(2);

        // Drives a packet every cycle the engine accepts one. The Accept FIFO smooths bursts.
        while (!$feof(packets_file)) begin
            while (!order_ready) tick;

            scan_result = $fscanf(packets_file, "%h\n", read_packet);
            if (scan_result != 1) begin
                if (!$feof(packets_file))
                    $display("[WARNING] Skipped malformed line at step %0d", current_step);
            end else begin
                issued_packets[issue_tail] = read_packet;
                issue_tail   = issue_tail + 1;
                current_step = current_step + 1;

                order_packet <= read_packet;
                order_valid  <= 1'b1;
                tick;
                order_valid  <= 1'b0;
            end
        end

        // Drain: waits for every issued packet to retire through Stage C.
        while (issue_head < issue_tail) tick;
        tick_n(4);

        $fclose(packets_file);
        $fclose(actual_file);
        $fclose(trades_file);

        // Mirror the throughput numbers to a CSV alongside stdout, so they survive even when
        // ModelSim's stdout pipe is buffered or routed to its transcript instead.
        throughput_file = $fopen("matching_engine_throughput.csv", "w");
        if (throughput_file != 0) begin
            $fwrite(throughput_file, "metric,value\n");
            $fwrite(throughput_file, "busy_cycles,%0d\n",         busy_cycles);
            $fwrite(throughput_file, "packets_issued,%0d\n",      issue_count);
            $fwrite(throughput_file, "packets_retired,%0d\n",     retire_count);
            $fwrite(throughput_file, "trade_pulses,%0d\n",        trade_pulse_count);
            $fwrite(throughput_file, "backpressure_cycles,%0d\n", backpressure_cycles);
            $fclose(throughput_file);
        end

        $display("");
        $display("CSV replay complete: %0d packets processed", current_step);
        $display("  Input:  matching_engine_packets.csv");
        $display("  Output: matching_engine_actual.csv");
        $display("  Output: matching_engine_trades_actual.csv");
        $display("  Output: matching_engine_throughput.csv");
        $display("");
        $display("Throughput summary:");
        $display("  Busy cycles            : %0d", busy_cycles);
        $display("  Packets issued         : %0d", issue_count);
        $display("  Packets retired        : %0d", retire_count);
        $display("  Trade pulses           : %0d", trade_pulse_count);
        $display("  Backpressure cycles    : %0d (order_ready = 0)", backpressure_cycles);
        if (busy_cycles > 0) begin
            $display("  Issue rate             : %0d packets per 1000 cycles",
                (issue_count * 1000) / busy_cycles);
            $display("  Retire rate            : %0d packets per 1000 cycles",
                (retire_count * 1000) / busy_cycles);
        end
        if (retire_count > 0) begin
            $display("  Avg cycles per packet  : %0d.%03d",
                busy_cycles / retire_count,
                ((busy_cycles % retire_count) * 1000) / retire_count);
        end
        $finish;
    end

    initial begin
        #(kClockPeriod * 5000000);
        $display("[ERROR] Watchdog timeout -- simulation hung");
        $finish;
    end

endmodule
