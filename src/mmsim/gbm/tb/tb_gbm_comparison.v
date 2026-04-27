///
/// @file tb_gbm_comparison.v
/// @brief Drives the Euler-Maruyama and log-space GBM candidates with an identical Z-stimulus
///        stream so the two implementations can be cross-checked sample-for-sample.
///

`timescale 1ns/1ns

module tb_gbm_comparison;

    // Parameters
    localparam CLK_PERIOD   = 20;       // 50 MHz
    localparam N_SAMPLES    = 1_000_000;
    localparam STALL_LIMIT  = 200;      

    // Clock and reset
    reg clk;
    reg rst_n;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Euler-Maruyama signals
    reg         z_valid_euler;
    reg  signed [15:0] z_in_euler;
    wire [31:0] price_out_euler;
    wire [31:0] sigma_out_euler;
    wire        price_valid_euler;

    gbm_euler #(
        .MU_ITO_FP_DEF  (32'sh00000000),
        .SIGMA_INIT_DEF (32'h00000451),
        .ALPHA_FP_DEF   (32'h00FD70A4),
        .P0_RECIP_DEF   (32'h00028F5C),
        .P0_INIT_DEF    (32'h64000000)
    ) dut_euler (
        .clk        (clk),
        .rst_n      (rst_n),
        .z_valid    (z_valid_euler),
        .z_in       (z_in_euler),
        .param_load (1'b0),
        .mu_ito_in  (32'sh0),
        .sigma_init_in(32'h0),
        .alpha_in   (32'h0),
        .p0_recip_in(32'h0),
        .price_out  (price_out_euler),
        .sigma_out  (sigma_out_euler),
        .price_valid(price_valid_euler)
    );

    // Log-Space signals
    reg         z_valid_log;
    reg  signed [15:0] z_in_log;
    wire [31:0] price_out_log;
    wire [31:0] sigma_out_log;
    wire        price_valid_log;

    gbm_logspace #(
        .MU_ITO_DT_DEF     (32'sh00000000),
        .SIGMA_SQRT_DT_DEF (32'sh00000451),
        .SIGMA_INIT_DEF    (32'h00000451),
        .ALPHA_FP_DEF      (32'h00FD70A4),
        .P0_RECIP_DEF      (32'h00028F5C)
    ) dut_log (
        .clk             (clk),
        .rst_n           (rst_n),
        .z_valid         (z_valid_log),
        .z_in            (z_in_log),
        .param_load      (1'b0),
        .mu_ito_dt_in    (32'sh0),
        .sigma_sqrt_dt_in(32'sh0),
        .sigma_init_in   (32'h0),
        .alpha_in        (32'h0),
        .p0_recip_in     (32'h0),
        .price_out       (price_out_log),
        .sigma_out       (sigma_out_log),
        .price_valid     (price_valid_log)
    );

    // Memory and file handles
    reg signed [15:0] z_samples [0:N_SAMPLES-1];
    integer           z_file_ok;
    integer euler_fd, log_fd, summary_fd;

    // Simulation state
    integer sample_idx;
    integer euler_count, log_count;
    integer cycle_count;
    integer stall_cycles_euler, stall_cycles_log;
    integer error_count;

    // Galois LFSR for fallback
    reg [31:0] lfsr_state;

    task lfsr_next;
        output [31:0] val;
        begin
            lfsr_state = {1'b0, lfsr_state[31:1]}
                       ^ (lfsr_state[0] ? 32'h80200003 : 32'h0);
            val = lfsr_state;
        end
    endtask

    function signed [15:0] lfsr_to_z;
        input [31:0] raw;
        begin
            lfsr_to_z = $signed(raw[31:16]);
        end
    endfunction

    // Assertion tasks
    task check_no_x_euler;
        begin
            if (^price_out_euler === 1'bx) begin
                $display("ERROR [%0t] Euler: X-propagation on price_out", $time);
                error_count = error_count + 1;
            end
            if (^sigma_out_euler === 1'bx) begin
                $display("ERROR [%0t] Euler: X-propagation on sigma_out", $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task check_no_x_log;
        begin
            if (^price_out_log === 1'bx) begin
                $display("ERROR [%0t] Log: X-propagation on price_out", $time);
                error_count = error_count + 1;
            end
            if (^sigma_out_log === 1'bx) begin
                $display("ERROR [%0t] Log: X-propagation on sigma_out", $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task check_positive_price_euler;
        begin
            if (price_valid_euler && (price_out_euler == 32'h0)) begin
                $display("ERROR [%0t] Euler: price_out = 0 (below PRICE_MIN)", $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task check_positive_price_log;
        begin
            if (price_valid_log && (price_out_log == 32'h0)) begin
                $display("ERROR [%0t] Log: price_out = 0 (below PRICE_MIN)", $time);
                error_count = error_count + 1;
            end
        end
    endtask

    // Stimulus and Monitoring
    integer i;
    reg [31:0] lfsr_raw;

    initial begin
        rst_n          = 0;
        z_valid_euler  = 0;
        z_valid_log    = 0;
        z_in_euler     = 16'sd0;
        z_in_log       = 16'sd0;
        sample_idx     = 0;
        euler_count    = 0;
        log_count      = 0;
        cycle_count    = 0;
        stall_cycles_euler = 0;
        stall_cycles_log   = 0;
        error_count    = 0;
        lfsr_state     = 32'hDEADBEEF;

        euler_fd = $fopen("gbm_euler_output.csv", "w");
        log_fd   = $fopen("gbm_logspace_output.csv", "w");
        if (euler_fd == 0 || log_fd == 0) begin 
            $display("ERROR: Output CSV file handle failed"); 
            $finish; 
        end

        $fdisplay(euler_fd, "tick,price_out_hex,sigma_out_hex");
        $fdisplay(log_fd,   "tick,price_out_hex,sigma_out_hex");

        $readmemh("z_samples.hex", z_samples);
        
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(3) @(posedge clk);

        $display("Starting simulation: Euler (14cyc) vs Log-Space (12cyc)");

        for (sample_idx = 0; sample_idx < N_SAMPLES; sample_idx = sample_idx + 1) begin
            @(posedge clk);
            z_valid_euler <= 1'b1;
            z_valid_log   <= 1'b1;
            z_in_euler    <= z_samples[sample_idx];
            z_in_log      <= z_samples[sample_idx];
            @(posedge clk);
            z_valid_euler <= 1'b0;
            z_valid_log   <= 1'b0;

            fork
                begin : wait_euler
                    stall_cycles_euler = 0;
                    while (!price_valid_euler) begin
                        @(posedge clk);
                        stall_cycles_euler = stall_cycles_euler + 1;
                        if (stall_cycles_euler > STALL_LIMIT) begin
                            $display("ERROR: Euler stall at sample %0d", sample_idx);
                            error_count = error_count + 1;
                            disable wait_euler;
                        end
                    end
                end
                begin : wait_log
                    stall_cycles_log = 0;
                    while (!price_valid_log) begin
                        @(posedge clk);
                        stall_cycles_log = stall_cycles_log + 1;
                        if (stall_cycles_log > STALL_LIMIT) begin
                            $display("ERROR: Log stall at sample %0d", sample_idx);
                            error_count = error_count + 1;
                            disable wait_log;
                        end
                    end
                end
            join

            euler_count = euler_count + 1;
            log_count   = log_count   + 1;

            if ((sample_idx + 1) % 100_000 == 0)
                $display("Progress: %0d samples, errors=%0d", sample_idx + 1, error_count);
        end

        $fclose(euler_fd);
        $fclose(log_fd);
        $display("SIMULATION COMPLETE: %0d errors", error_count);
        $finish;
    end

    // Data Logging
    integer euler_tick, log_tick;

    initial begin
        euler_tick = 0;
        log_tick   = 0;
    end

    always @(posedge clk) begin
        if (price_valid_euler) begin
            euler_tick = euler_tick + 1;
            $fdisplay(euler_fd, "%0d,%08h,%08h", euler_tick, price_out_euler, sigma_out_euler);
        end
    end

    always @(posedge clk) begin
        if (price_valid_log) begin
            log_tick = log_tick + 1;
            $fdisplay(log_fd, "%0d,%08h,%08h", log_tick, price_out_log, sigma_out_log);
        end
    end

    // Assertions
    always @(posedge clk) begin
        if (rst_n) begin
            check_no_x_euler;
            check_no_x_log;
        end
    end

    always @(posedge clk) begin
        if (rst_n && price_valid_euler) check_positive_price_euler;
    end

    always @(posedge clk) begin
        if (rst_n && price_valid_log) check_positive_price_log;
    end

    // Log-Space Pipeline Probe
    integer probe_fd, probe_tick;
    initial begin
        probe_fd = $fopen("gbm_logspace_probe.csv", "w");
        probe_tick = 0;
        $fdisplay(probe_fd, "tick,z_latch,diff_full,diffusion,L_reg,L_new,lut_addr,lut_data,P_new");
    end

    always @(posedge clk) begin
        if (price_valid_log && probe_tick < 20) begin
            probe_tick = probe_tick + 1;
            $fdisplay(probe_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08x,%08x",
                probe_tick,
                $signed(dut_log.z_latch),
                $signed(dut_log.diff_full),
                $signed(dut_log.diffusion),
                $signed(dut_log.L_reg),
                $signed(dut_log.L_new),
                dut_log.lut_addr,
                dut_log.lut_data,
                dut_log.P_new
            );
            if (probe_tick == 20) $fclose(probe_fd);
        end
    end

    // Counters
    always @(posedge clk) begin
        if (rst_n) cycle_count = cycle_count + 1;
    end

    // Timeout
    initial begin
        #(N_SAMPLES * 30 * CLK_PERIOD);
        $display("ERROR: Simulation timeout");
        $finish;
    end

endmodule