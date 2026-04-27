// tb_order_arbiter.v
// ModelSim testbench for order_arbiter.v  (Verilog 2001, -vlog01compat clean)
//
// Test plan:
//   T1: Basic round-robin — all units valid, grant order 0->1->...->7->0
//   T2: Sparse valid — only units 1,3,5, grant cycles through those only
//   T3: Stall on fifo_almost_full — zero grants while asserted
//   T4: Stall on fifo_full — zero grants while asserted
//   T5: Single unit valid (unit 3) — same unit granted every cycle
//   T6: Unit 2 deasserts mid-run — pointer skips it cleanly
//   T7: Stall then resume — grant_ptr must continue from saved position
//
// CSV output -> arbiter_log.csv
//   Header: cycle,event_type,unit,packet,wr_en,granted_mask
//   GRANT:  wr_en=1, unit=index of granted unit
//   STALL:  wr_en=0, unit=-1, FIFO throttle was active

`timescale 1ns/1ps

module tb_order_arbiter;

    localparam NUM_UNITS = 8;
    localparam PTR_WIDTH = 3;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    reg                      clk;
    reg                      rst_n;
    reg  [NUM_UNITS-1:0]     order_valid_in;
    reg  [NUM_UNITS*32-1:0]  order_packet_in;
    wire [NUM_UNITS-1:0]     order_granted;
    wire                     fifo_wr_en;
    wire [31:0]              fifo_din;
    reg                      fifo_almost_full;
    reg                      fifo_full;

    integer cycle;
    integer fd;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    order_arbiter #(
        .NUM_UNITS (NUM_UNITS),
        .PTR_WIDTH (PTR_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .order_valid_in   (order_valid_in),
        .order_packet_in  (order_packet_in),
        .order_granted    (order_granted),
        .fifo_wr_en       (fifo_wr_en),
        .fifo_din         (fifo_din),
        .fifo_almost_full (fifo_almost_full),
        .fifo_full        (fifo_full)
    );

    // -----------------------------------------------------------------------
    // Clock — 10 ns period
    // -----------------------------------------------------------------------
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // Cycle counter: increments on every posedge
    initial cycle = 0;
    always @(posedge clk) cycle = cycle + 1;

    // -----------------------------------------------------------------------
    // Logging: sample 1 ns after posedge so registered outputs are stable
    // -----------------------------------------------------------------------
    integer log_i;
    always @(posedge clk) begin
        #1;
        if (fifo_wr_en) begin
            for (log_i = 0; log_i < NUM_UNITS; log_i = log_i + 1) begin
                if (order_granted[log_i]) begin
                    $fdisplay(fd, "%0d,GRANT,%0d,%08h,%0d,%0h",
                              cycle, log_i, fifo_din,
                              fifo_wr_en, order_granted);
                end
            end
        end
        if (!fifo_wr_en && (fifo_almost_full || fifo_full)) begin
            $fdisplay(fd, "%0d,STALL,-1,00000000,0,%0h",
                      cycle, order_granted);
        end
    end

    // -----------------------------------------------------------------------
    // Helper task
    // -----------------------------------------------------------------------
    task wait_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Packet init — Verilog 2001, no SV casts
    // Canary: upper byte = 8'hA0 | unit[7:0], lower 16 = unit index
    // -----------------------------------------------------------------------
    integer u;
    task init_packets;
        begin
            for (u = 0; u < NUM_UNITS; u = u + 1) begin
                order_packet_in[u*32 +: 32] =
                    { (8'hA0 | u[7:0]), 8'h00, 8'h00, u[7:0] };
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Open log file (runs before main stimulus via initial ordering)
    // -----------------------------------------------------------------------
    initial begin
        fd = $fopen("arbiter_log.csv", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open arbiter_log.csv");
            $finish;
        end
        $fdisplay(fd, "cycle,event_type,unit,packet,wr_en,granted_mask");
    end

    // -----------------------------------------------------------------------
    // Main stimulus
    // -----------------------------------------------------------------------
    initial begin
        rst_n            = 1'b0;
        order_valid_in   = {NUM_UNITS{1'b0}};
        fifo_almost_full = 1'b0;
        fifo_full        = 1'b0;
        init_packets;

        // Hold reset for 2 cycles then release
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -------------------------------------------------------------------
        // T1: all units valid — 3 full laps, expect grants 0..7 repeating
        // -------------------------------------------------------------------
        $display("=== T1: all units valid, full round-robin ===");
        order_valid_in = {NUM_UNITS{1'b1}};
        wait_cycles(NUM_UNITS * 3);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // -------------------------------------------------------------------
        // T2: sparse — units 1, 3, 5 only
        // -------------------------------------------------------------------
        $display("=== T2: sparse valid (units 1,3,5) ===");
        order_valid_in = 8'b00101010;   // bits 1, 3, 5
        wait_cycles(12);                // expect 1->3->5->1->3->5->...
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // -------------------------------------------------------------------
        // T3: stall on fifo_almost_full
        // -------------------------------------------------------------------
        $display("=== T3: stall on fifo_almost_full ===");
        order_valid_in   = {NUM_UNITS{1'b1}};
        fifo_almost_full = 1'b1;
        wait_cycles(6);                 // must see only STALL rows
        $display("=== T3: almost_full cleared ===");
        fifo_almost_full = 1'b0;
        wait_cycles(4);                 // grants resume
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // -------------------------------------------------------------------
        // T4: stall on fifo_full
        // -------------------------------------------------------------------
        $display("=== T4: stall on fifo_full ===");
        order_valid_in = {NUM_UNITS{1'b1}};
        fifo_full      = 1'b1;
        wait_cycles(6);
        $display("=== T4: full cleared ===");
        fifo_full = 1'b0;
        wait_cycles(4);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // -------------------------------------------------------------------
        // T5: single unit — unit 3 only, should get every grant
        // -------------------------------------------------------------------
        $display("=== T5: single unit valid (unit 3) ===");
        order_valid_in = 8'b00001000;
        wait_cycles(8);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // -------------------------------------------------------------------
        // T6: unit 2 deasserts mid-run
        // -------------------------------------------------------------------
        $display("=== T6: unit 2 deasserts mid-run ===");
        order_valid_in = {NUM_UNITS{1'b1}};
        wait_cycles(3);
        order_valid_in[2] = 1'b0;
        wait_cycles(8);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        // -------------------------------------------------------------------
        // T7: stall then resume — pointer must not reset to 0
        // Grant 3 cycles (0,1,2), stall 4 cycles, resume expecting 3,4,...
        // -------------------------------------------------------------------
        $display("=== T7: stall then resume, pointer continuity ===");
        order_valid_in   = {NUM_UNITS{1'b1}};
        wait_cycles(3);
        fifo_almost_full = 1'b1;
        wait_cycles(4);
        fifo_almost_full = 1'b0;
        wait_cycles(6);
        order_valid_in = {NUM_UNITS{1'b0}};
        wait_cycles(2);

        $display("=== SIM DONE ===");
        $fclose(fd);
        $finish;
    end

endmodule