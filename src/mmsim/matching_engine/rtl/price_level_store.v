`timescale 1ns/1ns

///
/// @file price_level_store.v
/// @brief Stores aggregate share quantities per price tick for one side of the limit order book.
///

module price_level_store #(
    parameter kPriceWidth    = 32,    ///< Bit width of the price field (unsigned ticks).
    parameter kQuantityWidth = 16,    ///< Bit width of the quantity field.
    parameter kIsBid         = 1,     ///< Determines whether the instance manages the bid (1) or ask (0) side.
    parameter kPriceRange    = 480    ///< Number of addressable price ticks (matches agent packet range).
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Command interface (valid/ready handshake). Two-bit command field supports NOP, INSERT,
    // and CONSUME.
    input  wire [1:0]                  command,          ///< Selects the operation: 0=NOP, 1=INSERT, 2=CONSUME.
    input  wire [kPriceWidth-1:0]      command_price,    ///< Limit price for INSERT (ignored for CONSUME).
    input  wire [kQuantityWidth-1:0]   command_quantity, ///< Share count to insert or to consume.
    input  wire                        command_valid,    ///< Asserts when a command is offered.
    output reg                         command_ready,    ///< Asserts when the store can accept a command.

    // Response interface reports only the affected share count; no per-order identifier.
    output reg  [kQuantityWidth-1:0]   response_quantity, ///< Shares inserted, or total shares consumed.
    output reg                         response_valid,    ///< Pulses high for one cycle per response.

    // Top-of-book interface (combinational, always available).
    output wire [kPriceWidth-1:0]      best_price,        ///< Best resting price for the configured side.
    output wire [kQuantityWidth-1:0]   best_quantity,     ///< Aggregate share count at the best price.
    output wire                        best_valid         ///< Asserts when at least one price holds shares.
);

    // Command opcodes.
    localparam [1:0] kCommandNop     = 2'd0;  ///< Skips the cycle without modifying the book.
    localparam [1:0] kCommandInsert  = 2'd1;  ///< Adds a quantity to the level at command_price.
    localparam [1:0] kCommandConsume = 2'd2;  ///< Consumes shares from the current best price.

    // Top-level FSM states. Four states are needed because the M10K read has 1 cycle of latency:
    // the address must be presented one cycle before port_a_rdata reflects it. The Settle state
    // additionally lets the priority encoder pipeline catch up before the next command latches.
    localparam [1:0] kStateIdle      = 2'd0;  ///< Waits for a new command and registers the read address.
    localparam [1:0] kStateReadFetch = 2'd1;  ///< Lets port_a_rdata catch up to the just-set address.
    localparam [1:0] kStateReadAct   = 2'd2;  ///< Captures port_a_rdata, computes the new value, drives the write.
    localparam [1:0] kStateSettle    = 2'd3;  ///< Lets the write and priority encoder propagate, then pulses response_valid.

    localparam kPriceIndexWidth = $clog2(kPriceRange);  ///< Bit width required to index a price tick.

    // Stores aggregate share quantities indexed by price tick in a single packed M10K array.
    (* ramstyle = "M10K" *) reg [kQuantityWidth-1:0] level_quantity [0:kPriceRange-1];

    // Mirrors level_quantity occupancy in flops so the priority encoder can read every slot in
    // one cycle, which is not possible from M10K. The flag array updates in lockstep with
    // level_quantity writes.
    reg level_valid [0:kPriceRange-1];

    // Initializes memory contents so simulation sees defined values and synthesis emits the
    // zero-filled memory-initialization image that Cyclone V supports.
    integer init_iterator;
    initial begin
        for (init_iterator = 0; init_iterator < kPriceRange; init_iterator = init_iterator + 1) begin
            level_quantity[init_iterator] = {kQuantityWidth{1'b0}};
            level_valid[init_iterator] = 1'b0;
        end
    end

    // Port A carries the read-modify-write traffic for the active command. Port B continuously
    // reads the best price's level_quantity so best_quantity is available without tying up the
    // command path.
    reg  [kPriceIndexWidth-1:0] port_a_addr;
    reg                         port_a_we;
    reg  [kQuantityWidth-1:0]   port_a_wdata;
    reg  [kQuantityWidth-1:0]   port_a_rdata;
    reg  [kQuantityWidth-1:0]   port_b_rdata;

    wire [kPriceIndexWidth-1:0] best_price_index;

    // Pipelines best_price_index by one cycle so the wide priority-encoder fan-in is registered
    // before driving the M10K read address; this relaxes timing on the best-price read path.
    reg [kPriceIndexWidth-1:0] best_price_index_r;
    always @(posedge clk) begin
        if (!rst_n) best_price_index_r <= {kPriceIndexWidth{1'b0}};
        else        best_price_index_r <= best_price_index;
    end

    // Drives the synchronous read-modify-write port and resets the output register so
    // port_a_rdata starts at zero rather than X before any read has issued.
    always @(posedge clk) begin : level_quantity_port_a
        if (!rst_n) begin
            port_a_rdata <= {kQuantityWidth{1'b0}};
        end else begin
            if (port_a_we) level_quantity[port_a_addr] <= port_a_wdata;
            port_a_rdata <= level_quantity[port_a_addr];
        end
    end

    // Drives the synchronous read for the best-price quantity off the registered index so the
    // priority encoder + wide mux split into two pipeline stages, and resets the output register
    // so best_quantity reads zero before any command has executed.
    always @(posedge clk) begin : level_quantity_port_b
        if (!rst_n) begin
            port_b_rdata <= {kQuantityWidth{1'b0}};
        end else begin
            port_b_rdata <= level_quantity[best_price_index_r];
        end
    end

    // Implements a two-stage pipelined priority encoder that resolves best_price_index from the
    // occupancy bitmap. Stage 1 reduces each group of kGroupSize prices to a per-group winner
    // index and nonempty flag; stage 2 picks the winning group across all groups.
    localparam kGroupSize        = (kPriceRange >= 64) ? 64 : kPriceRange;
    localparam kGroupCount       = (kPriceRange + kGroupSize - 1) / kGroupSize;
    localparam kGroupIndexWidth  = (kGroupSize  > 1) ? $clog2(kGroupSize)  : 1;
    localparam kGroupSelectWidth = (kGroupCount > 1) ? $clog2(kGroupCount) : 1;

    reg [kGroupIndexWidth-1:0] group_best_index_comb [0:kGroupCount-1];
    reg [kGroupCount-1:0]      group_nonempty_comb;
    integer                    group_iterator;
    integer                    slot_iterator;

    // Bounds guard on the level_valid access is required when kPriceRange is not an integer
    // multiple of kGroupSize (e.g., 480 / 64 = 7.5 groups). The last group's upper slots
    // address indices >= kPriceRange that the array does not declare. Both loop variables are
    // compile-time constants after unrolling, so synthesis constant-folds the guard away and
    // the out-of-range branches simply disappear from the netlist.
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
    assign best_valid    = (level_count != 0);

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
                            // CONSUME targets the current best price. Skips the read and write
                            // when the book is empty; the response is then quantity zero.
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
                    // Absorbs the M10K read pipeline latency. By the end of this cycle,
                    // port_a_rdata reflects level_quantity[port_a_addr] for the just-set address
                    // rather than the previous command's address.
                    top_state <= kStateReadAct;
                end

                kStateReadAct: begin
                    // Snapshots the addressed level's old quantity that port_a_rdata now holds.
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
                        // Handles the CONSUME branch.
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
                    // The write commits this cycle and the priority encoder catches up to the
                    // updated level_valid mirror, so best_price_index and port_b_rdata reflect
                    // the post-command state by the time response_valid is observed externally.
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
