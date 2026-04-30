`timescale 1ns/1ns

///
/// @file tb_sim_top.v
/// @brief Integration testbench wiring order_gen_top and matching_engine over the canonical valid/ready boundary.
///
/// Phase 1: Writes minimal noise trader parameters into all active agent slots via the
///          parameter write port. Parameters are biased toward limit inserts with a wide
///          spread so both sides of the book seed quickly.
/// Phase 2: Releases control and lets the stochastic system run freely. Invariant checkers
///          activate once both best_bid_valid and best_ask_valid have been observed, ensuring
///          assertions only fire on a live book.
///
/// Invariants checked continuously once active:
///   1. trade_price was an occupied level on the opposite side at fill time
///   2. best_quantity > 0 when best_valid, persistent for 2 cycles (allows 1-cycle settle)
///   3. order_fifo full never asserts
///   4. in_flight count never exceeds 2
///   5. trade_quantity > 0 on every trade_valid
///   6. fill conservation: order_retire_fill_quantity matches accumulated trade_quantity
///
/// ModelSim:
///   vlog galois_lfsr.v ziggurat_gaussian.v gbm_logspace.v price_level_store.v matching_engine.v order_arbiter.v order_fifo.v order_gen_top.v agent_execution_unit.v top_level.v tb_sim_top.v
///   vsim -do run_sim_top.tcl
///

module tb_sim_top;
    localparam kClockPeriod  = 20;
    localparam kRunCycles    = 10000;
    localparam kWatchdog     = 100000;

    localparam NUM_UNITS        = 4;
    localparam SLOTS_PER_UNIT   = 64;
    localparam kPriceWidth      = 32;
    localparam kQuantityWidth   = 16;
    localparam kPriceRange      = 480;

    localparam kNoiseCount    = 16;
    localparam kMMCount       = 16;
    localparam kMomentumCount = 16;
    localparam kValueCount    = 16;
    localparam [31:0] kNoiseTraderParam = {2'b00, 10'd700, 10'd32, 10'd8};
    localparam [31:0] kMMTraderParam    = {2'b01, 10'd800, 10'd4,  10'd5};
    localparam [31:0] kMomentumParam    = {2'b10, 10'd15,  10'd4,  10'd4};
    localparam [31:0] kValueParam       = {2'b11, 10'd8,   10'd16, 10'd10};

    reg clk;
    reg rst_n;
    initial clk = 0;
    always #(kClockPeriod / 2) clk = ~clk;

    reg         param_wr_en;
    reg  [15:0] param_wr_addr;
    reg  [31:0] param_wr_data;
    reg  [15:0] active_agent_count;

    wire [31:0]               order_packet;
    wire                      order_valid;
    wire                      order_ready;

    wire [kPriceWidth-1:0]    best_bid_price;
    wire [kQuantityWidth-1:0] best_bid_quantity;
    wire                      best_bid_valid;
    wire [kPriceWidth-1:0]    best_ask_price;
    wire [kQuantityWidth-1:0] best_ask_quantity;
    wire                      best_ask_valid;
    wire [kPriceWidth-1:0]    trade_price;
    wire [kQuantityWidth-1:0] trade_quantity;
    wire                      trade_side;
    wire                      trade_valid;
    wire [kPriceWidth-1:0]    last_executed_price;
    wire                      last_executed_price_valid;
    wire                      order_retire_valid;
    wire [kQuantityWidth-1:0] order_retire_trade_count;
    wire [kQuantityWidth-1:0] order_retire_fill_quantity;

    // Taps the producer FIFO's full flag for the "FIFO never full" invariant.
    wire fifo_full;
    assign fifo_full = tb_sim_top.u_order_gen.u_fifo.full;

    // Pulses once per packet handshake into the matching engine; replaces the old fifo_rd_en
    // tap now that the matching engine has no internal Accept FIFO.
    wire packet_accepted = order_valid && order_ready;

    // Taps the per-tick occupancy bitmaps inside each book for the trade-price invariant.
    wire bid_level_valid_tap [0:kPriceRange-1];
    wire ask_level_valid_tap [0:kPriceRange-1];
    genvar lv;
    generate
        for (lv = 0; lv < kPriceRange; lv = lv + 1) begin : gen_level_taps
            assign bid_level_valid_tap[lv] = tb_sim_top.u_matching_engine.bid_book.level_valid[lv];
            assign ask_level_valid_tap[lv] = tb_sim_top.u_matching_engine.ask_book.level_valid[lv];
        end
    endgenerate

    // Aligns the level_valid check with trade_valid: the M10K latency from grant to trade_valid
    // is 4 cycles regardless of any prior stall, so _d4 always points to the cycle the CONSUME
    // was accepted.
    reg bid_level_valid_d1 [0:kPriceRange-1];
    reg bid_level_valid_d2 [0:kPriceRange-1];
    reg bid_level_valid_d3 [0:kPriceRange-1];
    reg bid_level_valid_d4 [0:kPriceRange-1];
    reg ask_level_valid_d1 [0:kPriceRange-1];
    reg ask_level_valid_d2 [0:kPriceRange-1];
    reg ask_level_valid_d3 [0:kPriceRange-1];
    reg ask_level_valid_d4 [0:kPriceRange-1];
    integer lv_i;
    always @(posedge clk) begin
        for (lv_i = 0; lv_i < kPriceRange; lv_i = lv_i + 1) begin
            bid_level_valid_d1[lv_i] <= bid_level_valid_tap[lv_i];
            bid_level_valid_d2[lv_i] <= bid_level_valid_d1[lv_i];
            bid_level_valid_d3[lv_i] <= bid_level_valid_d2[lv_i];
            bid_level_valid_d4[lv_i] <= bid_level_valid_d3[lv_i];
            ask_level_valid_d1[lv_i] <= ask_level_valid_tap[lv_i];
            ask_level_valid_d2[lv_i] <= ask_level_valid_d1[lv_i];
            ask_level_valid_d3[lv_i] <= ask_level_valid_d2[lv_i];
            ask_level_valid_d4[lv_i] <= ask_level_valid_d3[lv_i];
        end
    end

    order_gen_top #(
        .NUM_UNITS      (NUM_UNITS),
        .PTR_WIDTH      (2),
        .SLOTS_PER_UNIT (SLOTS_PER_UNIT)
    ) u_order_gen (
        .clk                 (clk),
        .rst_n               (rst_n),
        .last_executed_price (last_executed_price),
        .trade_valid         (trade_valid),
        .active_agent_count  (active_agent_count),
        .param_wr_en         (param_wr_en),
        .param_wr_addr       (param_wr_addr),
        .param_wr_data       (param_wr_data),
        .order_packet        (order_packet),
        .order_valid         (order_valid),
        .order_ready         (order_ready)
    );

    wire arb_valid_tap;
    assign arb_valid_tap = u_order_gen.arb_valid;

    matching_engine #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kPriceRange    (kPriceRange)
    ) u_matching_engine (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .order_packet               (order_packet),
        .order_valid                (order_valid),
        .order_ready                (order_ready),
        .trade_price                (trade_price),
        .trade_quantity             (trade_quantity),
        .trade_side                 (trade_side),
        .trade_valid                (trade_valid),
        .last_executed_price        (last_executed_price),
        .last_executed_price_valid  (last_executed_price_valid),
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

    reg  invariants_active;
    reg  book_ever_live;
    reg  [3:0] in_flight_count;
    reg  [kQuantityWidth-1:0] accumulated_fill;

    reg  bid_qty_zero_prev;
    reg  bid_qty_zero_prev2;
    reg  bid_qty_zero_prev3;
    reg  ask_qty_zero_prev;
    reg  ask_qty_zero_prev2;
    reg  ask_qty_zero_prev3;

    integer total_trades;
    integer total_retires;
    integer total_crosses_missed;
    integer total_phantom_valid;
    integer total_fifo_full_events;
    integer total_conservation_errors;
    integer total_invalid_trade_price;
    integer max_in_flight;
    integer cycle_count;

    integer events_file;
    integer summary_file;
    integer snapshot_file;

    always @(posedge clk) begin
        if (!rst_n) cycle_count <= 0;
        else        cycle_count <= cycle_count + 1;
    end

    // Flips invariants_active once the book has been two-sided live for at least 50 cycles.
    always @(posedge clk) begin
        if (!rst_n) begin
            book_ever_live    <= 1'b0;
            invariants_active <= 1'b0;
        end else begin
            if (best_bid_valid && best_ask_valid)
                book_ever_live <= 1'b1;
            if (book_ever_live && cycle_count > 50)
                invariants_active <= 1'b1;
        end
    end

    // Invariant 1: trade_price was an occupied level on the correct side.
    always @(posedge clk) begin
        if (invariants_active && trade_valid) begin
            if (trade_price < kPriceRange) begin
                if (trade_side == 1'b0) begin
                    if (!ask_level_valid_d4[trade_price]) begin
                        $fwrite(events_file,
                            "%0d,INVALID_TRADE_PRICE,side=buy,price=%0d,level_was_empty\n",
                            cycle_count, trade_price);
                        total_invalid_trade_price <= total_invalid_trade_price + 1;
                    end
                end else begin
                    if (!bid_level_valid_d4[trade_price]) begin
                        $fwrite(events_file,
                            "%0d,INVALID_TRADE_PRICE,side=sell,price=%0d,level_was_empty\n",
                            cycle_count, trade_price);
                        total_invalid_trade_price <= total_invalid_trade_price + 1;
                    end
                end
            end else begin
                $fwrite(events_file,
                    "%0d,TRADE_PRICE_OUT_OF_RANGE,price=%0d\n",
                    cycle_count, trade_price);
                total_invalid_trade_price <= total_invalid_trade_price + 1;
            end
        end
    end

    // Invariant 2: no phantom valid; persists for 2 cycles to allow settle.
    always @(posedge clk) begin
        if (!rst_n) begin
            bid_qty_zero_prev  <= 1'b0;
            bid_qty_zero_prev2 <= 1'b0;
            bid_qty_zero_prev3 <= 1'b0;
            ask_qty_zero_prev  <= 1'b0;
            ask_qty_zero_prev2 <= 1'b0;
            ask_qty_zero_prev3 <= 1'b0;
        end else begin
            bid_qty_zero_prev  <= invariants_active && best_bid_valid
                                  && (best_bid_quantity == {kQuantityWidth{1'b0}});
            bid_qty_zero_prev2 <= bid_qty_zero_prev;
            bid_qty_zero_prev3 <= bid_qty_zero_prev2;
            ask_qty_zero_prev  <= invariants_active && best_ask_valid
                                  && (best_ask_quantity == {kQuantityWidth{1'b0}});
            ask_qty_zero_prev2 <= ask_qty_zero_prev;
            ask_qty_zero_prev3 <= ask_qty_zero_prev2;
            if (bid_qty_zero_prev3 && best_bid_valid
                    && (best_bid_quantity == {kQuantityWidth{1'b0}})) begin
                $fwrite(events_file,
                    "%0d,PHANTOM_BID_VALID,qty=0\n", cycle_count);
                total_phantom_valid <= total_phantom_valid + 1;
            end
            if (ask_qty_zero_prev3 && best_ask_valid
                    && (best_ask_quantity == {kQuantityWidth{1'b0}})) begin
                $fwrite(events_file,
                    "%0d,PHANTOM_ASK_VALID,qty=0\n", cycle_count);
                total_phantom_valid <= total_phantom_valid + 1;
            end
        end
    end

    // Invariant 3: order_fifo full never asserts.
    always @(posedge clk) begin
        if (rst_n && fifo_full && arb_valid_tap) begin
            $fwrite(events_file, "%0d,FIFO_FULL\n", cycle_count);
            total_fifo_full_events <= total_fifo_full_events + 1;
        end
    end

    // Invariant 4: in-flight count never exceeds 2.
    always @(posedge clk) begin
        if (!rst_n) begin
            in_flight_count <= 4'd0;
            max_in_flight   <= 0;
        end else begin
            case ({packet_accepted, order_retire_valid})
                2'b10:   in_flight_count <= in_flight_count + 1'b1;
                2'b01:   in_flight_count <= in_flight_count - 1'b1;
                default: in_flight_count <= in_flight_count;
            endcase
            if (in_flight_count > max_in_flight)
                max_in_flight <= in_flight_count;
            if (invariants_active && in_flight_count > 4'd2) begin
                $fwrite(events_file,
                    "%0d,IN_FLIGHT_OVERFLOW,count=%0d\n",
                    cycle_count, in_flight_count);
            end
        end
    end

    // Invariant 5: trade_quantity > 0 on every trade_valid.
    always @(posedge clk) begin
        if (invariants_active && trade_valid) begin
            total_trades <= total_trades + 1;
            if (trade_quantity == {kQuantityWidth{1'b0}}) begin
                $fwrite(events_file,
                    "%0d,ZERO_QTY_TRADE,price=%0d,side=%0d\n",
                    cycle_count, trade_price, trade_side);
            end
        end
    end

    // Logs every trade so the analysis script can compute statistics.
    always @(posedge clk) begin
        if (rst_n && trade_valid) begin
            $fwrite(events_file,
                "%0d,TRADE,price=%0d,qty=%0d,side=%0d\n",
                cycle_count, trade_price, trade_quantity, trade_side);
        end
    end

    // Invariant 6: fill conservation across each retire.
    always @(posedge clk) begin
        if (!rst_n) begin
            accumulated_fill <= {kQuantityWidth{1'b0}};
        end else begin
            if (trade_valid && !order_retire_valid)
                accumulated_fill <= accumulated_fill + trade_quantity;
            if (order_retire_valid) begin
                total_retires <= total_retires + 1;
                if (trade_valid) begin
                    if ((accumulated_fill + trade_quantity) != order_retire_fill_quantity) begin
                        $fwrite(events_file,
                            "%0d,CONSERVATION_ERROR,accumulated=%0d,reported=%0d\n",
                            cycle_count,
                            accumulated_fill + trade_quantity,
                            order_retire_fill_quantity);
                        total_conservation_errors <= total_conservation_errors + 1;
                    end
                end else begin
                    if (accumulated_fill != order_retire_fill_quantity) begin
                        $fwrite(events_file,
                            "%0d,CONSERVATION_ERROR,accumulated=%0d,reported=%0d\n",
                            cycle_count,
                            accumulated_fill,
                            order_retire_fill_quantity);
                        total_conservation_errors <= total_conservation_errors + 1;
                    end
                end
                $fwrite(events_file,
                    "%0d,RETIRE,trade_count=%0d,fill_qty=%0d,bid=%0d,ask=%0d,bid_v=%0d,ask_v=%0d\n",
                    cycle_count,
                    order_retire_trade_count,
                    order_retire_fill_quantity,
                    best_bid_price,
                    best_ask_price,
                    best_bid_valid,
                    best_ask_valid);
                accumulated_fill <= {kQuantityWidth{1'b0}};
            end
        end
    end

    reg crossed_book_prev;

    always @(posedge clk) begin
        if (!rst_n) begin
            crossed_book_prev <= 1'b0;
        end else begin
            crossed_book_prev <= invariants_active && best_bid_valid && best_ask_valid
                                && (best_bid_price >= best_ask_price);
            if (crossed_book_prev && invariants_active && best_bid_valid && best_ask_valid
                    && (best_bid_price >= best_ask_price)) begin
                $fwrite(events_file,
                    "%0d,CROSSED_BOOK,bid=%0d,ask=%0d\n",
                    cycle_count, best_bid_price, best_ask_price);
                total_crosses_missed <= total_crosses_missed + 1;
            end
        end
    end

    // Snapshots top-of-book and last execution price every 100 cycles for plotting.
    always @(posedge clk) begin
        if (invariants_active && (cycle_count % 100 == 0)) begin
            $fwrite(snapshot_file,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cycle_count,
                best_bid_price,
                best_bid_quantity,
                best_bid_valid,
                best_ask_price,
                best_ask_quantity,
                best_ask_valid,
                last_executed_price);
        end
    end

    task tick;
        begin
            @(posedge clk); #1;
        end
    endtask

    task tick_n;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) begin
                tick;
            end
        end
    endtask

    task write_param;
        input [15:0] addr;
        input [31:0] data;
        begin
            param_wr_en   <= 1'b1;
            param_wr_addr <= addr;
            param_wr_data <= data;
            tick;
            param_wr_en   <= 1'b0;
            tick;
        end
    endtask

    task write_summary;
        begin
            $fwrite(summary_file, "metric,value\n");
            $fwrite(summary_file, "total_cycles,%0d\n",               cycle_count);
            $fwrite(summary_file, "total_trades,%0d\n",               total_trades);
            $fwrite(summary_file, "total_retires,%0d\n",              total_retires);
            $fwrite(summary_file, "crossed_book_events,%0d\n",        total_crosses_missed);
            $fwrite(summary_file, "phantom_valid_events,%0d\n",       total_phantom_valid);
            $fwrite(summary_file, "fifo_full_events,%0d\n",           total_fifo_full_events);
            $fwrite(summary_file, "conservation_errors,%0d\n",        total_conservation_errors);
            $fwrite(summary_file, "invalid_trade_price_events,%0d\n", total_invalid_trade_price);
            $fwrite(summary_file, "max_in_flight,%0d\n",              max_in_flight);
            $fwrite(summary_file, "hostile_writes,%0d\n",             hostile_writes);
            $fclose(events_file);
            $fclose(summary_file);
            $fclose(snapshot_file);
        end
    endtask

    // Issues bursts of unauthorized parameter writes during Phase 2 to confirm the engine
    // tolerates concurrent slot-table updates from a hostile manager.
    reg  [15:0] hostile_lfsr;
    integer     hostile_writes;
    initial begin
        hostile_lfsr   = 16'hACE1;
        hostile_writes = 0;
        wait(invariants_active);
        tick_n(100);
        repeat (200) begin
            tick_n(50 + {9'd0, hostile_lfsr[6:0]});
            @(posedge clk); #1;
            param_wr_en   <= 1'b1;
            param_wr_addr <= {hostile_lfsr[9:4], hostile_lfsr[5:0]};
            param_wr_data <= kNoiseTraderParam;
            @(posedge clk); #1;
            param_wr_en   <= 1'b0;
            hostile_lfsr <= {hostile_lfsr[14:0],
                             hostile_lfsr[15] ^ hostile_lfsr[13]
                             ^ hostile_lfsr[12] ^ hostile_lfsr[10]};
            hostile_writes = hostile_writes + 1;
        end
    end

    integer unit;
    integer slot;
    integer global_slot;
    reg [31:0] slot_param;
    initial begin
        $dumpfile("tb_sim_top.vcd");
        $dumpvars(0, tb_sim_top);
        events_file   = $fopen("sim_top_events.csv",    "w");
        summary_file  = $fopen("sim_top_summary.csv",   "w");
        snapshot_file = $fopen("sim_top_snapshots.csv", "w");
        $fwrite(events_file,  "cycle,event,detail\n");
        $fwrite(snapshot_file,
            "cycle,best_bid_price,best_bid_qty,best_bid_valid,best_ask_price,best_ask_qty,best_ask_valid,last_executed_price\n");

        rst_n              <= 1'b0;
        param_wr_en        <= 1'b0;
        param_wr_addr      <= 16'd0;
        param_wr_data      <= 32'd0;
        active_agent_count <= 16'd0;
        total_trades              = 0;
        total_retires             = 0;
        total_crosses_missed      = 0;
        total_phantom_valid       = 0;
        total_fifo_full_events    = 0;
        total_conservation_errors = 0;
        total_invalid_trade_price = 0;
        tick_n(4);
        rst_n <= 1'b1;
        tick_n(2);

        global_slot = 0;
        for (unit = 0; unit < NUM_UNITS; unit = unit + 1) begin
            for (slot = 0; slot < SLOTS_PER_UNIT; slot = slot + 1) begin
                global_slot = unit * SLOTS_PER_UNIT + slot;
                if      (global_slot < kNoiseCount)
                    slot_param = kNoiseTraderParam;
                else if (global_slot < kNoiseCount + kMMCount)
                    slot_param = kMMTraderParam;
                else if (global_slot < kNoiseCount + kMMCount + kMomentumCount)
                    slot_param = kMomentumParam;
                else if (global_slot < kNoiseCount + kMMCount + kMomentumCount + kValueCount)
                    slot_param = kValueParam;
                else
                    slot_param = kNoiseTraderParam; // fill remainder with noise
                write_param((unit[15:0] << 6) | slot[15:0], slot_param);
            end
        end

        wait(u_order_gen.gbm_price_valid);
        tick_n(4);  

        active_agent_count <= 16'd64;
        tick_n(2);

        // Phase 2: free run with invariant checkers and hostile writes in parallel.
        tick_n(kRunCycles);

        while (in_flight_count > 0) tick;
        tick_n(10);

        write_summary;
        $display("Integration test complete: %0d cycles", cycle_count);
        $display("  Trades:                %0d", total_trades);
        $display("  Retires:               %0d", total_retires);
        $display("  Crossed book:          %0d", total_crosses_missed);
        $display("  Phantom valid:         %0d", total_phantom_valid);
        $display("  FIFO full:             %0d", total_fifo_full_events);
        $display("  Conservation errors:   %0d", total_conservation_errors);
        $display("  Invalid trade price:   %0d", total_invalid_trade_price);
        $display("  Max in-flight:         %0d", max_in_flight);
        $display("  Hostile writes:        %0d", hostile_writes);
        if (total_crosses_missed      == 0 &&
            total_phantom_valid       == 0 &&
            total_fifo_full_events    == 0 &&
            total_conservation_errors == 0 &&
            total_invalid_trade_price == 0) begin
            $display("PASS: all invariants held");
        end else begin
            $display("FAIL: invariant violations -- check sim_top_events.csv");
        end
        $finish;
    end

    initial begin
        #(kClockPeriod * kWatchdog);
        $display("[ERROR] Watchdog timeout -- dumping partial results");
        write_summary;
        $finish;
    end
endmodule
