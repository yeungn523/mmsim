// tb_galois_lfsr.v
// Self-checking testbench for galois_lfsr.v. Covers reset, seed load, enable gating, early
// period sanity, bit uniformity, no-zero-lock, reproducibility, seed divergence, and exact
// sequence match against a Python golden model.
//
// ModelSim:
//   vlog galois_lfsr.v tb_galois_lfsr.v
//   vsim -do run_lfsr.tcl

`timescale 1ns/1ns

module tb_galois_lfsr;

// Parameters
parameter CLK_PERIOD  = 20;            // 50 MHz
parameter N_SAMPLES   = 100_000;       // samples used by the statistical tests
parameter POLY_PRIM   = 32'hB4BCD35C;  // primitive polynomial (maximal period)
parameter POLY_BAD    = 32'h00000001;  // non-primitive, short period
parameter SEED_A      = 32'hDEADBEEF;
parameter SEED_B      = 32'hCAFEBABE;

// DUT signals
reg        clk, rst_n, en, seed_valid;
reg [31:0] seed_load;
wire[31:0] out;

// DUT
galois_lfsr #(
    .POLY(POLY_PRIM),
    .SEED(SEED_A)
) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (en),
    .seed_load  (seed_load),
    .seed_valid (seed_valid),
    .out        (out)
);

// Clock
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// Tracking and bookkeeping
integer pass_count, fail_count;
integer csv_file;

task PASS;
    input [127:0] name;
    begin
        $display("  [PASS] %s", name);
        pass_count = pass_count + 1;
    end
endtask

task FAIL;
    input [127:0] name;
    input [63:0]  got;
    input [63:0]  expected;
    begin
        $display("  [FAIL] %s  got=%0h  expected=%0h", name, got, expected);
        fail_count = fail_count + 1;
    end
endtask

// Advances the simulation by a single clock cycle.
task tick;
    begin
        @(posedge clk); #1;
    end
endtask

// Advances the simulation by n clock cycles.
task tick_n;
    input integer n;
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) tick;
    end
endtask

// Asserts reset, drives inputs to a known state, then releases reset.
task do_reset;
    begin
        rst_n      = 0;
        en         = 0;
        seed_valid = 0;
        seed_load  = 0;
        tick_n(4);
        rst_n = 1;
        tick_n(2);
    end
endtask

// Statistical helpers (computed during simulation)
integer    ones_count;
integer    sample_idx;
reg [31:0] samples [0:N_SAMPLES-1];
reg [31:0] prev_out;
real       autocorr_sum, mean_val, var_val;
integer    bit_i;

// Storage for the period check
reg [31:0] first_val;
integer    period_count;
integer    period_found;

// Main test sequence
initial begin
    pass_count = 0;
    fail_count = 0;

    $display("\n====================================================");
    $display("  Galois LFSR Testbench");
    $display("  POLY=0x%08h  SEED=0x%08h", POLY_PRIM, SEED_A);
    $display("====================================================\n");

    // CSV consumed by the Python cross-check and visualization script.
    csv_file = $fopen("lfsr_samples.csv", "w");
    $fdisplay(csv_file, "index,value,bits_set");

    // TEST 1: Reset loads the SEED parameter.
    $display("TEST 1: Reset loads SEED parameter");
    do_reset;
    if (out === SEED_A)
        PASS("Reset to SEED_A");
    else
        FAIL("Reset to SEED_A", out, SEED_A);

    // TEST 2: Enable gating holds the output when en=0.
    $display("\nTEST 2: Enable gating (en=0 holds output)");
    do_reset;
    en = 1; tick; en = 0;                // advance one step before freezing
    prev_out = out;
    tick_n(10);                          // ten more clocks with en=0
    if (out === prev_out)
        PASS("Enable gate holds output");
    else
        FAIL("Enable gate holds output", out, prev_out);

    // TEST 3: seed_valid overrides the state mid-run.
    $display("\nTEST 3: Seed load overrides state mid-run");
    do_reset;
    en = 1; tick_n(20);
    seed_load  = SEED_B;
    seed_valid = 1;
    tick;                                // seed loads on this edge
    seed_valid = 0;
    if (out === SEED_B)
        PASS("Seed load overrides to SEED_B");
    else
        FAIL("Seed load overrides to SEED_B", out, SEED_B);

    // TEST 4: seed_valid suppresses the normal advance (seed wins over en).
    $display("\nTEST 4: seed_valid prevents LFSR advance (seed wins over en)");
    do_reset;
    en         = 1;
    seed_load  = SEED_B;
    seed_valid = 1;
    tick;
    seed_valid = 0;
    prev_out = out;                      // should be SEED_B
    tick;                                // advance normally on the next clock
    if (out !== prev_out)
        PASS("LFSR advanced after seed loaded");
    else
        FAIL("LFSR advanced after seed loaded", out, prev_out + 1);

    // TEST 5: No stuck-at-zero over N_SAMPLES. A primitive LFSR never visits 0.
    $display("\nTEST 5: No stuck-at-zero over %0d samples", N_SAMPLES);
    do_reset;
    en = 1;
    begin : zero_check
        integer i;
        integer found_zero;
        found_zero = 0;
        for (i = 0; i < N_SAMPLES; i = i + 1) begin
            tick;
            if (out === 32'h0) begin
                found_zero = 1;
                $display("  ZERO detected at sample %0d!", i);
                disable zero_check;
            end
        end
        if (!found_zero)
            PASS("No zero state in N_SAMPLES");
        else
            FAIL("No zero state in N_SAMPLES", 1, 0);
    end

    // TEST 6: Bit uniformity across N_SAMPLES. A primitive LFSR produces each bit with P(1)~=0.5;
    // allow 1% tolerance.
    $display("\nTEST 6: Bit uniformity over %0d samples", N_SAMPLES);
    do_reset;
    en = 1;
    ones_count = 0;
    for (sample_idx = 0; sample_idx < N_SAMPLES; sample_idx = sample_idx + 1) begin
        tick;
        samples[sample_idx] = out;
        for (bit_i = 0; bit_i < 32; bit_i = bit_i + 1)
            if (out[bit_i]) ones_count = ones_count + 1;
        $fdisplay(csv_file, "%0d,%0d,%0d",
            sample_idx, out, $countones(out));
    end

    begin : uniformity
        real ratio;
        real total_bits;
        total_bits = N_SAMPLES * 32.0;
        ratio = ones_count / total_bits;
        $display("  Ones ratio: %.4f  (ideal 0.5000, tolerance +/-0.01)", ratio);
        if (ratio > 0.49 && ratio < 0.51)
            PASS("Bit uniformity within 1%");
        else
            FAIL("Bit uniformity", ones_count, N_SAMPLES * 16);
    end

    // TEST 7: No early period repeat. The full period is 2^32 - 1, so the first 1000 cycles must
    // not revisit the starting value.
    $display("\nTEST 7: No early period repeat within 1000 cycles");
    do_reset;
    en = 1;
    tick;
    first_val    = out;
    period_found = 0;
    begin : period_check
        integer i;
        for (i = 0; i < 1000; i = i + 1) begin
            tick;
            if (out === first_val) begin
                $display("  Early repeat at cycle %0d!", i+1);
                period_found = 1;
                disable period_check;
            end
        end
    end
    if (!period_found)
        PASS("No period repeat in 1000 cycles");
    else
        FAIL("No period repeat in 1000 cycles", period_found, 0);

    // TEST 8: Reproducibility. The same seed must produce the same 16-sample sequence.
    $display("\nTEST 8: Reproducibility (same seed -> same sequence)");
    begin : repro
        reg [31:0] seq1 [0:15];
        reg [31:0] seq2 [0:15];
        integer i, mismatch;

        do_reset; en = 1;
        for (i = 0; i < 16; i = i + 1) begin tick; seq1[i] = out; end

        do_reset; en = 1;
        for (i = 0; i < 16; i = i + 1) begin tick; seq2[i] = out; end

        mismatch = 0;
        for (i = 0; i < 16; i = i + 1)
            if (seq1[i] !== seq2[i]) mismatch = mismatch + 1;

        if (mismatch == 0)
            PASS("Reproducibility: identical 16-sample sequences");
        else
            FAIL("Reproducibility", mismatch, 0);
    end

    // TEST 9: Different seeds must produce different sequences.
    $display("\nTEST 9: Different seeds produce different sequences");
    begin : diff_seeds
        reg [31:0] seqA [0:15];
        reg [31:0] seqB [0:15];
        integer i, match_count;

        do_reset; en = 1;
        for (i = 0; i < 16; i = i + 1) begin tick; seqA[i] = out; end

        do_reset;
        seed_load = SEED_B; seed_valid = 1; tick; seed_valid = 0;
        en = 1;
        for (i = 0; i < 16; i = i + 1) begin tick; seqB[i] = out; end

        match_count = 0;
        for (i = 0; i < 16; i = i + 1)
            if (seqA[i] === seqB[i]) match_count = match_count + 1;

        // All 16 samples matching by chance is vanishingly unlikely.
        if (match_count < 4)
            PASS("Different seeds give different sequences");
        else
            FAIL("Different seeds give different sequences", match_count, 0);
    end

    // TEST 10: Exact sequence match against the Python golden model.
    $display("\nTEST 10: Exact sequence match vs Python golden model");
    begin : exact_seq
        // Precomputed by lfsr_verify.galois_lfsr_step(SEED_A, POLY_PRIM).
        reg [31:0] expected [0:7];
        integer i, mismatch;
        expected[0] = 32'hDBEA0C2B;
        expected[1] = 32'hD949D549;
        expected[2] = 32'hD81839F8;
        expected[3] = 32'h6C0C1CFC;
        expected[4] = 32'h36060E7E;
        expected[5] = 32'h1B03073F;
        expected[6] = 32'hB93D50C3;
        expected[7] = 32'hE8227B3D;

        do_reset; en = 1;
        mismatch = 0;
        for (i = 0; i < 8; i = i + 1) begin
            tick;
            if (out !== expected[i]) begin
                $display("  Mismatch at step %0d: got 0x%08h expected 0x%08h",
                    i, out, expected[i]);
                mismatch = mismatch + 1;
            end
        end
        if (mismatch == 0)
            PASS("Exact 8-step sequence matches Python golden model");
        else begin
            $display("  *** Update expected[] from lfsr_verify.py output ***");
            FAIL("Exact sequence match", mismatch, 0);
        end
    end

    // Results summary
    $fclose(csv_file);
    $display("\n====================================================");
    $display("  RESULTS:  %0d passed,  %0d failed", pass_count, fail_count);
    $display("====================================================\n");

    if (fail_count == 0)
        $display("  ALL TESTS PASSED -- LFSR ready for integration\n");
    else
        $display("  FAILURES DETECTED -- do not integrate until resolved\n");

    $finish;
end

// Waveform dump
initial begin
    $dumpfile("lfsr_tb.vcd");
    $dumpvars(0, tb_galois_lfsr);
end

endmodule
