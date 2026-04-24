`timescale 1ns/1ps

module tb_market_maker;

    // Runtime parameters. kSkewEnable is overridden via -gkSkewEnable on the vsim command line
    // to select between the v1 (fixed spread) and v2 (inventory-skewed) market maker policies.
    parameter       kSkewEnable     = 1'b0;   ///< Market maker policy switch (0=v1, 1=v2).
    parameter integer kRunCycles    = 10000;  ///< Total simulated cycles after reset releases.
    parameter integer kClockPeriod  = 20;     ///< Clock period in simulation time units.

    // DUT bus widths. Must match the engine and market maker module parameters.
    parameter integer kPriceWidth    = 32;
    parameter integer kQuantityWidth = 16;
    parameter integer kOrderIdWidth  = 16;
    parameter integer kPriceRange    = 2048;
    parameter integer kDepth         = 16;
    parameter integer kMaxOrders     = 256;

    // Reserved order_id block for noise counterparty orders. Kept disjoint from the market
    // maker's reserved block so the DUT can attribute fills unambiguously.
    parameter [kOrderIdWidth-1:0] kNoiseOrderIdBase = 16'd50000;

    // Clock and reset
    reg clock;
    reg reset_n;

    // Matching engine order port (driven by the mux below)
    reg  [2:0]                  engine_order_type;
    reg  [kOrderIdWidth-1:0]    engine_order_id;
    reg  [kPriceWidth-1:0]      engine_order_price;
    reg  [kQuantityWidth-1:0]   engine_order_quantity;
    reg                         engine_order_valid;
    wire                        engine_order_ready;

    // Matching engine outputs
    wire [kOrderIdWidth-1:0]    trade_aggressor_id;
    wire [kOrderIdWidth-1:0]    trade_resting_id;
    wire [kPriceWidth-1:0]      trade_price;
    wire [kQuantityWidth-1:0]   trade_quantity;
    wire                        trade_valid;

    wire [kPriceWidth-1:0]      best_bid_price;
    wire [kQuantityWidth-1:0]   best_bid_quantity;
    wire                        best_bid_valid;
    wire [kPriceWidth-1:0]      best_ask_price;
    wire [kQuantityWidth-1:0]   best_ask_quantity;
    wire                        best_ask_valid;

    wire [31:0]                 total_trades;
    wire [31:0]                 total_volume;

    // Market maker submission bus (before mux)
    wire                        mm_order_request;
    wire [2:0]                  mm_order_type;
    wire [kOrderIdWidth-1:0]    mm_order_id;
    wire [kPriceWidth-1:0]      mm_order_price;
    wire [kQuantityWidth-1:0]   mm_order_quantity;

    // Grant wire driven by the mux back to the market maker
    reg                         mm_order_grant;

    // Per-cycle noise event loaded from noise_events.csv
    reg                         noise_fire;
    reg                         noise_is_buy;
    reg [kQuantityWidth-1:0]    noise_qty;
    reg [kOrderIdWidth-1:0]     noise_next_id;

    // Matching engine DUT
    matching_engine #(
        .kDepth         (kDepth),
        .kMaxOrders     (kMaxOrders),
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth),
        .kPriceRange    (kPriceRange)
    ) engine (
        .clk                (clock),
        .rst_n              (reset_n),
        .order_type         (engine_order_type),
        .order_id           (engine_order_id),
        .order_price        (engine_order_price),
        .order_quantity     (engine_order_quantity),
        .order_valid        (engine_order_valid),
        .order_ready        (engine_order_ready),
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

    // Market maker DUT
    market_maker #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kOrderIdWidth  (kOrderIdWidth),
        .kPriceRange    (kPriceRange),
        .kSkewEnable    (kSkewEnable)
    ) dut_mm (
        .clk                (clock),
        .rst_n              (reset_n),
        .best_bid_price     (best_bid_price),
        .best_bid_quantity  (best_bid_quantity),
        .best_bid_valid     (best_bid_valid),
        .best_ask_price     (best_ask_price),
        .best_ask_quantity  (best_ask_quantity),
        .best_ask_valid     (best_ask_valid),
        .trade_valid        (trade_valid),
        .trade_aggressor_id (trade_aggressor_id),
        .trade_resting_id   (trade_resting_id),
        .trade_price        (trade_price),
        .trade_quantity     (trade_quantity),
        .order_request      (mm_order_request),
        .order_grant        (mm_order_grant),
        .order_type         (mm_order_type),
        .order_id           (mm_order_id),
        .order_price        (mm_order_price),
        .order_quantity     (mm_order_quantity)
    );

    // Mux that routes either the market maker or the noise counterparty onto the engine's
    // single order port. The market maker wins priority when it requests; otherwise the noise
    // counterparty submits if it has a scheduled fire this cycle. This replaces a standalone
    // synthesizable arbiter module with testbench-internal combinational logic.
    always @(*) begin
        mm_order_grant        = 1'b0;
        engine_order_valid    = 1'b0;
        engine_order_type     = 3'd0;
        engine_order_id       = {kOrderIdWidth{1'b0}};
        engine_order_price    = {kPriceWidth{1'b0}};
        engine_order_quantity = {kQuantityWidth{1'b0}};

        if (mm_order_request && engine_order_ready) begin
            engine_order_type     = mm_order_type;
            engine_order_id       = mm_order_id;
            engine_order_price    = mm_order_price;
            engine_order_quantity = mm_order_quantity;
            engine_order_valid    = 1'b1;
            mm_order_grant        = 1'b1;
        end else if (noise_fire && engine_order_ready) begin
            engine_order_type     = noise_is_buy ? 3'd3 : 3'd4;  // 3=MARKET_BUY, 4=MARKET_SELL
            engine_order_id       = noise_next_id;
            engine_order_price    = {kPriceWidth{1'b0}};
            engine_order_quantity = noise_qty;
            engine_order_valid    = 1'b1;
        end
    end

    // Clock generation
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

    // File descriptors and per-cycle state
    integer noise_file;
    integer log_file;
    integer orders_file;
    integer read_fire;
    integer read_is_buy;
    integer read_size;
    integer scan_result;
    integer cycle_counter;
    reg [8*512-1:0] header_line;

    // Per-cycle logger. Writes the engine's book state, trade bus, and MM bookkeeping every
    // cycle after reset has released. Captures MM orders separately only when granted this cycle.
    always @(posedge clock) begin
        if (reset_n) begin
            $fwrite(log_file,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cycle_counter,
                best_bid_price, best_bid_quantity, best_bid_valid,
                best_ask_price, best_ask_quantity, best_ask_valid,
                trade_valid, trade_aggressor_id, trade_resting_id,
                trade_price, trade_quantity,
                $signed(dut_mm.net_inventory), dut_mm.state
            );
            if (mm_order_grant) begin
                $fwrite(orders_file, "%0d,%0d,%0d,%0d,%0d\n",
                    cycle_counter,
                    mm_order_type, mm_order_id,
                    mm_order_price, mm_order_quantity
                );
            end
        end
    end

    initial begin
        noise_file = $fopen("noise_events.csv", "r");
        if (noise_file == 0) begin
            $display("[ERROR] Cannot open noise_events.csv -- run the orchestrator stage 1 first");
            $finish;
        end

        log_file = $fopen("run_log.csv", "w");
        if (log_file == 0) begin
            $display("[ERROR] Cannot open run_log.csv for writing");
            $finish;
        end

        orders_file = $fopen("actual_orders.csv", "w");
        if (orders_file == 0) begin
            $display("[ERROR] Cannot open actual_orders.csv for writing");
            $finish;
        end

        $fwrite(log_file,
            "cycle,best_bid_price,best_bid_quantity,best_bid_valid,"
            "best_ask_price,best_ask_quantity,best_ask_valid,"
            "trade_valid,trade_aggressor_id,trade_resting_id,trade_price,trade_quantity,"
            "mm_net_inventory,mm_state\n"
        );
        $fwrite(orders_file, "cycle,order_type,order_id,order_price,order_quantity\n");

        // Skip the CSV header row
        scan_result = $fgets(header_line, noise_file);

        reset_n       = 1'b0;
        noise_fire    = 1'b0;
        noise_is_buy  = 1'b0;
        noise_qty     = {kQuantityWidth{1'b0}};
        noise_next_id = kNoiseOrderIdBase;
        cycle_counter = 0;

        tick_n(4);
        reset_n = 1'b1;

        while (cycle_counter < kRunCycles) begin
            // Loads the next noise event before the clock edge so the mux sees fresh values.
            // Defaults to no-fire on end-of-file or malformed rows so remaining cycles still run.
            if (!$feof(noise_file)) begin
                scan_result = $fscanf(noise_file, "%d,%d,%d\n",
                    read_fire, read_is_buy, read_size);
                if (scan_result == 3 && read_fire != 0) begin
                    noise_fire   = 1'b1;
                    noise_is_buy = (read_is_buy != 0);
                    noise_qty    = read_size[kQuantityWidth-1:0];
                end else begin
                    noise_fire = 1'b0;
                end
            end else begin
                noise_fire = 1'b0;
            end

            tick;

            // Advances the noise ID only when a noise order actually won the mux this cycle so
            // IDs stay gap-free and match the Python NoiseCounterparty's allocation.
            if (noise_fire && engine_order_ready && !mm_order_request) begin
                noise_next_id = noise_next_id + 16'd1;
            end

            cycle_counter = cycle_counter + 1;
        end

        $fclose(noise_file);
        $fclose(log_file);
        $fclose(orders_file);
        $display("[INFO] tb_market_maker complete. Cycles=%0d, kSkewEnable=%0d",
                 cycle_counter, kSkewEnable);
        $finish;
    end

endmodule
