///
/// @file tb_order_gen_top.v
/// @brief Integration testbench for order_gen_top covering reset, parameter loading, and structural packet checks.
///

`timescale 1ns/1ps

module tb_order_gen_top;

    localparam NUM_UNITS      = 16;
    localparam PTR_WIDTH      = 4;
    localparam SLOTS_PER_UNIT = 64;
    localparam SLOTS_LOG2     = 6;

    localparam AT_NOISE    = 2'b00;
    localparam AT_MM       = 2'b01;
    localparam AT_MOMENTUM = 2'b10;
    localparam AT_VALUE    = 2'b11;

    reg         clk;
    reg         rst_n;
    reg  [31:0] last_executed_price;
    reg         trade_valid;
    reg  [15:0] active_agent_count;
    reg         param_wr_en;
    reg  [15:0] param_wr_addr;
    reg  [31:0] param_wr_data;
    wire        order_ready;
    wire [31:0] order_packet;
    wire        order_valid;

    integer fd;
    integer cycle;
    integer phase;

    order_gen_top #(
        .NUM_UNITS        (NUM_UNITS),
        .PTR_WIDTH        (PTR_WIDTH),
        .SLOTS_PER_UNIT   (SLOTS_PER_UNIT)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .last_executed_price   (last_executed_price),
        .trade_valid       (trade_valid),
        .active_agent_count(active_agent_count),
        .param_wr_en       (param_wr_en),
        .param_wr_addr     (param_wr_addr),
        .param_wr_data     (param_wr_data),
        .order_packet      (order_packet),
        .order_valid       (order_valid),
        .order_ready       (order_ready)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial cycle = 0;
    always @(posedge clk) cycle = cycle + 1;

    reg draining;
    initial draining = 1'b0;

    // Drives order_ready high while draining so each presented packet handshakes through.
    assign order_ready = draining;

    // Logs every completed valid/ready transfer.
    always @(posedge clk) begin
        if (order_valid && order_ready) begin
            $fdisplay(fd, "%0d,%0d,%08h,%0d,%0d,%0d,%0d,%0d",
                cycle, phase, order_packet,
                order_packet[29:28], order_packet[31], order_packet[30],
                order_packet[24:16], order_packet[15:0]);
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

    task write_param;
        input integer unit_index;
        input integer slot_index;
        input [31:0]  data;
        begin
            @(posedge clk);
            param_wr_en   <= 1'b1;
            param_wr_addr <= (unit_index << SLOTS_LOG2) | slot_index;
            param_wr_data <= data;
            @(posedge clk);
            param_wr_en   <= 1'b0;
        end
    endtask

    task fill_unit;
        input integer unit_index;
        input [31:0]  data;
        integer slot;
        begin
            for (slot = 0; slot < SLOTS_PER_UNIT; slot = slot + 1) begin
                write_param(unit_index, slot, data);
            end
        end
    endtask

    // Drains the producer by holding order_ready high until order_valid stays low for several
    // cycles in a row, matching the showahead-OFF FIFO's read latency.
    task flush_fifo;
        integer idle_cycles;
        begin
            draining    = 1'b1;
            idle_cycles = 0;
            while (idle_cycles < 4) begin
                @(posedge clk);
                if (order_valid)
                    idle_cycles = 0;
                else
                    idle_cycles = idle_cycles + 1;
            end
            draining = 1'b0;
        end
    endtask

    // Parameter word layout:
    //   bits[31:30] = agent_type
    //   bits[29:20] = param1
    //   bits[19:10] = param2
    //   bits[9:0]   = param3
    localparam [31:0] PARAM_VALUE    = {2'b11, 10'd0,   10'd200, 10'd10};
    localparam [31:0] PARAM_NOISE    = {2'b00, 10'h3FF, 10'd1,   10'd10};
    localparam [31:0] PARAM_MM_STUB  = {2'b01, 10'd0,   10'd0,   10'd0};
    localparam [31:0] PARAM_VALUE_63 = {2'b11, 10'd0,   10'd200, 10'd63};

    integer unit;

    initial begin
        fd = $fopen("top_log.csv", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open top_log.csv");
            $finish;
        end
        $fdisplay(fd, "cycle,phase,packet,agent_type,side,order_type,price,volume");

        rst_n              = 1'b0;
        last_executed_price    = 32'h00100000;  // Q8.24 ~tick 0, guarantees divergence vs GBM.
        trade_valid        = 1'b0;
        active_agent_count = 16'd0;
        param_wr_en        = 1'b0;
        param_wr_addr      = 16'd0;
        param_wr_data      = 32'd0;
        draining           = 1'b0;
        phase              = 0;

        // PHASE 0: reset and load parameter tables.
        $display("=== PHASE 0: reset and param load ===");
        wait_cycles(4);
        rst_n = 1'b1;
        wait_cycles(2);

        $display("  Loading unit 0 -> value investor");
        fill_unit(0, PARAM_VALUE);

        $display("  Loading unit 1 -> noise trader");
        fill_unit(1, PARAM_NOISE);

        $display("  Loading units 2-15 -> MM stub");
        for (unit = 2; unit < NUM_UNITS; unit = unit + 1) begin
            fill_unit(unit, PARAM_MM_STUB);
        end

        wait_cycles(4);
        flush_fifo;

        // PHASE 1: active_agent_count=0, FIFO must stay empty.
        $display("=== PHASE 1: active_agent_count=0, expect empty FIFO ===");
        phase = 1;
        active_agent_count = 16'd0;
        wait_cycles(200);
        active_agent_count = 16'd0;
        wait_cycles(10);
        flush_fifo;

        // PHASE 2: active_agent_count=1, expect agent_type 11 and 00 only.
        $display("=== PHASE 2: active_agent_count=1, structural check ===");
        phase = 2;
        active_agent_count = 16'd1;
        wait_cycles(400);
        active_agent_count = 16'd0;
        wait_cycles(10);
        flush_fifo;

        // PHASE 3: active_agent_count=4, repeat structural checks.
        $display("=== PHASE 3: active_agent_count=4, structural check ===");
        phase = 3;
        active_agent_count = 16'd4;
        wait_cycles(800);
        active_agent_count = 16'd0;
        wait_cycles(10);
        flush_fifo;

        // PHASE 4: param decode spot-check, slot 0 takes vol_cap=63.
        $display("=== PHASE 4: param decode spot-check ===");
        phase = 4;
        write_param(1, 0, PARAM_MM_STUB);
        write_param(0, 0, PARAM_VALUE_63);
        active_agent_count = 16'd1;
        wait_cycles(400);
        active_agent_count = 16'd0;
        wait_cycles(10);
        flush_fifo;

        $display("=== SIM DONE ===");
        $fclose(fd);
        $finish;
    end

endmodule
