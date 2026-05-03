`timescale 1ns/1ns

// Stores aggregate share quantities per price tick for one side of the limit order book.

module price_level_store #(
    parameter kPriceWidth    = 32,
    parameter kQuantityWidth = 16,
    // 1 = bid side, 0 = ask side.
    parameter kIsBid         = 1,
    parameter kPriceRange    = 480
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Command interface (valid/ready); command: 0=NOP, 1=INSERT, 2=CONSUME.
    input  wire [1:0]                  command,
    input  wire [kPriceWidth-1:0]      command_price,
    input  wire [kQuantityWidth-1:0]   command_quantity,
    input  wire                        command_valid,
    output reg                         command_ready,

    // Response reports only the affected share count; no per-order identifier.
    output reg  [kQuantityWidth-1:0]   response_quantity,
    output reg                         response_valid,

    // Top-of-book interface (combinational, always available).
    output wire [kPriceWidth-1:0]      best_price,
    output wire [kQuantityWidth-1:0]   best_quantity,
    output wire                        best_valid,

    // Time-multiplexes the VGA depth tap onto port B; safe since best_price advances only every 4 cycles.
    input  wire [8:0]                  depth_rd_addr,
    output wire [kQuantityWidth-1:0]   depth_rd_data
);

    // Command opcodes.
    localparam [1:0] kCommandNop     = 2'd0;
    localparam [1:0] kCommandInsert  = 2'd1;
    localparam [1:0] kCommandConsume = 2'd2;

    // Covers the 1-cycle M10K read latency plus a Settle cycle for the priority encoder.
    localparam [1:0] kStateIdle      = 2'd0;
    localparam [1:0] kStateReadFetch = 2'd1;
    localparam [1:0] kStateReadAct   = 2'd2;
    localparam [1:0] kStateSettle    = 2'd3;

    localparam kPriceIndexWidth = $clog2(kPriceRange);

    // Stores aggregate share quantities per price tick in a packed M10K array.
    (* ramstyle = "M10K" *) reg [kQuantityWidth-1:0] level_quantity [0:kPriceRange-1];

    // Mirrors level_quantity occupancy in flops so the priority encoder reads every slot in one cycle.
    reg level_valid [0:kPriceRange-1];

    // Initializes memory so simulation has defined values and Cyclone V emits a zero-filled MIF.
    integer init_iterator;
    initial begin
        for (init_iterator = 0; init_iterator < kPriceRange; init_iterator = init_iterator + 1) begin
            level_quantity[init_iterator] = {kQuantityWidth{1'b0}};
            level_valid[init_iterator] = 1'b0;
        end
    end

    // Port A handles command read-modify-writes; port B reads the best price's quantity in parallel.
    reg  [kPriceIndexWidth-1:0] port_a_addr;
    reg                         port_a_we;
    reg  [kQuantityWidth-1:0]   port_a_wdata;
    reg  [kQuantityWidth-1:0]   port_a_rdata;
    reg  [kQuantityWidth-1:0]   port_b_rdata;

    wire [kPriceIndexWidth-1:0] best_price_index;

    // Pipelines best_price_index by one cycle to relax timing on the M10K read path.
    reg [kPriceIndexWidth-1:0] best_price_index_r;
    always @(posedge clk) begin
        if (!rst_n) best_price_index_r <= {kPriceIndexWidth{1'b0}};
        else        best_price_index_r <= best_price_index;
    end

    // Drives the synchronous RMW port; port_a_rdata resets to zero rather than X before any read.
    always @(posedge clk) begin : level_quantity_port_a
        if (!rst_n) begin
            port_a_rdata <= {kQuantityWidth{1'b0}};
        end else begin
            if (port_a_we) level_quantity[port_a_addr] <= port_a_wdata;
            port_a_rdata <= level_quantity[port_a_addr];
        end
    end

    // Time-multiplexes port B between best_quantity and the VGA depth tap; port_b_phase_r demuxes the read.
    reg                         port_b_phase;
    reg                         port_b_phase_r;
    reg  [kPriceIndexWidth-1:0] port_b_addr_muxed;
    reg  [kQuantityWidth-1:0]   port_b_q;
    reg  [kQuantityWidth-1:0]   depth_rd_data_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            port_b_phase   <= 1'b0;
            port_b_phase_r <= 1'b0;
        end else begin
            port_b_phase   <= ~port_b_phase;
            port_b_phase_r <= port_b_phase;
        end
    end

    always @(*) begin
        port_b_addr_muxed = port_b_phase ? depth_rd_addr[kPriceIndexWidth-1:0]
                                         : best_price_index_r;
    end

    always @(posedge clk) begin : level_quantity_port_b
        if (!rst_n) begin
            port_b_q          <= {kQuantityWidth{1'b0}};
            port_b_rdata      <= {kQuantityWidth{1'b0}};
            depth_rd_data_reg <= {kQuantityWidth{1'b0}};
        end else begin
            port_b_q <= level_quantity[port_b_addr_muxed];
            if (port_b_phase_r) depth_rd_data_reg <= port_b_q;
            else                port_b_rdata      <= port_b_q;
        end
    end

    assign depth_rd_data = depth_rd_data_reg;

    // Resolves best_price_index in two stages: stage 1 picks a per-group winner, stage 2 picks the group.
    localparam kGroupSize        = (kPriceRange >= 64) ? 64 : kPriceRange;
    localparam kGroupCount       = (kPriceRange + kGroupSize - 1) / kGroupSize;
    localparam kGroupIndexWidth  = (kGroupSize  > 1) ? $clog2(kGroupSize)  : 1;
    localparam kGroupSelectWidth = (kGroupCount > 1) ? $clog2(kGroupCount) : 1;

    reg [kGroupIndexWidth-1:0] group_best_index_comb [0:kGroupCount-1];
    reg [kGroupCount-1:0]      group_nonempty_comb;
    integer                    group_iterator;
    integer                    slot_iterator;

    // Guards against indices beyond kPriceRange when kGroupSize does not divide it evenly.
    always @(*) begin : stage1_compute
        for (group_iterator = 0; group_iterator < kGroupCount; group_iterator = group_iterator + 1) begin
            group_best_index_comb[group_iterator] = {kGroupIndexWidth{1'b0}};
            group_nonempty_comb[group_iterator]   = 1'b0;
            if (kIsBid) begin
                for (slot_iterator = 0; slot_iterator < kGroupSize; slot_iterator = slot_iterator + 1) begin
                    if ((group_iterator * kGroupSize + slot_iterator) < kPriceRange) begin
                        if (level_valid[group_iterator * kGroupSize + slot_iterator]) begin
                            group_best_index_comb[group_iterator] = slot_iterator[kGroupIndexWidth-1:0];
                            group_nonempty_comb[group_iterator]   = 1'b1;
                        end
                    end
                end
            end else begin
                for (slot_iterator = kGroupSize - 1; slot_iterator >= 0; slot_iterator = slot_iterator - 1) begin
                    if ((group_iterator * kGroupSize + slot_iterator) < kPriceRange) begin
                        if (level_valid[group_iterator * kGroupSize + slot_iterator]) begin
                            group_best_index_comb[group_iterator] = slot_iterator[kGroupIndexWidth-1:0];
                            group_nonempty_comb[group_iterator]   = 1'b1;
                        end
                    end
                end
            end
        end
    end

    reg [kGroupIndexWidth-1:0] group_best_index_reg [0:kGroupCount-1];
    reg [kGroupCount-1:0]      group_nonempty_reg;

    always @(posedge clk) begin : stage1_register
        if (!rst_n) begin
            for (group_iterator = 0; group_iterator < kGroupCount; group_iterator = group_iterator + 1) begin
                group_best_index_reg[group_iterator] <= {kGroupIndexWidth{1'b0}};
            end
            group_nonempty_reg <= {kGroupCount{1'b0}};
        end else begin
            for (group_iterator = 0; group_iterator < kGroupCount; group_iterator = group_iterator + 1) begin
                group_best_index_reg[group_iterator] <= group_best_index_comb[group_iterator];
            end
            group_nonempty_reg <= group_nonempty_comb;
        end
    end

    reg [kGroupSelectWidth-1:0] winning_group;
    integer                     group_select_iterator;

    always @(*) begin : stage2_compute
        winning_group = {kGroupSelectWidth{1'b0}};
        if (kIsBid) begin
            for (group_select_iterator = 0; group_select_iterator < kGroupCount; group_select_iterator = group_select_iterator + 1) begin
                if (group_nonempty_reg[group_select_iterator])
                    winning_group = group_select_iterator[kGroupSelectWidth-1:0];
            end
        end else begin
            for (group_select_iterator = kGroupCount - 1; group_select_iterator >= 0; group_select_iterator = group_select_iterator - 1) begin
                if (group_nonempty_reg[group_select_iterator])
                    winning_group = group_select_iterator[kGroupSelectWidth-1:0];
            end
        end
    end

    generate
        if (kGroupCount > 1) begin : hier_assemble
            assign best_price_index = {winning_group, group_best_index_reg[winning_group]};
        end else begin : flat_assemble
            assign best_price_index = group_best_index_reg[0][kPriceIndexWidth-1:0];
        end
    endgenerate

    // Tracks the total number of populated levels so best_valid can be a cheap register check.
    reg [$clog2(kPriceRange + 1) - 1:0] level_count;

    assign best_price    = {{(kPriceWidth - kPriceIndexWidth){1'b0}}, best_price_index};
    assign best_quantity = port_b_rdata;
    // Hides the ~3-cycle port_b lag after a CONSUME empties the prior best by gating on best_quantity != 0.
    assign best_valid    = (level_count != 0) && (best_quantity != {kQuantityWidth{1'b0}});

    // Latches command fields and bookkeeping state when a command is accepted.
    reg [1:0]                  top_state;
    reg [1:0]                  working_command;
    reg [kPriceIndexWidth-1:0] working_price_index;
    reg [kQuantityWidth-1:0]   working_quantity;
    reg                        working_out_of_range;
    reg                        working_level_was_valid;
    reg [kQuantityWidth-1:0]   working_response_quantity;

    always @(posedge clk) begin : main_proc
        reg [kQuantityWidth-1:0]   old_quantity;
        reg [kQuantityWidth-1:0]   new_quantity;
        reg [kQuantityWidth-1:0]   amount_consumed;
        reg [kPriceIndexWidth-1:0] target_price_index;

        if (!rst_n) begin
            top_state                 <= kStateIdle;
            command_ready             <= 1'b1;
            response_valid            <= 1'b0;
            response_quantity         <= {kQuantityWidth{1'b0}};
            port_a_addr               <= {kPriceIndexWidth{1'b0}};
            port_a_we                 <= 1'b0;
            port_a_wdata              <= {kQuantityWidth{1'b0}};
            working_command           <= kCommandNop;
            working_price_index       <= {kPriceIndexWidth{1'b0}};
            working_quantity          <= {kQuantityWidth{1'b0}};
            working_out_of_range      <= 1'b0;
            working_level_was_valid   <= 1'b0;
            working_response_quantity <= {kQuantityWidth{1'b0}};
            level_count               <= {($clog2(kPriceRange + 1)){1'b0}};
            for (init_iterator = 0; init_iterator < kPriceRange; init_iterator = init_iterator + 1) begin
                level_valid[init_iterator] <= 1'b0;
            end
        end else begin
            // Default deassertions; individual states reassert as needed.
            port_a_we      <= 1'b0;
            response_valid <= 1'b0;

            case (top_state)
                kStateIdle: begin
                    if (command_valid && command_ready && command != kCommandNop) begin
                        working_command  <= command;
                        working_quantity <= command_quantity;

                        if (command == kCommandInsert) begin
                            target_price_index = command_price[kPriceIndexWidth-1:0];
                            working_out_of_range    <= (command_price >= kPriceRange);
                            working_price_index     <= target_price_index;
                            port_a_addr             <= target_price_index;
                            working_level_was_valid <= level_valid[target_price_index];
                        end else begin
                            // CONSUME targets the current best price. Skips the read and write when the book is
                            // empty; the response is then quantity zero.
                            working_out_of_range    <= 1'b0;
                            working_price_index     <= best_price_index;
                            port_a_addr             <= best_price_index;
                            working_level_was_valid <= (level_count != 0);
                        end

                        command_ready <= 1'b0;
                        top_state     <= kStateReadFetch;
                    end
                end

                kStateReadFetch: begin
                    // Absorbs the M10K read latency so port_a_rdata reflects the just-set address.
                    top_state <= kStateReadAct;
                end

                kStateReadAct: begin
                    old_quantity = port_a_rdata;

                    if (working_command == kCommandInsert) begin
                        if (working_out_of_range) begin
                            new_quantity              = {kQuantityWidth{1'b0}};
                            amount_consumed           = {kQuantityWidth{1'b0}};
                            working_response_quantity <= {kQuantityWidth{1'b0}};
                        end else begin
                            new_quantity              = old_quantity + working_quantity;
                            amount_consumed           = {kQuantityWidth{1'b0}};
                            working_response_quantity <= working_quantity;
                            port_a_addr               <= working_price_index;
                            port_a_wdata              <= new_quantity;
                            port_a_we                 <= 1'b1;
                            level_valid[working_price_index] <= 1'b1;
                            if (!working_level_was_valid) begin
                                level_count <= level_count + 1'b1;
                            end
                        end
                    end else begin
                        if (!working_level_was_valid) begin
                            new_quantity              = {kQuantityWidth{1'b0}};
                            amount_consumed           = {kQuantityWidth{1'b0}};
                            working_response_quantity <= {kQuantityWidth{1'b0}};
                        end else begin
                            if (working_quantity >= old_quantity) begin
                                amount_consumed = old_quantity;
                                new_quantity    = {kQuantityWidth{1'b0}};
                            end else begin
                                amount_consumed = working_quantity;
                                new_quantity    = old_quantity - working_quantity;
                            end
                            working_response_quantity <= amount_consumed;
                            port_a_addr               <= working_price_index;
                            port_a_wdata              <= new_quantity;
                            port_a_we                 <= 1'b1;
                            if (new_quantity == {kQuantityWidth{1'b0}}) begin
                                level_valid[working_price_index] <= 1'b0;
                                level_count <= level_count - 1'b1;
                            end
                        end
                    end

                    top_state <= kStateSettle;
                end

                kStateSettle: begin
                    // Lets the write commit and the encoder catch up before pulsing response_valid.
                    response_valid    <= 1'b1;
                    response_quantity <= working_response_quantity;
                    command_ready     <= 1'b1;
                    top_state         <= kStateIdle;
                end

                default: begin
                    top_state     <= kStateIdle;
                    command_ready <= 1'b1;
                end
            endcase
        end
    end

endmodule
