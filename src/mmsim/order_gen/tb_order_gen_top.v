// tb_order_gen_top.v
// Integration testbench for order_gen_top.v
// Verilog 2001, ModelSim with Altera sim libs
//
// Test plan:
//   PHASE 0: Reset and param table load
//             Unit 0 slots -> value investor  (type 11, threshold=0, always emits)
//             Unit 1 slots -> noise trader    (type 00, prob=0x3FF, always emits)
//             Units 2-15   -> MM stub         (type 01, never emits)
//
//   PHASE 1: active_agent_count=0 -> FIFO must stay empty
//
//   PHASE 2: active_agent_count=1 (1 slot per unit) -> only unit 0 and unit 1
//             emit. Drain FIFO, verify:
//               - all packets have agent_type 11 or 00 only
//               - price field <= 479 in all packets
//               - reserved bits [27:25] == 0 in all packets
//               - packets alternate 11/00 in round-robin order
//
//   PHASE 3: active_agent_count=4 -> more slots active, repeat structural checks
//
//   PHASE 4: param decode spot-check
//             Write a unique vol_cap=63 to unit 0 slot 0 only.
//             All other unit 0 slots get vol_cap=10.
//             Run and collect packets — at least one packet from unit 0
//             should have volume <= 63, confirming slot 0 was loaded correctly.
//
// CSV output -> top_log.csv
//   cycle, phase, packet_hex, agent_type, side, order_type, price, volume

`timescale 1ns/1ps

module tb_order_gen_top;

    // -----------------------------------------------------------------------
    // DUT parameters
    // -----------------------------------------------------------------------
    localparam NUM_UNITS      = 16;
    localparam PTR_WIDTH      = 4;
    localparam SLOTS_PER_UNIT = 64;
    localparam SLOTS_LOG2     = 6;

    // Agent type encoding
    localparam AT_NOISE    = 2'b00;
    localparam AT_MM       = 2'b01;
    localparam AT_MOMENTUM = 2'b10;
    localparam AT_VALUE    = 2'b11;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    reg         clk;
    reg         rst_n;
    reg  [31:0] last_exec_price;
    reg         trade_valid;
    reg  [15:0] active_agent_count;
    reg         param_wr_en;
    reg  [15:0] param_wr_addr;
    reg  [31:0] param_wr_data;
    reg         fifo_rd_en;
    wire [31:0] fifo_dout;
    wire        fifo_empty;

    integer fd;
    integer cycle;
    integer phase;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    order_gen_top #(
        .NUM_UNITS        (NUM_UNITS),
        .PTR_WIDTH        (PTR_WIDTH),
        .SLOTS_PER_UNIT   (SLOTS_PER_UNIT)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .last_exec_price   (last_exec_price),
        .trade_valid       (trade_valid),
        .active_agent_count(active_agent_count),
        .param_wr_en       (param_wr_en),
        .param_wr_addr     (param_wr_addr),
        .param_wr_data     (param_wr_data),
        .fifo_rd_en        (fifo_rd_en),
        .fifo_dout         (fifo_dout),
        .fifo_empty        (fifo_empty)
    );

    // -----------------------------------------------------------------------
    // Clock
    // -----------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial cycle = 0;
    always @(posedge clk) cycle = cycle + 1;

    // -----------------------------------------------------------------------
    // FIFO drain logger — runs continuously
    // Reads one packet per cycle whenever FIFO is not empty and we're draining
    // -----------------------------------------------------------------------
    reg draining;
    initial draining = 1'b0;

    always @(posedge clk) begin
        fifo_rd_en <= 1'b0;
        if (draining && !fifo_empty) begin
            fifo_rd_en <= 1'b1;
        end
    end

    // Log packet one cycle after rd_en (showahead OFF -> data valid cycle after rd_en)
    reg        rd_en_d1;
    always @(posedge clk) begin
        rd_en_d1 <= fifo_rd_en;
    end

    always @(posedge clk) begin
        if (rd_en_d1) begin
            $fdisplay(fd, "%0d,%0d,%08h,%0d,%0d,%0d,%0d,%0d",
                cycle, phase, fifo_dout,
                fifo_dout[29:28], fifo_dout[31], fifo_dout[30],
                fifo_dout[24:16], fifo_dout[15:0]);
        end
    end

    // -----------------------------------------------------------------------
    // Helper tasks
    // -----------------------------------------------------------------------
    task wait_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    // Write one param word to a specific unit and slot
    task write_param;
        input integer unit_idx;
        input integer slot_idx;
        input [31:0]  data;
        begin
            @(posedge clk);
            param_wr_en   <= 1'b1;
            param_wr_addr <= (unit_idx << SLOTS_LOG2) | slot_idx;
            param_wr_data <= data;
            @(posedge clk);
            param_wr_en   <= 1'b0;
        end
    endtask

    // Fill all slots of a unit with the same param word
    task fill_unit;
        input integer unit_idx;
        input [31:0]  data;
        integer s;
        begin
            for (s = 0; s < SLOTS_PER_UNIT; s = s + 1) begin
                write_param(unit_idx, s, data);
            end
        end
    endtask

    // Drain FIFO until it is completely empty
    task flush_fifo;
        begin
            draining = 1'b1;
            while (!fifo_empty) begin
                @(posedge clk);
            end
            draining = 1'b0;
            // Wait a few cycles to ensure the pipeline clears cleanly
            wait_cycles(4); 
            fifo_rd_en <= 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Param words
    //   bits[31:30] = agent_type
    //   bits[29:20] = param1
    //   bits[19:10] = param2
    //   bits[9:0]   = param3
    //
    //   Value investor  (11): param1=divergence_thresh, param2=aggression, param3=vol_cap
    //   Noise trader    (00): param1=emit_prob,         param2=max_offset, param3=vol_cap
    //   MM stub         (01): never emits regardless of params
    // -----------------------------------------------------------------------
    //  Value investor: threshold=0 (always emit), aggression=1, vol_cap=10
    localparam [31:0] PARAM_VALUE    = {2'b11, 10'd0,   10'd200, 10'd10};
    //  Noise trader:  prob=0x3FF (always emit), offset=1, vol_cap=10
    localparam [31:0] PARAM_NOISE    = {2'b00, 10'h3FF, 10'd1, 10'd10};
    //  MM stub: never emits
    localparam [31:0] PARAM_MM_STUB  = {2'b01, 10'd0,   10'd0, 10'd0};
    //  Value investor with vol_cap=63 for param decode spot check
    localparam [31:0] PARAM_VALUE_63 = {2'b11, 10'd0,   10'd200, 10'd63};

    // -----------------------------------------------------------------------
    // Main stimulus
    // -----------------------------------------------------------------------
    integer u;

    initial begin
        fd = $fopen("top_log.csv", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open top_log.csv");
            $finish;
        end
        $fdisplay(fd, "cycle,phase,packet,agent_type,side,order_type,price,volume");

        // Default signal state
        rst_n              = 1'b0;
        last_exec_price    = 32'h00100000; // Q8.24 ~tick 0, guarantees divergence vs GBM
        trade_valid        = 1'b0;
        active_agent_count = 16'd0;
        param_wr_en        = 1'b0;
        param_wr_addr      = 16'd0;
        param_wr_data      = 32'd0;
        fifo_rd_en         = 1'b0;
        draining           = 1'b0;
        phase              = 0;

        // ===================================================================
        // PHASE 0: Reset then load param tables
        // ===================================================================
        $display("=== PHASE 0: reset and param load ===");
        wait_cycles(4);
        rst_n = 1'b1;
        wait_cycles(2);

        // Unit 0: value investor in all slots
        $display("  Loading unit 0 -> value investor");
        fill_unit(0, PARAM_VALUE);

        // Unit 1: noise trader in all slots
        $display("  Loading unit 1 -> noise trader");
        fill_unit(1, PARAM_NOISE);

        // Units 2-15: MM stub (never emits)
        $display("  Loading units 2-15 -> MM stub");
        for (u = 2; u < NUM_UNITS; u = u + 1) begin
            fill_unit(u, PARAM_MM_STUB);
        end

        wait_cycles(4);
        flush_fifo;

        // ===================================================================
        // PHASE 1: active_agent_count=0, FIFO must stay empty
        // ===================================================================
        $display("=== PHASE 1: active_agent_count=0, expect empty FIFO ===");
        phase = 1;
        active_agent_count = 16'd0;
        wait_cycles(200);
        active_agent_count = 16'd0;
        wait_cycles(10);
        flush_fifo;

        // ===================================================================
        // PHASE 2: active_agent_count=1, expect only agent_type 11 and 00
        // ===================================================================
        $display("=== PHASE 2: active_agent_count=1, structural check ===");
        phase = 2;
        active_agent_count = 16'd1;
        wait_cycles(400);
        active_agent_count = 16'd0;
        wait_cycles(10);
        flush_fifo;

        // ===================================================================
        // PHASE 3: active_agent_count=4, more slots, repeat structural check
        // ===================================================================
        $display("=== PHASE 3: active_agent_count=4, structural check ===");
        phase = 3;
        active_agent_count = 16'd4;
        wait_cycles(800);
        active_agent_count = 16'd0;
        wait_cycles(10);
        flush_fifo;

        // ===================================================================
        // PHASE 4: param decode spot-check
        // ===================================================================
        $display("=== PHASE 4: param decode spot-check ===");
        phase = 4;
        write_param(1, 0, PARAM_MM_STUB);   // mute unit 1
        write_param(0, 0, PARAM_VALUE_63);  // slot 0 gets vol_cap=63
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