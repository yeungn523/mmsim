/**
 * @file
 *
 * @brief Provides a direct-mapped register-array order book for one side (bid or ask) of a limit
 * order book.
 *
 * Each price maps directly to its own storage slot (index = price), eliminating the linear scan
 * and shift operations of the previous sorted-array design. A per-price FIFO preserves time
 * priority among orders at the same level. The best price is resolved combinationally by a
 * priority encoder over the occupancy bitmap: highest occupied index for bids, lowest for asks.
 * Prices are represented as unsigned integer ticks; prices outside [0, kPriceRange) are rejected
 * on insert using the same response path as a store-full rejection.
 */

`timescale 1ns/1ps

module price_level_store #(
    parameter kDepth         = 16,    ///< Provides a depth parameter exposed for interface parity with the parent module.
    parameter kMaxOrders     = 256,   ///< Stores the maximum number of individual orders.
    parameter kPriceWidth    = 32,    ///< Stores the bit width of the price field (unsigned ticks).
    parameter kQuantityWidth = 16,    ///< Stores the bit width of the quantity field.
    parameter kOrderIdWidth  = 16,    ///< Stores the bit width of the order identifier field.
    parameter kIsBid         = 1,     ///< Determines whether this store holds bids (1) or asks (0).
    parameter kPriceRange    = 2048   ///< Stores the number of addressable price ticks (direct-mapped depth).
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Command interface (valid/ready handshake)
    input  wire [2:0]                  command,            ///< Specifies the operation to perform.
    input  wire [kPriceWidth-1:0]      command_price,      ///< Provides the order's limit price.
    input  wire [kQuantityWidth-1:0]   command_quantity,   ///< Provides the order's share count.
    input  wire [kOrderIdWidth-1:0]    command_order_id,   ///< Provides the order's unique identifier.
    input  wire                        command_valid,      ///< Asserts when a new command is ready.
    output reg                         command_ready,      ///< Asserts when the store can accept a command.

    // Response interface
    output reg  [kOrderIdWidth-1:0]    response_order_id,  ///< Reports the affected order's identifier.
    output reg  [kQuantityWidth-1:0]   response_quantity,  ///< Reports the actual quantity consumed or cancelled.
    output reg                         response_valid,     ///< Pulses high for one cycle when the response is ready.
    output reg                         response_found,     ///< Determines whether the target order was found (cancel).

    // Top-of-book interface (combinational, always available)
    output wire [kPriceWidth-1:0]      best_price,         ///< Provides the best (top) price level.
    output wire [kQuantityWidth-1:0]   best_quantity,      ///< Provides the aggregate quantity at the best price.
    output wire                        best_valid,         ///< Determines whether at least one price level exists.

    // Status
    output wire                        full                ///< Determines whether the order store is at capacity.
);

    /// Specifies a no-operation command.
    localparam kCommandNop     = 3'd0;
    /// Specifies an order insertion command.
    localparam kCommandInsert  = 3'd1;
    /// Specifies a quantity consumption command from the best price level.
    localparam kCommandConsume = 3'd2;
    /// Specifies an order cancellation command by order identifier.
    localparam kCommandCancel  = 3'd3;

    /// Stores the bit width required to address the order store.
    localparam kPointerWidth    = $clog2(kMaxOrders);
    /// Stores the bit width required to index the direct-mapped price array.
    localparam kPriceIndexWidth = $clog2(kPriceRange);
    /// Stores the bit width required to count active price levels (level_count saturates at
    /// kPriceRange, bounded in practice by kMaxOrders).
    localparam kLevelCountWidth = $clog2(kPriceRange + 1);
    /// Stores the highest valid price index (kPriceRange - 1).
    localparam kMaxPriceIndex   = kPriceRange - 1;

    // Direct-mapped price level arrays where the array index itself encodes the price.
    (* ramstyle = "M10K" *) reg [kQuantityWidth-1:0] level_quantity     [0:kPriceRange-1];  ///< Stores the aggregate quantity at each price.
    (* ramstyle = "M10K" *) reg [kPointerWidth-1:0]  level_head_pointer [0:kPriceRange-1];  ///< Stores the FIFO head pointer at each price.
    (* ramstyle = "M10K" *) reg [kPointerWidth-1:0]  level_tail_pointer [0:kPriceRange-1];  ///< Stores the FIFO tail pointer at each price.
    reg                                              level_valid        [0:kPriceRange-1];  ///< Determines whether each price index holds orders.
    reg [kLevelCountWidth-1:0]  level_count;                           ///< Tracks the number of active price levels.

    // Order store (linked-list nodes). Each array is indexed by the order slot so that reading
    // index N across all five buffers reconstructs every metric of that trade.
    (* ramstyle = "M10K" *) reg [kOrderIdWidth-1:0]   order_id       [0:kMaxOrders-1];  ///< Stores the unique identifier for each order.
    (* ramstyle = "M10K" *) reg [kQuantityWidth-1:0]  order_quantity [0:kMaxOrders-1];  ///< Stores the share count for each order.
    (* ramstyle = "M10K" *) reg [kPriceIndexWidth-1:0] order_price   [0:kMaxOrders-1];  ///< Stores the price index for each order.
    (* ramstyle = "M10K" *) reg [kPointerWidth-1:0]   order_next     [0:kMaxOrders-1];  ///< Stores the next-node pointer for FIFO traversal.
    reg                                               order_valid    [0:kMaxOrders-1];  ///< Determines whether each order slot is occupied (kept in flops for broadcast-clear on reset).

    // Free-list stack (tracks available order store slots).
    reg [kPointerWidth-1:0]  free_stack [0:kMaxOrders-1];  ///< Stores the indices of unoccupied order slots.
    reg [kPointerWidth:0]    free_pointer;                 ///< Points to the top of the free-list stack.

    // Initializes the M10K-backed arrays at power-up so simulation sees defined values and
    // synthesis emits the zero-filled memory-initialization image that Cyclone V supports.
    integer init_iterator;
    initial begin
        for (init_iterator = 0; init_iterator < kPriceRange; init_iterator = init_iterator + 1) begin
            level_quantity[init_iterator]     = {kQuantityWidth{1'b0}};
            level_head_pointer[init_iterator] = {kPointerWidth{1'b0}};
            level_tail_pointer[init_iterator] = {kPointerWidth{1'b0}};
        end
        for (init_iterator = 0; init_iterator < kMaxOrders; init_iterator = init_iterator + 1) begin
            order_id[init_iterator]       = {kOrderIdWidth{1'b0}};
            order_quantity[init_iterator] = {kQuantityWidth{1'b0}};
            order_price[init_iterator]    = {kPriceIndexWidth{1'b0}};
            order_next[init_iterator]     = {kPointerWidth{1'b0}};
        end
    end

    // Resolves best_price_index through a two-stage pipelined priority encoder over level_valid[].
    localparam kGroupSize        = (kPriceRange >= 64) ? 64 : kPriceRange;      ///< Stores the number of price slots per stage-1 group.
    localparam kGroupCount       = (kPriceRange + kGroupSize - 1) / kGroupSize; ///< Stores the number of stage-1 groups covering kPriceRange.
    localparam kGroupIndexWidth  = (kGroupSize  > 1) ? $clog2(kGroupSize)  : 1; ///< Stores the bit width of a within-group index.
    localparam kGroupSelectWidth = (kGroupCount > 1) ? $clog2(kGroupCount) : 1; ///< Stores the bit width of the group-select index.

    // Computes the per-group best index and occupancy flag combinationally from level_valid[].
    reg [kGroupIndexWidth-1:0] group_best_index_comb [0:kGroupCount-1];  ///< Stores the per-group best-index combinational output.
    reg [kGroupCount-1:0]      group_nonempty_comb;                      ///< Stores the per-group occupancy combinational bitmap.
    integer                    group_iterator;                           ///< Iterates over groups during stage-1 and stage-1-register passes.
    integer                    slot_iterator;                            ///< Iterates over slots within a group during stage-1 encoding.

    always @(*) begin : stage1_compute
        for (group_iterator = 0; group_iterator < kGroupCount; group_iterator = group_iterator + 1) begin
            group_best_index_comb[group_iterator] = {kGroupIndexWidth{1'b0}};
            group_nonempty_comb[group_iterator]   = 1'b0;
            if (kIsBid) begin
                for (slot_iterator = 0; slot_iterator < kGroupSize; slot_iterator = slot_iterator + 1) begin
                    if (level_valid[group_iterator * kGroupSize + slot_iterator]) begin
                        group_best_index_comb[group_iterator] = slot_iterator[kGroupIndexWidth-1:0];
                        group_nonempty_comb[group_iterator]   = 1'b1;
                    end
                end
            end else begin
                for (slot_iterator = kGroupSize - 1; slot_iterator >= 0; slot_iterator = slot_iterator - 1) begin
                    if (level_valid[group_iterator * kGroupSize + slot_iterator]) begin
                        group_best_index_comb[group_iterator] = slot_iterator[kGroupIndexWidth-1:0];
                        group_nonempty_comb[group_iterator]   = 1'b1;
                    end
                end
            end
        end
    end

    // Latches the stage-1 combinational outputs to shorten the critical path into stage 2.
    reg [kGroupIndexWidth-1:0] group_best_index_reg [0:kGroupCount-1];  ///< Stores the registered per-group best index.
    reg [kGroupCount-1:0]      group_nonempty_reg;                      ///< Stores the registered per-group occupancy bitmap.

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

    // Selects the winning group from the registered occupancy bitmap.
    reg [kGroupSelectWidth-1:0] winning_group;            ///< Stores the stage-2 winning-group index.
    integer                     group_select_iterator;   ///< Iterates over groups during stage-2 selection.

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

    wire [kPriceIndexWidth-1:0] best_price_index;  ///< Provides the pipelined best-price index.

    generate
        if (kGroupCount > 1) begin : hier_assemble
            assign best_price_index = {winning_group, group_best_index_reg[winning_group]};
        end else begin : flat_assemble
            assign best_price_index = group_best_index_reg[0][kPriceIndexWidth-1:0];
        end
    endgenerate

    assign best_price    = {{(kPriceWidth - kPriceIndexWidth){1'b0}}, best_price_index};
    assign best_quantity = level_quantity_b_rdata;
    assign best_valid    = (level_count != 0);
    assign full          = (free_pointer == 0);

    // M10K ports for the price-indexed arrays. level_quantity uses TDP so port B can
    // keep reading best_price_index continuously while port A serves the FSM's RMW.
    reg [kPriceIndexWidth-1:0] level_quantity_a_addr;
    reg [kQuantityWidth-1:0]   level_quantity_a_wdata;
    reg                        level_quantity_a_we;
    reg [kQuantityWidth-1:0]   level_quantity_a_rdata;
    reg [kQuantityWidth-1:0]   level_quantity_b_rdata;

    reg [kPriceIndexWidth-1:0] level_head_pointer_raddr;
    reg [kPriceIndexWidth-1:0] level_head_pointer_waddr;
    reg [kPointerWidth-1:0]    level_head_pointer_wdata;
    reg                        level_head_pointer_we;
    reg [kPointerWidth-1:0]    level_head_pointer_rdata;

    reg [kPriceIndexWidth-1:0] level_tail_pointer_raddr;
    reg [kPriceIndexWidth-1:0] level_tail_pointer_waddr;
    reg [kPointerWidth-1:0]    level_tail_pointer_wdata;
    reg                        level_tail_pointer_we;
    reg [kPointerWidth-1:0]    level_tail_pointer_rdata;

    always @(posedge clk) begin : level_quantity_port_a
        if (level_quantity_a_we) level_quantity[level_quantity_a_addr] <= level_quantity_a_wdata;
        level_quantity_a_rdata <= level_quantity[level_quantity_a_addr];
    end

    always @(posedge clk) begin : level_quantity_port_b
        level_quantity_b_rdata <= level_quantity[best_price_index];
    end

    always @(posedge clk) begin : level_head_pointer_port
        if (level_head_pointer_we) level_head_pointer[level_head_pointer_waddr] <= level_head_pointer_wdata;
        level_head_pointer_rdata <= level_head_pointer[level_head_pointer_raddr];
    end

    always @(posedge clk) begin : level_tail_pointer_port
        if (level_tail_pointer_we) level_tail_pointer[level_tail_pointer_waddr] <= level_tail_pointer_wdata;
        level_tail_pointer_rdata <= level_tail_pointer[level_tail_pointer_raddr];
    end

    // M10K ports for the order-indexed arrays.
    reg [kPointerWidth-1:0]    order_id_raddr;
    reg [kPointerWidth-1:0]    order_id_waddr;
    reg [kOrderIdWidth-1:0]    order_id_wdata;
    reg                        order_id_we;
    reg [kOrderIdWidth-1:0]    order_id_rdata;

    reg [kPointerWidth-1:0]    order_quantity_raddr;
    reg [kPointerWidth-1:0]    order_quantity_waddr;
    reg [kQuantityWidth-1:0]   order_quantity_wdata;
    reg                        order_quantity_we;
    reg [kQuantityWidth-1:0]   order_quantity_rdata;

    reg [kPointerWidth-1:0]    order_next_raddr;
    reg [kPointerWidth-1:0]    order_next_waddr;
    reg [kPointerWidth-1:0]    order_next_wdata;
    reg                        order_next_we;
    reg [kPointerWidth-1:0]    order_next_rdata;

    reg [kPointerWidth-1:0]    order_price_waddr;
    reg [kPriceIndexWidth-1:0] order_price_wdata;
    reg                        order_price_we;

    always @(posedge clk) begin : order_id_port
        if (order_id_we) order_id[order_id_waddr] <= order_id_wdata;
        order_id_rdata <= order_id[order_id_raddr];
    end

    always @(posedge clk) begin : order_quantity_port
        if (order_quantity_we) order_quantity[order_quantity_waddr] <= order_quantity_wdata;
        order_quantity_rdata <= order_quantity[order_quantity_raddr];
    end

    always @(posedge clk) begin : order_next_port
        if (order_next_we) order_next[order_next_waddr] <= order_next_wdata;
        order_next_rdata <= order_next[order_next_raddr];
    end

    always @(posedge clk) begin : order_price_port
        if (order_price_we) order_price[order_price_waddr] <= order_price_wdata;
    end

    // Top-level FSM dispatches each command to its sub-FSM and collects completions.
    localparam kTopIdle         = 3'd0;  ///< Waits for a new command.
    localparam kTopInsertBusy   = 3'd1;  ///< Insert sub-FSM is active.
    localparam kTopConsumeBusy  = 3'd2;  ///< Consume sub-FSM is active.
    localparam kTopCancelBusy   = 3'd3;  ///< Cancel sub-FSM is active.
    localparam kTopSettle       = 3'd4;  ///< Waits one cycle for the encoder, then pulses response_valid.
    localparam kTopDone         = 3'd5;  ///< Reasserts command_ready and returns to idle.

    // Insert sub-FSM: fetch level reads, wait, execute.
    localparam kInsertFetch     = 2'd0;
    localparam kInsertWait      = 2'd1;
    localparam kInsertExec      = 2'd2;

    // Consume sub-FSM: fetch level, wait, fetch order, wait, execute, rescan after empty.
    localparam kConsumeFetchLevel = 3'd0;
    localparam kConsumeWaitLevel  = 3'd1;
    localparam kConsumeFetchOrder = 3'd2;
    localparam kConsumeWaitOrder  = 3'd3;
    localparam kConsumeExecute    = 3'd4;
    localparam kConsumeRescan     = 3'd5;

    // Cancel sub-FSM: scan levels, fetch/walk FIFO, unlink on match, clean up freed slot.
    localparam kCancelScan            = 4'd0;
    localparam kCancelWaitHead        = 4'd1;
    localparam kCancelDispatchOrder   = 4'd2;
    localparam kCancelWaitOrder       = 4'd3;
    localparam kCancelFetchNode       = 4'd4;
    localparam kCancelWaitMatch       = 4'd5;
    localparam kCancelUnlink          = 4'd6;
    localparam kCancelCleanup         = 4'd7;

    reg [2:0] top_state;      ///< Stores the top-level FSM state.
    reg [1:0] insert_state;   ///< Stores the insert sub-FSM state.
    reg [2:0] consume_state;  ///< Stores the consume sub-FSM state.
    reg [3:0] cancel_state;   ///< Stores the cancel sub-FSM state.

    // Working registers (latched from the command interface for multi-cycle processing).
    reg [2:0]                  working_command;    ///< Latches the active command code.
    reg [kPriceWidth-1:0]      working_price;      ///< Latches the active order's price.
    reg [kQuantityWidth-1:0]   working_quantity;   ///< Latches the active order's quantity.
    reg [kOrderIdWidth-1:0]    working_order_id;   ///< Latches the active order's identifier.
    reg [kQuantityWidth-1:0]   remaining_quantity; ///< Tracks unconsumed quantity during consume.
    reg [kQuantityWidth-1:0]   consumed_so_far;    ///< Accumulates total quantity consumed across all orders touched.
    reg [kPriceIndexWidth-1:0] cancel_level_index; ///< Holds the price index being scanned for cancel.
    reg [kPointerWidth-1:0]    scan_pointer;       ///< Points to the current FIFO node during cancel.
    reg [kPointerWidth-1:0]    previous_pointer;   ///< Points to the preceding FIFO node during cancel.
    reg                        cancel_is_head;     ///< Determines whether the scanned node is the FIFO head.
    reg [kPointerWidth-1:0]    head_slot_reg;      ///< Latches the FIFO head slot across the consume pipeline.

    integer i;

    always @(posedge clk) begin : main_proc
        // Declares local variables shared across multiple states at the top of the named block.
        reg [kPointerWidth-1:0]    slot;
        reg [kPointerWidth-1:0]    head_slot_local;
        reg [kQuantityWidth-1:0]   head_order_quantity;
        reg [kQuantityWidth-1:0]   new_level_quantity;
        reg [kQuantityWidth-1:0]   cancelled_quantity;
        reg [kPriceIndexWidth-1:0] insert_index;

        if (!rst_n) begin
            top_state         <= kTopIdle;
            insert_state      <= kInsertFetch;
            consume_state     <= kConsumeFetchLevel;
            cancel_state      <= kCancelScan;
            command_ready     <= 1'b1;
            response_valid    <= 1'b0;
            response_found    <= 1'b0;
            response_order_id <= {kOrderIdWidth{1'b0}};
            response_quantity <= {kQuantityWidth{1'b0}};
            level_count       <= {kLevelCountWidth{1'b0}};
            free_pointer      <= kMaxOrders[kPointerWidth:0];
            consumed_so_far   <= {kQuantityWidth{1'b0}};
            head_slot_reg     <= {kPointerWidth{1'b0}};

            // M10K contents are not re-zeroed here; the initial block and the freed-slot
            // invariant (order_next cleared on release) cover the defined-state requirement.
            order_id_we          <= 1'b0;
            order_quantity_we    <= 1'b0;
            order_next_we        <= 1'b0;
            order_price_we       <= 1'b0;
            order_id_raddr       <= {kPointerWidth{1'b0}};
            order_quantity_raddr <= {kPointerWidth{1'b0}};
            order_next_raddr     <= {kPointerWidth{1'b0}};

            level_quantity_a_we      <= 1'b0;
            level_quantity_a_addr    <= {kPriceIndexWidth{1'b0}};
            level_head_pointer_we    <= 1'b0;
            level_head_pointer_raddr <= {kPriceIndexWidth{1'b0}};
            level_tail_pointer_we    <= 1'b0;
            level_tail_pointer_raddr <= {kPriceIndexWidth{1'b0}};

            for (i = 0; i < kPriceRange; i = i + 1) begin
                level_valid[i] <= 1'b0;
            end

            for (i = 0; i < kMaxOrders; i = i + 1) begin
                order_valid[i] <= 1'b0;
                free_stack[i]  <= i[kPointerWidth-1:0];
            end
        end else begin
            // Defaults so port writes and the response pulse stay single-cycle events.
            response_valid        <= 1'b0;
            order_id_we           <= 1'b0;
            order_quantity_we     <= 1'b0;
            order_next_we         <= 1'b0;
            order_price_we        <= 1'b0;
            level_quantity_a_we   <= 1'b0;
            level_head_pointer_we <= 1'b0;
            level_tail_pointer_we <= 1'b0;

            case (top_state)
                // Waits for a command and dispatches it to the appropriate sub-FSM.
                kTopIdle: begin
                    if (command_valid && command_ready) begin
                        working_command  <= command;
                        working_price    <= command_price;
                        working_quantity <= command_quantity;
                        working_order_id <= command_order_id;
                        command_ready    <= 1'b0;

                        case (command)
                            kCommandInsert: begin
                                insert_state <= kInsertFetch;
                                top_state    <= kTopInsertBusy;
                            end
                            kCommandConsume: begin
                                remaining_quantity <= command_quantity;
                                consumed_so_far    <= {kQuantityWidth{1'b0}};
                                consume_state      <= kConsumeFetchLevel;
                                top_state          <= kTopConsumeBusy;
                            end
                            kCommandCancel: begin
                                cancel_level_index <= {kPriceIndexWidth{1'b0}};
                                cancel_state       <= kCancelScan;
                                top_state          <= kTopCancelBusy;
                            end
                            default: command_ready <= 1'b1;
                        endcase
                    end
                end

                // Insert sub-FSM: issues level reads, waits, then performs the insert.
                kTopInsertBusy: begin
                    case (insert_state)
                        kInsertFetch: begin
                            if (working_price >= kPriceRange[kPriceWidth-1:0] || free_pointer == 0) begin
                                response_valid    <= 1'b1;
                                response_order_id <= {kOrderIdWidth{1'b0}};
                                response_quantity <= {kQuantityWidth{1'b0}};
                                response_found    <= 1'b0;
                                top_state         <= kTopDone;
                            end else begin
                                level_tail_pointer_raddr <= working_price[kPriceIndexWidth-1:0];
                                level_quantity_a_addr    <= working_price[kPriceIndexWidth-1:0];
                                insert_state             <= kInsertWait;
                            end
                        end

                        kInsertWait: begin
                            insert_state <= kInsertExec;
                        end

                        kInsertExec: begin
                            insert_index = working_price[kPriceIndexWidth-1:0];
                            slot         = free_stack[free_pointer - 1];

                            order_id_we          <= 1'b1;
                            order_id_waddr       <= slot;
                            order_id_wdata       <= working_order_id;

                            order_quantity_we    <= 1'b1;
                            order_quantity_waddr <= slot;
                            order_quantity_wdata <= working_quantity;

                            order_price_we       <= 1'b1;
                            order_price_waddr    <= slot;
                            order_price_wdata    <= insert_index;

                            order_valid[slot]    <= 1'b1;

                            if (!level_valid[insert_index]) begin
                                // Activates a new price level. order_next[slot] is already zero by
                                // the freed-slot invariant, so no port cycle is spent here.
                                level_valid[insert_index] <= 1'b1;

                                level_head_pointer_we    <= 1'b1;
                                level_head_pointer_waddr <= insert_index;
                                level_head_pointer_wdata <= slot;

                                level_tail_pointer_we    <= 1'b1;
                                level_tail_pointer_waddr <= insert_index;
                                level_tail_pointer_wdata <= slot;

                                level_quantity_a_we      <= 1'b1;
                                level_quantity_a_wdata   <= working_quantity;

                                level_count              <= level_count + 1'b1;
                            end else begin
                                // Appends to the existing FIFO tail using the registered tail.
                                order_next_we            <= 1'b1;
                                order_next_waddr         <= level_tail_pointer_rdata;
                                order_next_wdata         <= slot;

                                level_tail_pointer_we    <= 1'b1;
                                level_tail_pointer_waddr <= insert_index;
                                level_tail_pointer_wdata <= slot;

                                level_quantity_a_we      <= 1'b1;
                                level_quantity_a_wdata   <= level_quantity_a_rdata + working_quantity;
                            end

                            free_pointer      <= free_pointer - 1'b1;
                            response_quantity <= working_quantity;
                            response_order_id <= working_order_id;
                            response_found    <= 1'b1;
                            top_state         <= kTopSettle;
                        end

                        default: top_state <= kTopIdle;
                    endcase
                end

                // Consume sub-FSM: loops FetchLevel -> WaitLevel -> FetchOrder -> WaitOrder -> Execute.
                kTopConsumeBusy: begin
                    case (consume_state)
                        kConsumeFetchLevel: begin
                            if (level_count == 0 || remaining_quantity == 0) begin
                                response_valid    <= 1'b1;
                                response_quantity <= consumed_so_far;
                                response_found    <= (consumed_so_far != {kQuantityWidth{1'b0}});
                                if (consumed_so_far == {kQuantityWidth{1'b0}})
                                    response_order_id <= {kOrderIdWidth{1'b0}};
                                top_state <= kTopDone;
                            end else begin
                                level_head_pointer_raddr <= best_price_index;
                                level_quantity_a_addr    <= best_price_index;
                                consume_state            <= kConsumeWaitLevel;
                            end
                        end

                        kConsumeWaitLevel: begin
                            consume_state <= kConsumeFetchOrder;
                        end

                        kConsumeFetchOrder: begin
                            head_slot_reg        <= level_head_pointer_rdata;
                            order_id_raddr       <= level_head_pointer_rdata;
                            order_quantity_raddr <= level_head_pointer_rdata;
                            order_next_raddr     <= level_head_pointer_rdata;
                            consume_state        <= kConsumeWaitOrder;
                        end

                        kConsumeWaitOrder: begin
                            consume_state <= kConsumeExecute;
                        end

                        kConsumeExecute: begin
                            head_order_quantity = order_quantity_rdata;
                            response_order_id   <= order_id_rdata;

                            if (remaining_quantity >= head_order_quantity) begin
                                // Fully consumes the head order and frees its slot.
                                new_level_quantity = level_quantity_a_rdata - head_order_quantity;

                                level_quantity_a_we    <= 1'b1;
                                level_quantity_a_wdata <= new_level_quantity;

                                remaining_quantity <= remaining_quantity - head_order_quantity;
                                consumed_so_far    <= consumed_so_far + head_order_quantity;

                                level_head_pointer_we    <= 1'b1;
                                level_head_pointer_waddr <= best_price_index;
                                level_head_pointer_wdata <= order_next_rdata;

                                order_valid[head_slot_reg] <= 1'b0;
                                free_stack[free_pointer]   <= head_slot_reg;
                                free_pointer               <= free_pointer + 1'b1;

                                // Preserves the freed-slot invariant.
                                order_next_we    <= 1'b1;
                                order_next_waddr <= head_slot_reg;
                                order_next_wdata <= {kPointerWidth{1'b0}};

                                if (new_level_quantity == 0) begin
                                    level_valid[best_price_index] <= 1'b0;
                                    level_count                   <= level_count - 1'b1;
                                    consume_state                 <= kConsumeRescan;
                                end else begin
                                    consume_state <= kConsumeFetchLevel;
                                end
                            end else begin
                                // Partial fill; FetchLevel terminates on the next iteration.
                                order_quantity_we    <= 1'b1;
                                order_quantity_waddr <= head_slot_reg;
                                order_quantity_wdata <= head_order_quantity - remaining_quantity;

                                level_quantity_a_we    <= 1'b1;
                                level_quantity_a_wdata <= level_quantity_a_rdata - remaining_quantity;

                                consumed_so_far    <= consumed_so_far + remaining_quantity;
                                remaining_quantity <= {kQuantityWidth{1'b0}};
                                consume_state      <= kConsumeFetchLevel;
                            end
                        end

                        // Stalls one cycle for the priority encoder to settle after a level empties.
                        kConsumeRescan: begin
                            consume_state <= kConsumeFetchLevel;
                        end

                        default: top_state <= kTopIdle;
                    endcase
                end

                // Cancel sub-FSM: scans levels, walks FIFOs, and unlinks on match.
                kTopCancelBusy: begin
                    case (cancel_state)
                        kCancelScan: begin
                            if (level_count == 0) begin
                                response_valid    <= 1'b1;
                                response_order_id <= working_order_id;
                                response_quantity <= {kQuantityWidth{1'b0}};
                                response_found    <= 1'b0;
                                top_state         <= kTopDone;
                            end else if (level_valid[cancel_level_index]) begin
                                level_head_pointer_raddr <= cancel_level_index;
                                cancel_state             <= kCancelWaitHead;
                            end else if (cancel_level_index == kMaxPriceIndex[kPriceIndexWidth-1:0]) begin
                                response_valid    <= 1'b1;
                                response_order_id <= working_order_id;
                                response_quantity <= {kQuantityWidth{1'b0}};
                                response_found    <= 1'b0;
                                top_state         <= kTopDone;
                            end else begin
                                cancel_level_index <= cancel_level_index + 1'b1;
                            end
                        end

                        kCancelWaitHead: begin
                            cancel_state <= kCancelDispatchOrder;
                        end

                        kCancelDispatchOrder: begin
                            scan_pointer         <= level_head_pointer_rdata;
                            order_id_raddr       <= level_head_pointer_rdata;
                            order_quantity_raddr <= level_head_pointer_rdata;
                            order_next_raddr     <= level_head_pointer_rdata;
                            previous_pointer     <= {kPointerWidth{1'b1}};
                            cancel_is_head       <= 1'b1;
                            cancel_state         <= kCancelWaitOrder;
                        end

                        kCancelWaitOrder: begin
                            cancel_state <= kCancelFetchNode;
                        end

                        kCancelFetchNode: begin
                            if (!order_valid[scan_pointer]) begin
                                if (cancel_level_index == kMaxPriceIndex[kPriceIndexWidth-1:0]) begin
                                    response_valid    <= 1'b1;
                                    response_order_id <= working_order_id;
                                    response_quantity <= {kQuantityWidth{1'b0}};
                                    response_found    <= 1'b0;
                                    top_state         <= kTopDone;
                                end else begin
                                    cancel_level_index <= cancel_level_index + 1'b1;
                                    cancel_state       <= kCancelScan;
                                end
                            end else if (order_id_rdata == working_order_id) begin
                                // Match: fetch level reads needed for the unlink writes.
                                level_tail_pointer_raddr <= cancel_level_index;
                                level_quantity_a_addr    <= cancel_level_index;
                                cancel_state             <= kCancelWaitMatch;
                            end else begin
                                // Hop to the next FIFO node and reissue the order reads.
                                previous_pointer     <= scan_pointer;
                                scan_pointer         <= order_next_rdata;
                                order_id_raddr       <= order_next_rdata;
                                order_quantity_raddr <= order_next_rdata;
                                order_next_raddr     <= order_next_rdata;
                                cancel_is_head       <= 1'b0;
                                cancel_state         <= kCancelWaitOrder;
                            end
                        end

                        kCancelWaitMatch: begin
                            cancel_state <= kCancelUnlink;
                        end

                        kCancelUnlink: begin
                            cancelled_quantity = order_quantity_rdata;

                            if (cancel_is_head) begin
                                level_head_pointer_we    <= 1'b1;
                                level_head_pointer_waddr <= cancel_level_index;
                                level_head_pointer_wdata <= order_next_rdata;
                            end else begin
                                order_next_we    <= 1'b1;
                                order_next_waddr <= previous_pointer;
                                order_next_wdata <= order_next_rdata;
                            end

                            if (level_tail_pointer_rdata == scan_pointer) begin
                                level_tail_pointer_we    <= 1'b1;
                                level_tail_pointer_waddr <= cancel_level_index;
                                if (cancel_is_head)
                                    level_tail_pointer_wdata <= order_next_rdata;
                                else
                                    level_tail_pointer_wdata <= previous_pointer;
                            end

                            order_valid[scan_pointer] <= 1'b0;
                            free_stack[free_pointer]  <= scan_pointer;
                            free_pointer              <= free_pointer + 1'b1;

                            level_quantity_a_we    <= 1'b1;
                            level_quantity_a_wdata <= level_quantity_a_rdata - cancelled_quantity;

                            if (level_quantity_a_rdata == cancelled_quantity) begin
                                level_valid[cancel_level_index] <= 1'b0;
                                level_count                     <= level_count - 1'b1;
                            end

                            response_order_id <= working_order_id;
                            response_quantity <= cancelled_quantity;
                            response_found    <= 1'b1;
                            cancel_state      <= kCancelCleanup;
                        end

                        kCancelCleanup: begin
                            order_next_we    <= 1'b1;
                            order_next_waddr <= scan_pointer;
                            order_next_wdata <= {kPointerWidth{1'b0}};
                            top_state        <= kTopSettle;
                        end

                        default: top_state <= kTopIdle;
                    endcase
                end

                // Stalls one cycle for the priority encoder, then pulses response_valid.
                kTopSettle: begin
                    response_valid <= 1'b1;
                    top_state      <= kTopDone;
                end

                // Reasserts command_ready and returns to idle for the next command.
                kTopDone: begin
                    command_ready <= 1'b1;
                    top_state     <= kTopIdle;
                end

                default: top_state <= kTopIdle;
            endcase
        end
    end

endmodule
