// agent_execution_unit_tb.v
// ModelSim testbench for agent_execution_unit
//
// METHODOLOGY:
//   - Drives hardcoded deterministic inputs so Python golden model can
//     predict exact outputs without needing to simulate the TB itself
//   - Internal LFSR inside DUT is real and free-running from a known seed
//     (LFSR_SEED = 32'hCAFEBABE, POLY = 32'hB4BCD35C) -- Python replicates
//     this exact Galois LFSR to predict emission decisions and packet values
//   - Every order_valid pulse dumps one CSV row via $fwrite
//   - CSV includes input state snapshot at moment of emission so Python
//     can verify math without ambiguity
//
// CSV FORMAT (one row per order_valid pulse):
//   cycle,phase,side,order_type,agent_type,price,volume,gbm_price_in,param_data_in
//
// PHASES:
//   Phase 1-3: Noise trader (Always emit, Never emit, 50% emit)
//   Phase 4-6: Value investor (Buy, Sell, Silent)
//   Phase 7: Momentum trader, Uptrend (Buy)
//            Expected: order_valid every 4 cycles, market buy
//   Phase 8: Momentum trader, Downtrend (Sell)
//            Expected: order_valid every 4 cycles, market sell
//   Phase 9: Momentum trader, Sideways (Silent)
//            Expected: order_valid never asserted
//
// HOW TO RUN:
//   do run_sim.tcl
//   Output: sim_output.csv in working directory

`timescale 1ns/1ns

module agent_execution_unit_tb;

    // ----------------------------------------------------------------
    // Parameters matching DUT instantiation
    // ----------------------------------------------------------------
    localparam [31:0] LFSR_POLY         = 32'hB4BCD35C;
    localparam [31:0] LFSR_SEED         = 32'hCAFEBABE;
    localparam [8:0]  NEAR_NOISE_THRESH = 9'd16;

    localparam CLK_PERIOD = 20; // 50MHz

    // MUST remain multiples of 4 (one FSM slot = 4 cycles)
    // Non-multiples cause param swap mid-slot and corrupt results
    localparam PHASE1_CYCLES = 400;
    localparam PHASE2_CYCLES = 200;
    localparam PHASE3_CYCLES = 4000;
    localparam PHASE4_CYCLES = 200;
    localparam PHASE5_CYCLES = 200;
    localparam PHASE6_CYCLES = 200;
    localparam PHASE7_CYCLES = 200;
    localparam PHASE8_CYCLES = 200;
    localparam PHASE9_CYCLES = 200;

    // ----------------------------------------------------------------
    // DUT signals -- reg for driven signals, wire for outputs
    // ----------------------------------------------------------------
    reg         clk;
    reg         rst_n;
    reg  [31:0] gbm_price;
    reg  [31:0] last_exec_price;
    reg  [15:0] sigma;
    reg         trade_valid;
    wire [15:0] param_addr;
    reg  [31:0] param_data;
    reg  [15:0] active_agent_count;
    wire [31:0] order_packet;
    wire        order_valid;

    // ----------------------------------------------------------------
    // Testbench internal
    // ----------------------------------------------------------------
    integer csv_file;
    integer cycle_count;
    integer phase;
    integer emission_count;
    integer i;

    // Simulated M10K -- TB drives param_data based on param_addr
    // Registered read to match real M10K 1-cycle latency
    reg [31:0] param_table [0:63];

    always @(posedge clk) begin
        param_data <= param_table[param_addr];
    end

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    agent_execution_unit #(
        .NUM_AGENT_SLOTS  (64),
        .LFSR_POLY        (LFSR_POLY),
        .LFSR_SEED        (LFSR_SEED),
        .NEAR_NOISE_THRESH(NEAR_NOISE_THRESH)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .gbm_price         (gbm_price),
        .last_exec_price   (last_exec_price),
        .sigma             (sigma),
        .trade_valid       (trade_valid),
        .param_addr        (param_addr),
        .param_data        (param_data),
        .active_agent_count(active_agent_count),
        .order_packet      (order_packet),
        .order_valid       (order_valid)
    );

    // ----------------------------------------------------------------
    // Clock generation
    // ----------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ----------------------------------------------------------------
    // Cycle counter
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    // ----------------------------------------------------------------
    // CSV dump on every order_valid pulse
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (order_valid) begin
            $fwrite(csv_file, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cycle_count,
                phase,
                order_packet[31],
                order_packet[30],
                order_packet[29:28],
                order_packet[24:16],
                order_packet[15:0],
                gbm_price,
                param_data
            );
            emission_count = emission_count + 1;
        end
    end

    // ----------------------------------------------------------------
    // Main stimulus
    // ----------------------------------------------------------------
    initial begin
        csv_file = $fopen("sim_output.csv", "w");
        $fwrite(csv_file, "cycle,phase,side,order_type,agent_type,price,volume,gbm_price_in,param_data_in\n");

        // Initialize signals
        rst_n              = 0;
        trade_valid        = 0;
        active_agent_count = 16'd1;
        emission_count     = 0;

        // ============================================================
        // Setup phase 1 WHILE RESET IS LOW
        // ============================================================
        phase           = 1;
        gbm_price       = 32'h64000000; // Q8.24 = 100.0, tick = 200
        last_exec_price = 32'h64000000;
        sigma           = 16'h0100;

        for (i = 0; i < 64; i = i + 1)
            param_table[i] = 32'd0;

        // Slot 0: always-emit noise trader
        param_table[0] = {2'b00, 10'h3FF, 10'd50, 10'd100};

        repeat(4) @(posedge clk);
        @(negedge clk); // Release reset on negedge so FSM wakes perfectly on next posedge
        rst_n = 1;

        // ============================================================
        // PHASE 1: always emit
        // ============================================================
        $display("Phase 1 start: always-emit noise trader, gbm_tick=200, max_offset=50, max_vol=100");
        
        repeat(PHASE1_CYCLES) @(posedge clk);
        #1; // Fix race condition before changing parameters

        // HARDWARE UPDATE: Change params NOW so the FSM reads them for the next slot
        param_table[0] = {2'b00, 10'h000, 10'd50, 10'd100};
        
        // TB UPDATE: Wait 1 cycle for the CSV writer to log the final Phase 1 order
        @(posedge clk);
        $display("Phase 1 end: %0d emissions in %0d cycles", emission_count, PHASE1_CYCLES);

        // ============================================================
        // PHASE 2: never emit
        // ============================================================
        phase          = 2;
        emission_count = 0;
        $display("Phase 2 start: never-emit noise trader");
        
        // We consumed 1 cycle of Phase 2 waiting for the CSV, so we run for (CYCLES - 1)
        repeat(PHASE2_CYCLES - 1) @(posedge clk);
        #1; // Race condition protection
        
        // HARDWARE UPDATE
        param_table[0] = {2'b00, 10'd512, 10'd50, 10'd100};
        
        // TB UPDATE: Wait 1 cycle for CSV flush
        @(posedge clk);
        $display("Phase 2 end: %0d emissions (expected 0)", emission_count);
        if (emission_count != 0)
            $display("FAIL: Phase 2 expected 0 emissions, got %0d", emission_count);
        else
            $display("PASS: Phase 2 silence confirmed");

        // ============================================================
        // PHASE 3: ~50% emit
        // ============================================================
        phase          = 3;
        emission_count = 0;
        $display("Phase 3 start: 50pct emission, running %0d cycles", PHASE3_CYCLES);
        
        // Run for (CYCLES - 1)
        repeat(PHASE3_CYCLES - 1) @(posedge clk);
        #1; 
        
        // TB UPDATE: Wait 1 final cycle so the very last order makes it into the CSV
        @(posedge clk);
        $display("Phase 3 end: %0d emissions out of %0d evaluations", emission_count, PHASE3_CYCLES/4);

        if (emission_count >= 400 && emission_count <= 600)
            $display("PASS: Phase 3 emission rate within expected range");
        else
            $display("WARN: Phase 3 emission count %0d outside 400-600", emission_count);


        // ============================================================
        // SETUP FOR VALUE INVESTOR (PHASES 4-6)
        // Must pulse trade_valid so exec_price_shift_reg catches it
        // ============================================================
        last_exec_price = 32'h64000000; // Q8.24 = 100.0, tick = 200
        trade_valid     = 1;
        @(posedge clk);
        #1; 
        trade_valid     = 0;

        repeat(3) @(posedge clk);
        #1;

        // ============================================================
        // PHASE 4: Value Investor - Undervalued (Buy)
        // ============================================================
        phase          = 4;
        emission_count = 0;
        gbm_price      = 32'h78000000; // Q8.24 = 120.0, tick = 240
        
        // Type=11, Threshold=10, Aggression=256, Cap=100
        param_table[0] = {2'b11, 10'd10, 10'd256, 10'd100};
        
        $display("Phase 4 start: Value Buy (GBM=240, Exec=200, Div=+40 > Thresh 10)");
        
        repeat(PHASE4_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 4 end: %0d emissions", emission_count);


        // ============================================================
        // PHASE 5: Value Investor - Overvalued (Sell)
        // ============================================================
        phase          = 5;
        emission_count = 0;
        gbm_price      = 32'h50000000; // Q8.24 = 80.0, tick = 160
        
        $display("Phase 5 start: Value Sell (GBM=160, Exec=200, Div=-40 < Thresh -10)");
        
        repeat(PHASE5_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 5 end: %0d emissions", emission_count);


        // ============================================================
        // PHASE 6: Value Investor - Within Threshold (Silent)
        // ============================================================
        phase          = 6;
        emission_count = 0;
        gbm_price      = 32'h66000000; // Q8.24 = 102.0, tick = 204
        
        $display("Phase 6 start: Value Silent (GBM=204, Exec=200, Div=+4 <= Thresh 10)");
        
        repeat(PHASE6_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);

        $display("Phase 6 end: %0d emissions (expected 0)", emission_count);
        if (emission_count != 0)
            $display("FAIL: Phase 6 expected 0 emissions, got %0d", emission_count);
        else
            $display("PASS: Phase 6 silence confirmed");


        // ============================================================
        // SETUP FOR MOMENTUM TRADER - UPTREND (PHASE 7)
        // We need 4 consecutive trades to fill the shift register
        // sequence: 200 -> 210 -> 220 -> 240
        // Result: Oldest (reg_3) = 200. Newest (reg_0) = 240. Delta = +40
        // ============================================================
        // Type=10, Threshold=10, Aggression=256, Cap=100
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100};
        
        last_exec_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_exec_price = 32'h69000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 210
        last_exec_price = 32'h6E000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 220
        last_exec_price = 32'h78000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 240
        
        // ============================================================
        // SETUP FOR MOMENTUM TRADER - UPTREND (PHASE 7)
        // ============================================================
        param_table[0] = 32'd0; // <-- MUTE AGENT DURING SETUP
        
        last_exec_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_exec_price = 32'h69000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 210
        last_exec_price = 32'h6E000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 220
        last_exec_price = 32'h78000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 240
        
        // ============================================================
        // PHASE 7: Momentum Trader - Uptrend (Buy)
        // ============================================================
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100}; // <-- WAKE AGENT UP
        phase          = 7;
        emission_count = 0;
        
        $display("Phase 7 start: Momentum Buy (New=240, Old=200, Trend=+40 > Thresh 10)");
        
        repeat(PHASE7_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 7 end: %0d emissions", emission_count);

        // ============================================================
        // SETUP FOR MOMENTUM TRADER - DOWNTREND (PHASE 8)
        // ============================================================
        param_table[0] = 32'd0; // <-- MUTE AGENT DURING SETUP
        
        last_exec_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_exec_price = 32'h5F000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 190
        last_exec_price = 32'h5A000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 180
        last_exec_price = 32'h50000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 160

        // ============================================================
        // PHASE 8: Momentum Trader - Downtrend (Sell)
        // ============================================================
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100}; // <-- WAKE AGENT UP
        phase          = 8;
        emission_count = 0;
        
        $display("Phase 8 start: Momentum Sell (New=160, Old=200, Trend=-40 < Thresh -10)");
        
        repeat(PHASE8_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 8 end: %0d emissions", emission_count);

        // ============================================================
        // SETUP FOR MOMENTUM TRADER - SIDEWAYS (PHASE 9)
        // ============================================================
        param_table[0] = 32'd0; // <-- MUTE AGENT DURING SETUP
        
        last_exec_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_exec_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_exec_price = 32'h65000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 202
        last_exec_price = 32'h66000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 204

        // ============================================================
        // PHASE 9: Momentum Trader - Sideways (Silent)
        // ============================================================
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100}; // <-- WAKE AGENT UP
        phase          = 9;
        emission_count = 0;
        
        $display("Phase 9 start: Momentum Silent (New=204, Old=200, Trend=+4 <= Thresh 10)");
        
        repeat(PHASE9_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        
        $display("Phase 9 end: %0d emissions (expected 0)", emission_count);
        if (emission_count != 0)
            $display("FAIL: Phase 9 expected 0 emissions, got %0d", emission_count);
        else
            $display("PASS: Phase 9 silence confirmed");

        // ============================================================
        // SIMULATION COMPLETE
        // ============================================================
        $fclose(csv_file);
        $display("Done. Output: sim_output.csv");
        $display("Next: update and run python agent_golden_model.py");
        $stop;
    end

endmodule