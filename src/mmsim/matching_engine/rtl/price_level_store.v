/**
 * @file
 *
 * @brief Provides a sorted register-array order book for one side (bid or ask) of a limit order
 * book.
 *
 * Each price level stores an aggregate quantity and a linked-list FIFO of individual orders.
 * Index 0 always holds the best price. The kIsBid parameter controls sort direction: descending
 * for bids (highest price at index 0) or ascending for asks (lowest price at index 0). Prices
 * are represented as unsigned integer ticks.
 */

`timescale 1ns/1ps

module price_level_store #(
    parameter kDepth     = 16,  ///< Maximum number of distinct price levels.
    parameter kMaxOrders = 64,  ///< Maximum number of individual orders stored.
    parameter kPriceWidth    = 32,  ///< Bit width of the price field (unsigned ticks).
    parameter kQuantityWidth = 16,  ///< Bit width of the quantity field.
    parameter kOrderIdWidth  = 16,  ///< Bit width of the order identifier field.
    parameter kIsBid         = 1    ///< Determines whether this store holds bids (1) or asks (0).
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Command interface (valid/ready handshake)
    input  wire [2:0]                  command,            ///< Specifies the operation to perform.
    input  wire [kPriceWidth-1:0]      command_price,      ///< Provides the order's limit price.
    input  wire [kQuantityWidth-1:0]   command_quantity,    ///< Provides the order's share count.
    input  wire [kOrderIdWidth-1:0]    command_order_id,    ///< Provides the order's unique identifier.
    input  wire                        command_valid,       ///< Asserts when a new command is ready.
    output reg                         command_ready,       ///< Asserts when the store can accept a command.

    // Response interface
    output reg  [kOrderIdWidth-1:0]    response_order_id,   ///< Reports the affected order's identifier.
    output reg  [kQuantityWidth-1:0]   response_quantity,    ///< Reports the actual quantity consumed or cancelled.
    output reg                         response_valid,       ///< Pulses high for one cycle when the response is ready.
    output reg                         response_found,       ///< Determines whether the target order was found (cancel).

    // Top-of-book interface (combinational, always available)
    output wire [kPriceWidth-1:0]      best_price,           ///< Provides the best (top) price level.
    output wire [kQuantityWidth-1:0]   best_quantity,         ///< Provides the aggregate quantity at the best price.
    output wire                        best_valid,            ///< Determines whether at least one price level exists.

    // Status
    output wire                        full                   ///< Determines whether the order store is at capacity.
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
    localparam kPointerWidth = $clog2(kMaxOrders);
    /// Stores the bit width required to index the price level array.
    localparam kDepthWidth   = $clog2(kDepth);

    // Price level array (sorted, index 0 holds the best price)
    reg [kPriceWidth-1:0]    level_price       [0:kDepth-1];  ///< Stores the tick price for each level.
    reg [kQuantityWidth-1:0] level_quantity     [0:kDepth-1];  ///< Stores the aggregate quantity for each level.
    reg [kPointerWidth-1:0]  level_head_pointer [0:kDepth-1];  ///< Stores the FIFO head pointer for each level.
    reg [kPointerWidth-1:0]  level_tail_pointer [0:kDepth-1];  ///< Stores the FIFO tail pointer for each level.
    reg                      level_valid        [0:kDepth-1];  ///< Determines whether each level is active.
    reg [kDepthWidth:0]      level_count;                      ///< Tracks the number of active price levels.

    // Order store (linked-list nodes)
    reg [kOrderIdWidth-1:0]  order_id    [0:kMaxOrders-1];  ///< Stores the unique identifier for each order.
    reg [kQuantityWidth-1:0] order_quantity [0:kMaxOrders-1];  ///< Stores the share count for each order.
    reg [kPointerWidth-1:0]  order_next  [0:kMaxOrders-1];  ///< Stores the next-node pointer for FIFO traversal.
    reg                      order_valid [0:kMaxOrders-1];  ///< Determines whether each order slot is occupied.

    // Free-list stack (tracks available order store slots)
    reg [kPointerWidth-1:0]  free_stack   [0:kMaxOrders-1];  ///< Stores the indices of unoccupied order slots.
    reg [kPointerWidth:0]    free_pointer;                    ///< Points to the top of the free-list stack.

    // Top-of-book combinational outputs
    assign best_price    = level_price[0];
    assign best_quantity = level_quantity[0];
    assign best_valid    = (level_count != 0);
    assign full          = (free_pointer == 0);

    // FSM state encoding
    localparam kStateIdle         = 4'd0;  ///< Waits for a new command.
    localparam kStateFindLevel    = 4'd1;  ///< Searches for the target price level during insertion.
    localparam kStateShiftInsert  = 4'd2;  ///< Shifts levels to create space for a new price level.
    localparam kStateUpdateFifo   = 4'd3;  ///< Appends the new order to the target level's FIFO.
    localparam kStateConsumePop   = 4'd4;  ///< Pops orders from the best level's FIFO head.
    localparam kStateConsumeShift = 4'd5;  ///< Removes an empty level and shifts remaining levels up.
    localparam kStateCancelScan   = 4'd6;  ///< Iterates through levels to locate the target order.
    localparam kStateCancelUnlink = 4'd7;  ///< Traverses a level's FIFO to unlink the cancelled order.
    localparam kStateDone         = 4'd8;  ///< Signals command completion and returns to idle.

    reg [3:0] state;

    // Working registers (latched from the command interface for multi-cycle processing)
    reg [2:0]                  working_command;          ///< Latches the active command code.
    reg [kPriceWidth-1:0]      working_price;            ///< Latches the active order's price.
    reg [kQuantityWidth-1:0]   working_quantity;          ///< Latches the active order's quantity.
    reg [kOrderIdWidth-1:0]    working_order_id;          ///< Latches the active order's identifier.
    reg [kDepthWidth:0]        insert_position;           ///< Holds the computed insertion index for a new level.
    reg                        level_found;               ///< Determines whether an existing level matches the price.
    reg [kDepthWidth:0]        level_index;               ///< Holds the index of the matched or target level.
    reg [kQuantityWidth-1:0]   remaining_quantity;         ///< Tracks unconsumed quantity during a consume operation.
    reg [kPointerWidth-1:0]    scan_pointer;              ///< Points to the current node during cancel FIFO traversal.
    reg [kPointerWidth-1:0]    previous_pointer;           ///< Points to the preceding node during cancel traversal.
    reg [kDepthWidth:0]        cancel_level_index;         ///< Holds the level index being scanned for cancellation.
    reg                        cancel_is_head;             ///< Determines whether the scanned node is the FIFO head.

    /**
     * @brief Compares two prices and determines whether the first is more competitive.
     *
     * For bids (kIsBid=1), a higher price is more competitive. For asks (kIsBid=0), a lower
     * price is more competitive.
     */
    function is_better_price;
        input [kPriceWidth-1:0] price_a;
        input [kPriceWidth-1:0] price_b;
        begin
            if (kIsBid)
                is_better_price = (price_a > price_b);
            else
                is_better_price = (price_a < price_b);
        end
    endfunction

    integer i;

    always @(posedge clk or negedge rst_n) begin : main_proc
        // Local variables used across multiple states (declared once at top of named block).
        integer                  k;
        reg                      found_local;
        reg [kDepthWidth:0]      insert_local;
        reg [kDepthWidth:0]      match_local;
        reg [kPointerWidth-1:0]  slot;
        reg [kPointerWidth-1:0]  head_slot;
        reg [kQuantityWidth-1:0] head_order_quantity;
        reg [kQuantityWidth-1:0] cancelled_quantity;
        reg [kQuantityWidth-1:0] new_level_quantity;

        if (!rst_n) begin
            state            <= kStateIdle;
            command_ready    <= 1'b1;
            response_valid   <= 1'b0;
            response_found   <= 1'b0;
            response_order_id <= {kOrderIdWidth{1'b0}};
            response_quantity <= {kQuantityWidth{1'b0}};
            level_count      <= 0;
            free_pointer     <= kMaxOrders[kPointerWidth:0];

            for (i = 0; i < kDepth; i = i + 1) begin
                level_valid[i]        <= 1'b0;
                level_price[i]        <= {kPriceWidth{1'b0}};
                level_quantity[i]     <= {kQuantityWidth{1'b0}};
                level_head_pointer[i] <= {kPointerWidth{1'b0}};
                level_tail_pointer[i] <= {kPointerWidth{1'b0}};
            end

            for (i = 0; i < kMaxOrders; i = i + 1) begin
                order_valid[i]    <= 1'b0;
                order_id[i]       <= {kOrderIdWidth{1'b0}};
                order_quantity[i] <= {kQuantityWidth{1'b0}};
                order_next[i]     <= {kPointerWidth{1'b0}};
                free_stack[i]     <= i[kPointerWidth-1:0];
            end
        end else begin
            // Deasserts response_valid after each pulse
            response_valid <= 1'b0;

            case (state)
                kStateIdle: begin
                    if (command_valid && command_ready) begin
                        working_command  <= command;
                        working_price    <= command_price;
                        working_quantity <= command_quantity;
                        working_order_id <= command_order_id;
                        command_ready    <= 1'b0;

                        case (command)
                            kCommandInsert: state <= kStateFindLevel;
                            kCommandConsume: begin
                                remaining_quantity <= command_quantity;
                                state              <= kStateConsumePop;
                            end
                            kCommandCancel: begin
                                cancel_level_index <= 0;
                                state              <= kStateCancelScan;
                            end
                            default: command_ready <= 1'b1;
                        endcase
                    end
                end

                // Searches for an existing price level or determines the insertion position
                kStateFindLevel: begin
                    // Uses blocking assignments to local variables so each loop iteration
                    // sees the updated state from the previous iteration.
                    found_local  = 1'b0;
                    insert_local = level_count;
                    match_local  = 0;

                    // Scans for an exact price match
                    for (k = 0; k < kDepth; k = k + 1) begin
                        if (k[kDepthWidth:0] < level_count) begin
                            if (level_price[k] == working_price && !found_local) begin
                                found_local = 1'b1;
                                match_local = k[kDepthWidth:0];
                            end
                        end
                    end

                    // Identifies the first level with a less competitive price for insertion
                    if (!found_local) begin
                        for (k = 0; k < kDepth; k = k + 1) begin
                            if (k[kDepthWidth:0] < level_count) begin
                                if (is_better_price(working_price, level_price[k])
                                    && insert_local == level_count) begin
                                    insert_local = k[kDepthWidth:0];
                                end
                            end
                        end
                    end

                    level_found     <= found_local;
                    insert_position <= insert_local;
                    level_index     <= match_local;

                    if (free_pointer == 0) begin
                        // Rejects the insertion when no free order slots remain
                        response_valid    <= 1'b1;
                        response_quantity <= {kQuantityWidth{1'b0}};
                        response_found    <= 1'b0;
                        state             <= kStateDone;
                    end else begin
                        state <= kStateShiftInsert;
                    end
                end

                kStateShiftInsert: begin
                    if (level_found) begin
                        // Proceeds directly to FIFO update when the price level already exists
                        state <= kStateUpdateFifo;
                    end else if (level_count < kDepth[kDepthWidth:0]) begin
                        // Shifts existing levels downward to make room for the new price level
                        for (k = kDepth - 1; k > 0; k = k - 1) begin
                            if (k[kDepthWidth:0] > insert_position && k[kDepthWidth:0] <= level_count) begin
                                level_price[k]        <= level_price[k-1];
                                level_quantity[k]     <= level_quantity[k-1];
                                level_head_pointer[k] <= level_head_pointer[k-1];
                                level_tail_pointer[k] <= level_tail_pointer[k-1];
                                level_valid[k]        <= level_valid[k-1];
                            end
                        end

                        // Initializes the newly created price level
                        level_price[insert_position]        <= working_price;
                        level_quantity[insert_position]     <= {kQuantityWidth{1'b0}};
                        level_head_pointer[insert_position] <= {kPointerWidth{1'b0}};
                        level_tail_pointer[insert_position] <= {kPointerWidth{1'b0}};
                        level_valid[insert_position]        <= 1'b1;
                        level_count                         <= level_count + 1;

                        level_index <= insert_position;
                        state       <= kStateUpdateFifo;
                    end else begin
                        // Rejects the insertion when all price level slots are occupied
                        response_valid    <= 1'b1;
                        response_quantity <= {kQuantityWidth{1'b0}};
                        response_found    <= 1'b0;
                        state             <= kStateDone;
                    end
                end

                kStateUpdateFifo: begin
                    // Allocates a free slot and appends the order to the target level's FIFO.
                    // Uses a blocking-assigned local 'slot' so the index is stable in this cycle.
                    slot = free_stack[free_pointer - 1];

                    order_id[slot]       <= working_order_id;
                    order_quantity[slot]  <= working_quantity;
                    order_next[slot]     <= {kPointerWidth{1'b0}};
                    order_valid[slot]    <= 1'b1;

                    if (level_quantity[level_index] == 0) begin
                        // Sets the head pointer when this is the first order at the level
                        level_head_pointer[level_index] <= slot;
                    end else begin
                        // Links the previous tail node to the newly allocated slot
                        order_next[level_tail_pointer[level_index]] <= slot;
                    end
                    level_tail_pointer[level_index] <= slot;

                    level_quantity[level_index] <= level_quantity[level_index] + working_quantity;

                    free_pointer <= free_pointer - 1;

                    response_valid     <= 1'b1;
                    response_quantity  <= working_quantity;
                    response_order_id  <= working_order_id;
                    response_found     <= 1'b1;
                    state              <= kStateDone;
                end

            // Removes quantity from the best price level by popping orders from the FIFO head
                kStateConsumePop: begin
                    if (level_count == 0 || remaining_quantity == 0) begin
                        // Reports the total consumed quantity when no more can be removed. Preserves response_order_id 
                        // from the last fill iteration; only zeroes it when the book was empty.
                        response_valid    <= 1'b1;
                        response_quantity <= working_quantity - remaining_quantity;
                        response_found    <= (remaining_quantity != working_quantity);
                        if (remaining_quantity == working_quantity)
                            response_order_id <= {kOrderIdWidth{1'b0}};
                        state             <= kStateDone;
                    end else begin
                        head_slot           = level_head_pointer[0];
                        head_order_quantity = order_quantity[head_slot];

                        response_order_id <= order_id[head_slot];

                        if (remaining_quantity >= head_order_quantity) begin
                            // Fully consumes the head order and frees its slot
                            new_level_quantity = level_quantity[0] - head_order_quantity;

                            level_quantity[0]  <= new_level_quantity;
                            remaining_quantity <= remaining_quantity - head_order_quantity;
                            response_quantity  <= head_order_quantity;

                            level_head_pointer[0]            <= order_next[head_slot];
                            order_valid[head_slot]           <= 1'b0;
                            free_stack[free_pointer]         <= head_slot;
                            free_pointer                     <= free_pointer + 1;

                            if (new_level_quantity == 0) begin
                                // Transitions to level removal when the level becomes empty
                                state <= kStateConsumeShift;
                            end else begin
                                // Emits a fill response and continues consuming from the next order
                                response_valid <= 1'b1;
                                state          <= kStateConsumePop;
                            end
                        end else begin
                            // Partially fills the head order and completes the consume operation
                            order_quantity[head_slot] <= head_order_quantity - remaining_quantity;
                            level_quantity[0]         <= level_quantity[0] - remaining_quantity;
                            response_quantity         <= remaining_quantity;
                            remaining_quantity        <= 0;

                            response_valid <= 1'b1;
                            response_found <= 1'b1;
                            state          <= kStateDone;
                        end
                    end
                end

                kStateConsumeShift: begin
                    // Removes the empty level at index 0 and shifts all remaining levels upward
                    for (k = 0; k < kDepth - 1; k = k + 1) begin
                        if (k[kDepthWidth:0] < level_count - 1) begin
                            level_price[k]        <= level_price[k+1];
                            level_quantity[k]     <= level_quantity[k+1];
                            level_head_pointer[k] <= level_head_pointer[k+1];
                            level_tail_pointer[k] <= level_tail_pointer[k+1];
                            level_valid[k]        <= level_valid[k+1];
                        end
                    end

                    if (level_count > 0) begin
                        level_valid[level_count - 1]    <= 1'b0;
                        level_quantity[level_count - 1] <= {kQuantityWidth{1'b0}};
                    end

                    level_count <= level_count - 1;

                    if (remaining_quantity > 0) begin
                        // Continues consuming from the next level after the shift completes
                        response_valid <= 1'b1;
                        state          <= kStateConsumePop;
                    end else begin
                        response_valid    <= 1'b1;
                        response_quantity <= working_quantity - remaining_quantity;
                        response_found    <= 1'b1;
                        state             <= kStateDone;
                    end
                end

                // Iterates through each level to locate the order targeted for cancellation
                kStateCancelScan: begin
                    if (cancel_level_index >= level_count) begin
                        // Reports that the target order was not found in any level
                        response_valid    <= 1'b1;
                        response_order_id <= working_order_id;
                        response_quantity <= {kQuantityWidth{1'b0}};
                        response_found    <= 1'b0;
                        state             <= kStateDone;
                    end else begin
                        // Begins FIFO traversal from the head of the current level
                        scan_pointer     <= level_head_pointer[cancel_level_index];
                        previous_pointer <= {kPointerWidth{1'b1}};
                        cancel_is_head   <= 1'b1;
                        state            <= kStateCancelUnlink;
                    end
                end

                kStateCancelUnlink: begin
                    if (!order_valid[scan_pointer]) begin
                        // Advances to the next level when the current FIFO is exhausted
                        cancel_level_index <= cancel_level_index + 1;
                        state              <= kStateCancelScan;
                    end else if (order_id[scan_pointer] == working_order_id) begin
                        // Unlinks the matched order from its FIFO and frees the slot
                        cancelled_quantity = order_quantity[scan_pointer];

                        if (cancel_is_head) begin
                            level_head_pointer[cancel_level_index] <= order_next[scan_pointer];
                        end else begin
                            order_next[previous_pointer] <= order_next[scan_pointer];
                        end

                        if (level_tail_pointer[cancel_level_index] == scan_pointer) begin
                            if (cancel_is_head)
                                level_tail_pointer[cancel_level_index] <= level_head_pointer[cancel_level_index];
                            else
                                level_tail_pointer[cancel_level_index] <= previous_pointer;
                        end

                        order_valid[scan_pointer]    <= 1'b0;
                        free_stack[free_pointer]     <= scan_pointer;
                        free_pointer                 <= free_pointer + 1;

                        level_quantity[cancel_level_index] <= level_quantity[cancel_level_index] - cancelled_quantity;

                        response_order_id <= working_order_id;
                        response_quantity <= cancelled_quantity;
                        response_found    <= 1'b1;
                        response_valid    <= 1'b1;

                        // Removes the price level entirely when the cancelled order was the last one
                        if (level_quantity[cancel_level_index] == cancelled_quantity) begin
                            for (k = 0; k < kDepth - 1; k = k + 1) begin
                                if (k[kDepthWidth:0] >= cancel_level_index
                                    && k[kDepthWidth:0] < level_count - 1) begin
                                    level_price[k]        <= level_price[k+1];
                                    level_quantity[k]     <= level_quantity[k+1];
                                    level_head_pointer[k] <= level_head_pointer[k+1];
                                    level_tail_pointer[k] <= level_tail_pointer[k+1];
                                    level_valid[k]        <= level_valid[k+1];
                                end
                            end
                            if (level_count > 0) begin
                                level_valid[level_count - 1]    <= 1'b0;
                                level_quantity[level_count - 1] <= {kQuantityWidth{1'b0}};
                            end
                            level_count <= level_count - 1;
                        end

                        state <= kStateDone;
                    end else begin
                        // Advances the scan to the next node in the FIFO
                        previous_pointer <= scan_pointer;
                        scan_pointer     <= order_next[scan_pointer];
                        cancel_is_head   <= 1'b0;
                    end
                end

                // Signals command completion and re-enables command acceptance
                kStateDone: begin
                    command_ready <= 1'b1;
                    state         <= kStateIdle;
                end

                default: state <= kStateIdle;
            endcase
        end
    end

endmodule
