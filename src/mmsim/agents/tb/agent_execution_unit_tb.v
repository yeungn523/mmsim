///
/// @file agent_execution_unit_tb.v
/// @brief Phased deterministic testbench for agent_execution_unit; emits one CSV row per
///        order_valid pulse for the agents_verify Python golden model to score.
///
/// ModelSim:
///   vlog galois_lfsr.v agent_execution_unit.v agent_execution_unit_tb.v
///   vsim -do run_agents.tcl
///

`timescale 1ns/1ns

module agent_execution_unit_tb;

    // Parameters matching DUT instantiation.
    localparam [31:0] LFSR_POLY         = 32'hB4BCD35C;
    localparam [31:0] LFSR_SEED         = 32'hCAFEBABE;
    localparam [8:0]  NEAR_NOISE_THRESH = 9'd16;

    localparam CLK_PERIOD = 20; // 50 MHz

    // Keeps each phase length a multiple of 4 (one FSM slot = 4 cycles); non-multiples cause
    // param swaps mid-slot and corrupt the captured emissions.
    localparam PHASE1_CYCLES = 400;
    localparam PHASE2_CYCLES = 200;
    localparam PHASE3_CYCLES = 4000;
    localparam PHASE4_CYCLES = 200;
    localparam PHASE5_CYCLES = 200;
    localparam PHASE6_CYCLES = 200;
    localparam PHASE7_CYCLES = 200;
    localparam PHASE8_CYCLES = 200;
    localparam PHASE9_CYCLES = 200;

    // DUT signals: reg for driven inputs, wire for outputs.
    reg         clk;
    reg         rst_n;
    reg  [31:0] gbm_price;
    reg  [31:0] last_executed_price;
    reg  [15:0] sigma;
    reg         trade_valid;
    wire [15:0] param_addr;
    reg  [31:0] param_data;
    reg  [15:0] active_agent_count;
    wire [31:0] order_packet;
    wire        order_valid;

    // Testbench-internal scoreboard state.
    integer csv_file;
    integer cycle_count;
    integer phase;
    integer emission_count;
    integer i;

    // Simulates the M10K param ROM by driving param_data from param_table; the registered read
    // matches the real M10K 1-cycle latency.
    reg [31:0] param_table [0:63];

    always @(posedge clk) begin
        param_data <= param_table[param_addr];
    end

    // DUT instantiation.
    agent_execution_unit #(
        .NUM_AGENT_SLOTS  (64),
        .LFSR_POLY        (LFSR_POLY),
        .LFSR_SEED        (LFSR_SEED),
        .NEAR_NOISE_THRESH(NEAR_NOISE_THRESH)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .gbm_price         (gbm_price),
        .last_executed_price (last_executed_price),
        .sigma             (sigma),
        .trade_valid       (trade_valid),
        .param_addr        (param_addr),
        .param_data        (param_data),
        .active_agent_count(active_agent_count),
        .order_packet      (order_packet),
        .order_valid       (order_valid)
    );

    // Clock generation.
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Cycle counter.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    // Dumps one CSV row per order_valid pulse, capturing the input snapshot at the moment of
    // emission.
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

    // Main stimulus.
    initial begin
        csv_file = $fopen("sim_output.csv", "w");
        $fwrite(csv_file, "cycle,phase,side,order_type,agent_type,price,volume,gbm_price_in,param_data_in\n");

        // Initializes the driven signals.
        rst_n              = 0;
        trade_valid        = 0;
        active_agent_count = 16'd1;
        emission_count     = 0;

        // Sets up phase 1 stimuli while reset is held low.
        phase           = 1;
        gbm_price       = 32'h64000000; // Q8.24 = 100.0, tick = 200
        last_executed_price = 32'h64000000;
        sigma           = 16'h0100;

        for (i = 0; i < 64; i = i + 1)
            param_table[i] = 32'd0;

        // Slot 0: always-emit noise trader
        param_table[0] = {2'b00, 10'h3FF, 10'd50, 10'd100};

        repeat(4) @(posedge clk);
        @(negedge clk); // Releases reset on negedge so the FSM wakes on the next posedge.
        rst_n = 1;

        // Phase 1: always-emit noise trader.
        $display("Phase 1 start: always-emit noise trader, gbm_tick=200, max_offset=50, max_vol=100");

        repeat(PHASE1_CYCLES) @(posedge clk);
        #1; // Guards against the param-swap/FSM-read race before changing parameters.

        // Updates params here so the FSM reads them on the next slot.
        param_table[0] = {2'b00, 10'h000, 10'd50, 10'd100};

        // Waits one cycle so the CSV writer logs the final Phase 1 order.
        @(posedge clk);
        $display("Phase 1 end: %0d emissions in %0d cycles", emission_count, PHASE1_CYCLES);

        // Phase 2: never-emit noise trader.
        phase          = 2;
        emission_count = 0;
        $display("Phase 2 start: never-emit noise trader");

        // Subtracts one cycle to compensate for the carry-over consumed by Phase 1's CSV flush.
        repeat(PHASE2_CYCLES - 1) @(posedge clk);
        #1; // Guards against the param-swap/FSM-read race.

        // Updates params for Phase 3.
        param_table[0] = {2'b00, 10'd512, 10'd50, 10'd100};

        // Waits one cycle for the CSV flush.
        @(posedge clk);
        $display("Phase 2 end: %0d emissions (expected 0)", emission_count);
        if (emission_count != 0)
            $display("FAIL: Phase 2 expected 0 emissions, got %0d", emission_count);
        else
            $display("PASS: Phase 2 silence confirmed");

        // Phase 3: ~50% emit.
        phase          = 3;
        emission_count = 0;
        $display("Phase 3 start: 50pct emission, running %0d cycles", PHASE3_CYCLES);

        // Subtracts one cycle to absorb the Phase 2 CSV-flush carry-over.
        repeat(PHASE3_CYCLES - 1) @(posedge clk);
        #1;

        // Waits one final cycle so the last order makes it into the CSV.
        @(posedge clk);
        $display("Phase 3 end: %0d emissions out of %0d evaluations", emission_count, PHASE3_CYCLES/4);

        if (emission_count >= 400 && emission_count <= 600)
            $display("PASS: Phase 3 emission rate within expected range");
        else
            $display("WARN: Phase 3 emission count %0d outside 400-600", emission_count);


        // Pulses trade_valid before phases 4-6 so exec_price_shift_reg catches the seed price.
        last_executed_price = 32'h64000000; // Q8.24 = 100.0, tick = 200
        trade_valid     = 1;
        @(posedge clk);
        #1; 
        trade_valid     = 0;

        repeat(3) @(posedge clk);
        #1;

        // Phase 4: Value Investor undervalued (buy).
        phase          = 4;
        emission_count = 0;
        gbm_price      = 32'h78000000; // Q8.24 = 120.0, tick = 240

        // Encodes the value-investor param packet: type=11, threshold=10, aggression=256, cap=100.
        param_table[0] = {2'b11, 10'd10, 10'd256, 10'd100};

        $display("Phase 4 start: Value Buy (GBM=240, Exec=200, Div=+40 > Thresh 10)");

        repeat(PHASE4_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 4 end: %0d emissions", emission_count);


        // Phase 5: Value Investor overvalued (sell).
        phase          = 5;
        emission_count = 0;
        gbm_price      = 32'h50000000; // Q8.24 = 80.0, tick = 160

        $display("Phase 5 start: Value Sell (GBM=160, Exec=200, Div=-40 < Thresh -10)");

        repeat(PHASE5_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 5 end: %0d emissions", emission_count);


        // Phase 6: Value Investor within threshold (silent).
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


        // Primes the shift register with four consecutive uptrend trades (200, 210, 220, 240) so
        // reg_3 = 200 (oldest), reg_0 = 240 (newest), delta = +40. Encodes the momentum-trader
        // param packet: type=10, threshold=10, aggression=256, cap=100.
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100};

        last_executed_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_executed_price = 32'h69000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 210
        last_executed_price = 32'h6E000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 220
        last_executed_price = 32'h78000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 240

        // Re-primes the shift register with the agent muted so the setup pulses do not pollute
        // the Phase 7 emission count.
        param_table[0] = 32'd0;

        last_executed_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_executed_price = 32'h69000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 210
        last_executed_price = 32'h6E000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 220
        last_executed_price = 32'h78000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 240

        // Phase 7: Momentum Trader uptrend (buy).
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100}; // Re-enables the agent for the phase under test.
        phase          = 7;
        emission_count = 0;
        
        $display("Phase 7 start: Momentum Buy (New=240, Old=200, Trend=+40 > Thresh 10)");
        
        repeat(PHASE7_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 7 end: %0d emissions", emission_count);

        // Primes the shift register with four consecutive downtrend trades (200, 190, 180, 160)
        // with the agent muted so only Phase 8 emissions are counted.
        param_table[0] = 32'd0;

        last_executed_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_executed_price = 32'h5F000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 190
        last_executed_price = 32'h5A000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 180
        last_executed_price = 32'h50000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 160

        // Phase 8: Momentum Trader downtrend (sell).
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100}; // Re-enables the agent for the phase under test.
        phase          = 8;
        emission_count = 0;
        
        $display("Phase 8 start: Momentum Sell (New=160, Old=200, Trend=-40 < Thresh -10)");
        
        repeat(PHASE8_CYCLES - 1) @(posedge clk);
        #1;
        @(posedge clk);
        $display("Phase 8 end: %0d emissions", emission_count);

        // Primes the shift register with four near-flat trades (200, 200, 202, 204) with the
        // agent muted so only Phase 9 emissions are counted.
        param_table[0] = 32'd0;

        last_executed_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_executed_price = 32'h64000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 200
        last_executed_price = 32'h65000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 202
        last_executed_price = 32'h66000000; trade_valid = 1; @(posedge clk); #1; trade_valid = 0; repeat(3) @(posedge clk); #1; // tick 204

        // Phase 9: Momentum Trader sideways (silent).
        param_table[0] = {2'b10, 10'd10, 10'd256, 10'd100}; // Re-enables the agent for the phase under test.
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

        // Closes out the simulation and hands the CSV off to the verifier.
        $fclose(csv_file);
        $display("Done. Output: sim_output.csv");
        $display("Next: update and run python agents_verify.py");
        $stop;
    end

endmodule