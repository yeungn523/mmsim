///
/// @file tb_gaussian_comparison.v
/// @brief Compares the CLT-12 and ROM-backed Ziggurat Gaussian generators by sampling each in
///        parallel and emitting per-sample CSVs for downstream statistical verification.
///
/// Outputs:
///   clt12_samples.csv      -- sample_index, raw_q115, float_value
///   ziggurat_samples.csv   -- sample_index, raw_q115, float_value
///

`timescale 1ns/1ns

module tb_gaussian_comparison;

    // Parameters
    parameter N_SAMPLES  = 1000000;
    parameter CLK_PERIOD = 20;  // 50 MHz

    // Signals
    reg        clk, rst_n;
    reg        en_clt, en_zig;            // separate enables driven independently
    reg [31:0] seed0, seed1, seed2, seed3;
    reg        seed_valid;

    wire [15:0] clt_out;
    wire        clt_valid;
    wire [15:0] zig_out;
    wire        zig_valid;

    // DUTs
    clt12_gaussian dut_clt (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en_clt),
        .seed0      (seed0),
        .seed1      (seed1),
        .seed2      (seed2),
        .seed3      (seed3),
        .seed_valid (seed_valid),
        .gauss_out  (clt_out),
        .valid_out  (clt_valid)
    );

    ziggurat_gaussian dut_zig (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en_zig),
        .seed0      (seed0),
        .seed1      (seed1),
        .seed2      (seed2),
        .seed3      (seed3),
        .seed_valid (seed_valid),
        .gauss_out  (zig_out),
        .valid_out  (zig_valid)
    );

    // Clock
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // File handles and counters
    integer clt_file, zig_file;
    integer clt_count, zig_count;
    integer t_start, t_clt_done, t_zig_done;

    // Re-enables the Ziggurat generator after each valid output. The FSM idles between samples,
    // so en_zig is pulsed high for one cycle whenever the previous sample completes. CLT-12 is
    // pipelined and stays enabled continuously.
    always @(posedge clk) begin
        if (!rst_n || seed_valid) begin
            en_zig <= 1'b0;
        end else if (zig_valid && zig_count < N_SAMPLES - 1) begin
            en_zig <= 1'b1;
        end else if (en_zig) begin
            en_zig <= 1'b0;
        end
    end

    // Stimulus
    initial begin
        clt_file = $fopen("clt12_samples.csv", "w");
        zig_file = $fopen("ziggurat_samples.csv", "w");

        if (clt_file == 0 || zig_file == 0) begin
            $display("ERROR: Could not open output files");
            $finish;
        end

        $fdisplay(clt_file, "sample_index,raw_q115,float_value");
        $fdisplay(zig_file, "sample_index,raw_q115,float_value");

        rst_n      = 0;
        en_clt     = 0;
        en_zig     = 0;
        seed_valid = 0;
        seed0      = 32'hDEADBEEF;
        seed1      = 32'hCAFEBABE;
        seed2      = 32'h12345678;
        seed3      = 32'hABCDEF01;
        clt_count  = 0;
        zig_count  = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // Loads seeds into both DUTs simultaneously.
        seed_valid = 1;
        @(posedge clk);
        seed_valid = 0;
        repeat(3) @(posedge clk);

        $display("Starting: %0d samples from each generator", N_SAMPLES);

        t_start = $time;
        en_clt = 1;
        en_zig = 1;

        wait(clt_count >= N_SAMPLES);
        t_clt_done = $time;
        $display("CLT-12:   %0d cycles for %0d samples = %.2f cycles/sample",
            (t_clt_done - t_start)/CLK_PERIOD, N_SAMPLES,
            $itor(t_clt_done - t_start) / CLK_PERIOD / N_SAMPLES);
        en_clt = 0;

        wait(zig_count >= N_SAMPLES);
        t_zig_done = $time;
        $display("Ziggurat: %0d cycles for %0d samples = %.2f cycles/sample",
            (t_zig_done - t_start)/CLK_PERIOD, N_SAMPLES,
            $itor(t_zig_done - t_start) / CLK_PERIOD / N_SAMPLES);

        repeat(5) @(posedge clk);
        $display("=== SUMMARY ===");
        $display("CLT-12   cycles/sample: %.2f", $itor(t_clt_done - t_start) / CLK_PERIOD / N_SAMPLES);
        $display("Ziggurat cycles/sample: %.2f", $itor(t_zig_done - t_start) / CLK_PERIOD / N_SAMPLES);
        $display("Ziggurat overhead: %.1fx slower", $itor(t_zig_done - t_start) / $itor(t_clt_done - t_start));
        $display("CLT-12   samples: %0d / %0d", clt_count, N_SAMPLES);
        $display("Ziggurat samples: %0d / %0d", zig_count, N_SAMPLES);
        $fclose(clt_file);
        $fclose(zig_file);
        $finish;
    end

    // Captures CLT-12 samples into the CSV.
    always @(posedge clk) begin
        if (clt_valid && clt_count < N_SAMPLES && clt_file != 0) begin
            $fdisplay(clt_file, "%0d,%0d,%f",
                clt_count,
                $signed(clt_out),
                $itor($signed(clt_out)) / 4096.0);
            clt_count = clt_count + 1;
        end
    end

    // Captures Ziggurat samples into the CSV.
    always @(posedge clk) begin
        if (zig_valid && zig_count < N_SAMPLES && zig_file != 0) begin
            $fdisplay(zig_file, "%0d,%0d,%f",
                zig_count,
                $signed(zig_out),
                $itor($signed(zig_out)) / 32768.0);
            zig_count = zig_count + 1;
        end
    end

    // Prints a progress summary every 1000 clock cycles.
    initial begin
        forever begin
            #(CLK_PERIOD * 1000);
            $display("t=%0t ns | CLT: %0d/%0d | Zig: %0d/%0d",
                $time, clt_count, N_SAMPLES, zig_count, N_SAMPLES);
        end
    end

    // Warns on X propagation in either generator output.
    always @(posedge clk) begin
        if (clt_valid && ^clt_out === 1'bx)
            $display("WARN: CLT-12 X output at t=%0t", $time);
        if (zig_valid && ^zig_out === 1'bx)
            $display("WARN: Ziggurat X output at t=%0t", $time);
    end

    // Detects Ziggurat FSM stalls. If the generator does not produce a valid output within ~200
    // cycles of being enabled, flags a likely hang.
    integer zig_stall_ctr;
    always @(posedge clk) begin
        if (!rst_n) begin
            zig_stall_ctr <= 0;
        end else if (en_zig) begin
            zig_stall_ctr <= 0;
        end else if (zig_count > 0 && zig_count < N_SAMPLES && !zig_valid) begin
            zig_stall_ctr <= zig_stall_ctr + 1;
            if (zig_stall_ctr > 200) begin
                $display("ERROR: Ziggurat FSM stall detected at t=%0t (>200 cycles without valid)",
                         $time);
                zig_stall_ctr <= 0;
            end
        end else begin
            zig_stall_ctr <= 0;
        end
    end

    // Waveform dump
    initial begin
        $dumpfile("gaussian_comparison.vcd");
        $dumpvars(0, tb_gaussian_comparison);
    end

endmodule
