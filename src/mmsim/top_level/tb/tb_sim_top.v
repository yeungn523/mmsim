`timescale 1ns/1ns

// Wires order_gen_top to matching_engine and seeds agent params from $value$plusargs so an
// outer sweep harness drives parameter sweeps without recompiling the TB.
//
// Plusargs (10-bit fields pack into a 32-bit param word with type in bits[31:30]):
//   +P1_NOISE +P2_NOISE +P3_NOISE        defaults 700, 32, 8
//   +P1_MM    +P2_MM    +P3_MM           defaults 800, 4, 5
//   +P1_MOM   +P2_MOM   +P3_MOM          defaults 15, 4, 4
//   +P1_VAL   +P2_VAL   +P3_VAL          defaults 8, 16, 10
//   +RUN_CYCLES=N                         default 5000
//   +OUT_TAG=string                       default "default"
//   +SUMMARY_PATH=path                    default "sweep_results.csv", appended
//   +VCD=1                                default off; enables $dumpvars when set
//
// Drift metric: exec_tick - gbm_tick, both = price[31:23] saturated at 479.

module tb_sim_top;
    localparam kClockPeriod  = 20;
    localparam kWatchdogMul  = 50;

    localparam NUM_UNITS        = 4;
    localparam SLOTS_PER_UNIT   = 64;
    localparam kPriceWidth      = 32;
    localparam kQuantityWidth   = 16;
    localparam kPriceRange      = 480;
    localparam TICK_SHIFT       = 23;

    // Holds plusarg-loaded parameter values; populated in the main initial block.
    reg [9:0] p1_noise, p2_noise, p3_noise;
    reg [9:0] p1_mm,    p2_mm,    p3_mm;
    reg [9:0] p1_mom,   p2_mom,   p3_mom;
    reg [9:0] p1_val,   p2_val,   p3_val;

    reg [31:0] noise_param, mm_param, mom_param, val_param;

    integer     run_cycles;
    integer     watchdog_cycles;
    reg [255:0]  out_tag;
    reg [1023:0] summary_path;
    integer     vcd_enable;

    reg clk;
    reg rst_n;
    initial clk = 0;
    always #(kClockPeriod / 2) clk = ~clk;

    reg         gbm_enable;
    reg  [15:0] active_agent_count;

    wire [NUM_UNITS*10-1:0]  agent_param_rd_addr;
    wire [NUM_UNITS*32-1:0]  agent_param_rd_data;

    // Mirrors HPS-side param memory; indexed as unit*SLOTS_PER_UNIT + slot.
    reg [31:0] param_mem [0:NUM_UNITS*SLOTS_PER_UNIT-1];

    // Mimics M10K with a 1-cycle synchronous read.
    reg [31:0] param_rd_data_reg [0:NUM_UNITS-1];
    genvar gu;
    generate
        for (gu = 0; gu < NUM_UNITS; gu = gu + 1) begin : gen_param_mem_read
            wire [9:0] addr_in = agent_param_rd_addr[gu*10 +: 10];
            always @(posedge clk) begin
                if (addr_in < SLOTS_PER_UNIT)
                    param_rd_data_reg[gu] <= param_mem[gu*SLOTS_PER_UNIT + addr_in];
                else
                    param_rd_data_reg[gu] <= 32'd0;
            end
            assign agent_param_rd_data[gu*32 +: 32] = param_rd_data_reg[gu];
        end
    endgenerate

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
    wire [1:0]                order_retire_agent_type;

    // Stubs the inject bus; sweep does not exercise injection.
    wire        inject_active_unused;

    // Taps internal nets for invariants and the drift metric.
    wire fifo_full = tb_sim_top.u_order_gen.u_fifo.full;
    wire arb_valid_tap = tb_sim_top.u_order_gen.arb_valid;
    wire packet_accepted = order_valid && order_ready;
    wire [31:0] gbm_price_q824 = tb_sim_top.u_order_gen.u_gbm.price_out;
    wire [8:0]  gbm_tick_raw   = (gbm_price_q824[31:TICK_SHIFT] > 9'd479)
                                 ? 9'd479 : gbm_price_q824[31:TICK_SHIFT];
    wire [8:0]  exec_tick_raw  = (last_executed_price[31:TICK_SHIFT] > 9'd479)
                                 ? 9'd479 : last_executed_price[31:TICK_SHIFT];

    order_gen_top #(
        .NUM_UNITS      (NUM_UNITS),
        .PTR_WIDTH      (2),
        .SLOTS_PER_UNIT (SLOTS_PER_UNIT)
    ) u_order_gen (
        .clk                 (clk),
        .rst_n               (rst_n),
        .gbm_enable          (gbm_enable),
        .last_executed_price (last_executed_price),
        .trade_valid         (trade_valid),
        .active_agent_count  (active_agent_count),
        .order_packet        (order_packet),
        .order_valid         (order_valid),
        .order_ready         (order_ready),
        .inject_packet       (32'd0),
        .inject_trigger      (1'b0),
        .inject_count        (32'd0),
        .inject_active       (inject_active_unused),
        .param_rd_addr       (agent_param_rd_addr),
        .param_rd_data       (agent_param_rd_data)
    );

    // Stubs the depth read port; not consumed here.
    wire [kQuantityWidth-1:0] bid_depth_rd_data_unused;
    wire [kQuantityWidth-1:0] ask_depth_rd_data_unused;

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
        .order_retire_fill_quantity (order_retire_fill_quantity),
        .order_retire_agent_type    (order_retire_agent_type),
        .depth_rd_addr              (9'd0),
        .bid_depth_rd_data          (bid_depth_rd_data_unused),
        .ask_depth_rd_data          (ask_depth_rd_data_unused)
    );

    // ---------------- Counters / accumulators ----------------
    integer cycle_count;
    integer trades_active;
    // Gates metrics until the book is two-sided and gbm_enable has been live >= 50 cycles.
    reg     measurement_active;
    reg     book_live;

    // 32-bit accumulators are safe for runs up to ~10M cycles given the 480-tick range.
    integer drift_sum_sq;
    integer drift_sum_abs;
    integer drift_samples;
    integer terminal_drift;
    integer min_exec_tick;
    integer max_exec_tick;
    integer max_drawdown;

    // Sampled only when both sides of the book are valid.
    integer spread_sum;
    integer spread_samples;
    integer bid_qty_sum;
    integer ask_qty_sum;
    integer qty_samples;

    integer qty_noise_total;
    integer qty_mm_total;
    integer qty_mom_total;
    integer qty_val_total;

    integer total_crosses_missed;
    integer total_phantom_valid;
    integer total_fifo_full_events;
    integer total_conservation_errors;
    integer total_invalid_trade_price;
    integer max_in_flight;
    reg [3:0] in_flight_count;
    reg [kQuantityWidth-1:0] accumulated_fill;

    // Pipelines zero-qty 3 cycles deep so the phantom-valid invariant lets the book settle.
    reg bid_qty_zero_p1, bid_qty_zero_p2, bid_qty_zero_p3;
    reg ask_qty_zero_p1, ask_qty_zero_p2, ask_qty_zero_p3;
    reg crossed_book_prev;

    integer summary_file;
    integer running_max_exec;

    // ---------------- Cycle counter ----------------
    always @(posedge clk) begin
        if (!rst_n) cycle_count <= 0;
        else        cycle_count <= cycle_count + 1;
    end

    // ---------------- Drift / liquidity sampling ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            book_live          <= 1'b0;
            measurement_active <= 1'b0;
        end else begin
            if (gbm_enable && best_bid_valid && best_ask_valid)
                book_live <= 1'b1;
            if (book_live && cycle_count > 50)
                measurement_active <= 1'b1;
        end
    end

    integer drift_signed;
    integer exec_tick_int;
    integer gbm_tick_int;

    always @(posedge clk) begin
        if (!rst_n) begin
            drift_sum_sq    <= 0;
            drift_sum_abs   <= 0;
            drift_samples   <= 0;
            terminal_drift  <= 0;
            min_exec_tick   <= 480;
            max_exec_tick   <= -1;
            max_drawdown    <= 0;
            running_max_exec<= 0;
            spread_sum      <= 0;
            spread_samples  <= 0;
            bid_qty_sum     <= 0;
            ask_qty_sum     <= 0;
            qty_samples     <= 0;
            trades_active   <= 0;
        end else if (measurement_active) begin
            exec_tick_int = exec_tick_raw;
            gbm_tick_int  = gbm_tick_raw;
            drift_signed  = exec_tick_int - gbm_tick_int;

            drift_sum_sq  <= drift_sum_sq + drift_signed * drift_signed;
            drift_sum_abs <= drift_sum_abs + ((drift_signed < 0) ? -drift_signed : drift_signed);
            drift_samples <= drift_samples + 1;
            terminal_drift <= drift_signed;

            if (exec_tick_int < min_exec_tick) min_exec_tick <= exec_tick_int;
            if (exec_tick_int > max_exec_tick) max_exec_tick <= exec_tick_int;
            if (exec_tick_int > running_max_exec) running_max_exec <= exec_tick_int;
            if ((running_max_exec - exec_tick_int) > max_drawdown)
                max_drawdown <= running_max_exec - exec_tick_int;

            if (best_bid_valid && best_ask_valid) begin
                spread_sum     <= spread_sum + (best_ask_price[8:0] - best_bid_price[8:0]);
                spread_samples <= spread_samples + 1;
                bid_qty_sum    <= bid_qty_sum + best_bid_quantity;
                ask_qty_sum    <= ask_qty_sum + best_ask_quantity;
                qty_samples    <= qty_samples + 1;
            end

            if (trade_valid) trades_active <= trades_active + 1;
        end
    end

    // ---------------- Per-type retire qty ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            qty_noise_total <= 0;
            qty_mm_total    <= 0;
            qty_mom_total   <= 0;
            qty_val_total   <= 0;
        end else if (order_retire_valid) begin
            case (order_retire_agent_type)
                2'b00: qty_noise_total <= qty_noise_total + order_retire_fill_quantity;
                2'b01: qty_mm_total    <= qty_mm_total    + order_retire_fill_quantity;
                2'b10: qty_mom_total   <= qty_mom_total   + order_retire_fill_quantity;
                2'b11: qty_val_total   <= qty_val_total   + order_retire_fill_quantity;
            endcase
        end
    end

    // ---------------- Invariants (count-only) ----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            in_flight_count <= 4'd0;
            max_in_flight   <= 0;
            accumulated_fill <= {kQuantityWidth{1'b0}};
            total_conservation_errors <= 0;
        end else begin
            case ({packet_accepted, order_retire_valid})
                2'b10:   in_flight_count <= in_flight_count + 1'b1;
                2'b01:   in_flight_count <= in_flight_count - 1'b1;
                default: in_flight_count <= in_flight_count;
            endcase
            if (in_flight_count > max_in_flight) max_in_flight <= in_flight_count;

            if (trade_valid && !order_retire_valid)
                accumulated_fill <= accumulated_fill + trade_quantity;
            if (order_retire_valid) begin
                if (trade_valid) begin
                    if ((accumulated_fill + trade_quantity) != order_retire_fill_quantity)
                        total_conservation_errors <= total_conservation_errors + 1;
                end else begin
                    if (accumulated_fill != order_retire_fill_quantity)
                        total_conservation_errors <= total_conservation_errors + 1;
                end
                accumulated_fill <= {kQuantityWidth{1'b0}};
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            total_crosses_missed      <= 0;
            total_phantom_valid       <= 0;
            total_fifo_full_events    <= 0;
            total_invalid_trade_price <= 0;
            crossed_book_prev         <= 1'b0;
            bid_qty_zero_p1 <= 1'b0; bid_qty_zero_p2 <= 1'b0; bid_qty_zero_p3 <= 1'b0;
            ask_qty_zero_p1 <= 1'b0; ask_qty_zero_p2 <= 1'b0; ask_qty_zero_p3 <= 1'b0;
        end else begin
            if (fifo_full && arb_valid_tap)
                total_fifo_full_events <= total_fifo_full_events + 1;

            if (measurement_active && trade_valid && (trade_price[8:0] >= 9'd480))
                total_invalid_trade_price <= total_invalid_trade_price + 1;

            crossed_book_prev <= measurement_active && best_bid_valid && best_ask_valid
                                 && (best_bid_price >= best_ask_price);
            if (crossed_book_prev && measurement_active && best_bid_valid && best_ask_valid
                    && (best_bid_price >= best_ask_price))
                total_crosses_missed <= total_crosses_missed + 1;

            bid_qty_zero_p1 <= measurement_active && best_bid_valid
                               && (best_bid_quantity == {kQuantityWidth{1'b0}});
            bid_qty_zero_p2 <= bid_qty_zero_p1;
            bid_qty_zero_p3 <= bid_qty_zero_p2;
            ask_qty_zero_p1 <= measurement_active && best_ask_valid
                               && (best_ask_quantity == {kQuantityWidth{1'b0}});
            ask_qty_zero_p2 <= ask_qty_zero_p1;
            ask_qty_zero_p3 <= ask_qty_zero_p2;
            if (bid_qty_zero_p3 && best_bid_valid
                    && (best_bid_quantity == {kQuantityWidth{1'b0}}))
                total_phantom_valid <= total_phantom_valid + 1;
            if (ask_qty_zero_p3 && best_ask_valid
                    && (best_ask_quantity == {kQuantityWidth{1'b0}}))
                total_phantom_valid <= total_phantom_valid + 1;
        end
    end

    // ---------------- Helpers ----------------
    task tick;
        begin @(posedge clk); #1; end
    endtask

    task tick_n;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) tick;
        end
    endtask

    function [31:0] pack_param;
        input [1:0] kind;
        input [9:0] p1;
        input [9:0] p2;
        input [9:0] p3;
        begin
            pack_param = {kind, p1, p2, p3};
        end
    endfunction

    task write_summary;
        integer mean_abs_x1000;
        integer trade_rate_x1000;
        integer mean_spread_x1000;
        integer mean_bid_x1000;
        integer mean_ask_x1000;
        integer drift_avg_sq;
        begin
            // Reports MSE here; the Python analyzer takes sqrt for RMS.
            drift_avg_sq = (drift_samples > 0) ? (drift_sum_sq / drift_samples) : 0;
            mean_abs_x1000 = (drift_samples > 0)
                              ? (drift_sum_abs * 1000) / drift_samples : 0;
            trade_rate_x1000 = (run_cycles > 0)
                              ? (trades_active * 1000) / run_cycles : 0;
            mean_spread_x1000 = (spread_samples > 0)
                              ? (spread_sum * 1000) / spread_samples : 0;
            mean_bid_x1000 = (qty_samples > 0)
                              ? (bid_qty_sum * 1000) / qty_samples : 0;
            mean_ask_x1000 = (qty_samples > 0)
                              ? (ask_qty_sum * 1000) / qty_samples : 0;

            $fwrite(summary_file,
                "%0s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                out_tag,
                p1_noise, p2_noise, p3_noise,
                p1_mm,    p2_mm,    p3_mm,
                p1_mom,   p2_mom,   p3_mom,
                p1_val,   p2_val,   p3_val,
                cycle_count, trades_active, trade_rate_x1000,
                drift_avg_sq, terminal_drift, mean_abs_x1000,
                max_drawdown, min_exec_tick, max_exec_tick,
                mean_spread_x1000, mean_bid_x1000, mean_ask_x1000,
                qty_noise_total, qty_mm_total, qty_mom_total, qty_val_total,
                total_crosses_missed, total_phantom_valid, total_fifo_full_events,
                total_conservation_errors, total_invalid_trade_price);
            $fclose(summary_file);
        end
    endtask

    // ---------------- Main ----------------
    integer slot;

    initial begin
        if (!$value$plusargs("P1_NOISE=%d", p1_noise)) p1_noise = 10'd700;
        if (!$value$plusargs("P2_NOISE=%d", p2_noise)) p2_noise = 10'd32;
        if (!$value$plusargs("P3_NOISE=%d", p3_noise)) p3_noise = 10'd8;
        if (!$value$plusargs("P1_MM=%d",    p1_mm))    p1_mm    = 10'd800;
        if (!$value$plusargs("P2_MM=%d",    p2_mm))    p2_mm    = 10'd4;
        if (!$value$plusargs("P3_MM=%d",    p3_mm))    p3_mm    = 10'd5;
        if (!$value$plusargs("P1_MOM=%d",   p1_mom))   p1_mom   = 10'd15;
        if (!$value$plusargs("P2_MOM=%d",   p2_mom))   p2_mom   = 10'd4;
        if (!$value$plusargs("P3_MOM=%d",   p3_mom))   p3_mom   = 10'd4;
        if (!$value$plusargs("P1_VAL=%d",   p1_val))   p1_val   = 10'd8;
        if (!$value$plusargs("P2_VAL=%d",   p2_val))   p2_val   = 10'd16;
        if (!$value$plusargs("P3_VAL=%d",   p3_val))   p3_val   = 10'd10;
        if (!$value$plusargs("RUN_CYCLES=%d", run_cycles)) run_cycles = 5000;
        if (!$value$plusargs("VCD=%d", vcd_enable)) vcd_enable = 0;
        if (!$value$plusargs("OUT_TAG=%s", out_tag))      out_tag = "default";
        if (!$value$plusargs("SUMMARY_PATH=%s", summary_path))
            summary_path = "sweep_results.csv";

        watchdog_cycles = run_cycles * kWatchdogMul;

        noise_param = pack_param(2'b00, p1_noise, p2_noise, p3_noise);
        mm_param    = pack_param(2'b01, p1_mm,    p2_mm,    p3_mm);
        mom_param   = pack_param(2'b10, p1_mom,   p2_mom,   p3_mom);
        val_param   = pack_param(2'b11, p1_val,   p2_val,   p3_val);

        if (vcd_enable) begin
            $dumpfile("tb_sim_top.vcd");
            $dumpvars(0, tb_sim_top);
        end

        // Append-only; the sweep driver writes the CSV header.
        summary_file = $fopen(summary_path, "a");
        if (summary_file == 0) begin
            $display("[ERROR] could not open summary path: %0s", summary_path);
            $finish;
        end

        rst_n              <= 1'b0;
        gbm_enable         <= 1'b0;
        active_agent_count <= 16'd0;

        // Unit 0 = noise, 1 = MM, 2 = momentum, 3 = value.
        for (slot = 0; slot < SLOTS_PER_UNIT; slot = slot + 1) begin
            param_mem[0*SLOTS_PER_UNIT + slot] = noise_param;
            param_mem[1*SLOTS_PER_UNIT + slot] = mm_param;
            param_mem[2*SLOTS_PER_UNIT + slot] = mom_param;
            param_mem[3*SLOTS_PER_UNIT + slot] = val_param;
        end

        tick_n(8);
        rst_n <= 1'b1;
        tick_n(8);

        // Phase 1: seeds the book at GBM_P0_HELD with gbm_enable low.
        active_agent_count <= 16'd64;
        tick_n(200);

        // Phase 2: releases GBM for the measurement window.
        gbm_enable <= 1'b1;
        tick_n(run_cycles);

        // Drains in-flight orders before final sampling.
        while (in_flight_count > 0) tick;
        tick_n(20);

        write_summary;

        $display("=== sweep run [%0s] complete ===", out_tag);
        $display("  cycles=%0d trades=%0d trade_rate(/k)=%0d",
                 cycle_count, trades_active,
                 (run_cycles > 0) ? (trades_active * 1000) / run_cycles : 0);
        $display("  drift_mse=%0d term_drift=%0d max_dd=%0d min_exec=%0d max_exec=%0d",
                 (drift_samples > 0) ? (drift_sum_sq / drift_samples) : 0,
                 terminal_drift, max_drawdown, min_exec_tick, max_exec_tick);
        $display("  qty noise=%0d mm=%0d mom=%0d val=%0d",
                 qty_noise_total, qty_mm_total, qty_mom_total, qty_val_total);
        $display("  invariants cross=%0d phantom=%0d fifo=%0d cons=%0d invprice=%0d",
                 total_crosses_missed, total_phantom_valid, total_fifo_full_events,
                 total_conservation_errors, total_invalid_trade_price);
        $finish;
    end

    // Bounds total sim time at RUN_CYCLES * kWatchdogMul.
    initial begin
        wait (run_cycles > 0);
        while (cycle_count < watchdog_cycles) #(kClockPeriod * 100);
        $display("[ERROR] Watchdog timeout (%0d cycles)", watchdog_cycles);
        write_summary;
        $finish;
    end
endmodule
