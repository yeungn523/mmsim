///
/// @file tb_order_arbiter.v
/// @brief ModelSim testbench for order_arbiter that exercises round-robin grants and downstream backpressure.
///

`timescale 1ns/1ps

module tb_order_arbiter;

    localparam NUM_UNITS = 8;
    localparam PTR_WIDTH = 3;

    reg                      clk;
    reg                      rst_n;
    reg  [NUM_UNITS-1:0]     order_valid_in;
    reg  [NUM_UNITS*32-1:0]  order_packet_in;
    wire [NUM_UNITS-1:0]     order_granted;
    wire [31:0]              order_packet;
    wire                     order_valid;
    reg                      order_ready;

    integer cycle;
    integer fd;

    order_arbiter #(
        .NUM_UNITS (NUM_UNITS),
        .PTR_WIDTH (PTR_WIDTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .order_valid_in  (order_valid_in),
        .order_packet_in (order_packet_in),
        .order_granted   (order_granted),
        .order_packet    (order_packet),
        .order_valid     (order_valid),
        .order_ready     (order_ready)
    );

    // 10 ns clock period.
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    initial cycle = 0;
    always @(posedge clk) cycle = cycle + 1;

    // Logs every accepted handshake (valid && ready) and every stall cycle (valid && !ready).
    integer log_index;
    always @(posedge clk) begin
        #1;
        if (order_valid && order_ready) begin
            for (log_index = 0; log_index < NUM_UNITS; log_index = log_index + 1) begin
                if (order_granted[log_index]) begin
                    $fdisplay(fd, "%0d,GRANT,%0d,%08h,1,%0h",
                              cycle, log_index, order_packet, order_granted);
                end
            end
        end
        if (order_valid && !order_ready) begin
            $fdisplay(fd, "%0d,STALL,-1,00000000,0,%0h",
                      cycle, order_granted);
        end
    end

    task wait_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    // Canary: upper byte = 8'hA0 | unit[7:0], lower 16 = unit index.
    integer unit;
    task init_packets;
        begin
            for (unit = 0; unit < NUM_UNITS; unit = unit + 1) begin
                order_packet_in[unit*32 +: 32] =
                    { (8'hA0 | unit[7:0]), 8'h00, 8'h00, unit[7:0] };
            end
        end
    endtask

    initial begin
        fd = $fopen("arbiter_log.csv", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open arbiter_log.csv");
            $finish;
        end
        $fdisplay(fd, "cycle,event_type,unit,packet,ready,granted_mask");
    end

    initial begin
        rst_n          = 1'b0;
        order_valid_in = {NUM_UNITS{1'b0}};
        order_ready    = 1'b1;
        init_packets;

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // T1: all units valid for 3 full laps; expect grants 0..7 repeating.
        $display("=== T1: all units valid, full round-robin ===");
        order_valid_in = {NUM_UNITS{1'b1}};
        wait_cycles(NUM_UNITS * 3);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // T2: sparse units 1, 3, 5; expect 1 -> 3 -> 5 cycle.
        $display("=== T2: sparse valid (units 1,3,5) ===");
        order_valid_in = 8'b00101010;
        wait_cycles(12);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // T3: stall by dropping order_ready; only STALL rows expected.
        $display("=== T3: stall on order_ready=0 ===");
        order_valid_in = {NUM_UNITS{1'b1}};
        order_ready    = 1'b0;
        wait_cycles(6);
        $display("=== T3: order_ready cleared ===");
        order_ready = 1'b1;
        wait_cycles(4);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // T4: only unit 3 valid; should receive every grant.
        $display("=== T4: single unit valid (unit 3) ===");
        order_valid_in = 8'b00001000;
        wait_cycles(8);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // T5: unit 2 deasserts mid-run; pointer must skip cleanly.
        $display("=== T5: unit 2 deasserts mid-run ===");
        order_valid_in = {NUM_UNITS{1'b1}};
        wait_cycles(3);
        order_valid_in[2] = 1'b0;
        wait_cycles(8);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // T6: stall then resume; pointer must continue from saved position.
        $display("=== T6: stall then resume, pointer continuity ===");
        order_valid_in = {NUM_UNITS{1'b1}};
        wait_cycles(3);
        order_ready = 1'b0;
        wait_cycles(4);
        order_ready = 1'b1;
        wait_cycles(6);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        $display("=== SIM DONE ===");
        $fclose(fd);
        $finish;
    end

endmodule
