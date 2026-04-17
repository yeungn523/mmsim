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
    parameter kDepth         = 16,    ///< Provides the legacy depth parameter, retained for API compatibility.
    parameter kMaxOrders     = 64,    ///< Stores the maximum number of individual orders.
    parameter kPriceWidth    = 32,    ///< Stores the bit width of the price field (unsigned ticks).
    parameter kQuantityWidth = 16,    ///< Stores the bit width of the quantity field.
    parameter kOrderIdWidth  = 16,    ///< Stores the bit width of the order identifier field.
    parameter kIsBid         = 1,     ///< Determines whether this store holds bids (1) or asks (0).
    parameter kPriceRange    = 4096   ///< Stores the number of addressable price ticks (direct-mapped depth).
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

    // Direct-mapped price level arrays (index = price). The sorted level_price[] array from the
    // previous design has been removed because the array index itself is the price.
    reg [kQuantityWidth-1:0]    level_quantity     [0:kPriceRange-1];  ///< Stores the aggregate quantity at each price.
    reg [kPointerWidth-1:0]     level_head_pointer [0:kPriceRange-1];  ///< Stores the FIFO head pointer at each price.
    reg [kPointerWidth-1:0]     level_tail_pointer [0:kPriceRange-1];  ///< Stores the FIFO tail pointer at each price.
    reg                         level_valid        [0:kPriceRange-1];  ///< Determines whether each price index holds orders.
    reg [kLevelCountWidth-1:0]  level_count;                           ///< Tracks the number of active price levels.

    // Order store (linked-list nodes).
    reg [kOrderIdWidth-1:0]  order_id       [0:kMaxOrders-1];  ///< Stores the unique identifier for each order.
    reg [kQuantityWidth-1:0] order_quantity [0:kMaxOrders-1];  ///< Stores the share count for each order.
    reg [kPointerWidth-1:0]  order_next     [0:kMaxOrders-1];  ///< Stores the next-node pointer for FIFO traversal.
    reg                      order_valid    [0:kMaxOrders-1];  ///< Determines whether each order slot is occupied.

    // Free-list stack (tracks available order store slots).
    reg [kPointerWidth-1:0]  free_stack [0:kMaxOrders-1];  ///< Stores the indices of unoccupied order slots.
    reg [kPointerWidth:0]    free_pointer;                 ///< Points to the top of the free-list stack.

    // Combinational best-price priority encoder over level_valid[]. For bids the highest occupied
    // index wins (most competitive = highest price); for asks the lowest wins. Implemented as a
    // single-pass scan with last-write-wins semantics; synthesis collapses it into a tree of
    // comparators.
    reg [kPriceIndexWidth-1:0] best_price_index;  ///< Stores the combinational best-price index.
    integer                    encoder_index;    ///< Iterates over the occupancy bitmap during encoding.

    always @(*) begin : best_price_encoder
        best_price_index = {kPriceIndexWidth{1'b0}};
        if (kIsBid) begin
            for (encoder_index = 0; encoder_index < kPriceRange; encoder_index = encoder_index + 1) begin
                if (level_valid[encoder_index])
                    best_price_index = encoder_index[kPriceIndexWidth-1:0];
            end
        end else begin
            for (encoder_index = kPriceRange - 1; encoder_index >= 0; encoder_index = encoder_index - 1) begin
                if (level_valid[encoder_index])
                    best_price_index = encoder_index[kPriceIndexWidth-1:0];
            end
        end
    end

    assign best_price    = {{(kPriceWidth - kPriceIndexWidth){1'b0}}, best_price_index};
    assign best_quantity = level_quantity[best_price_index];
    assign best_valid    = (level_count != 0);
    assign full          = (free_pointer == 0);

    // FSM state encoding.
    localparam kStateIdle         = 4'd0;  ///< Waits for a new command.
    localparam kStateInsert       = 4'd1;  ///< Performs a direct-mapped insert at index = price.
    localparam kStateConsumePop   = 4'd2;  ///< Pops orders from the best level's FIFO head.
    localparam kStateCancelScan   = 4'd3;  ///< Advances the scan index to the next occupied level.
    localparam kStateCancelUnlink = 4'd4;  ///< Traverses a level's FIFO to unlink the cancelled order.
    localparam kStateDone         = 4'd5;  ///< Signals command completion and returns to idle.

    reg [3:0] state;  ///< Stores the current FSM state.

    // Working registers (latched from the command interface for multi-cycle processing).
    reg [2:0]                  working_command;    ///< Latches the active command code.
    reg [kPriceWidth-1:0]      working_price;      ///< Latches the active order's price.
    reg [kQuantityWidth-1:0]   working_quantity;   ///< Latches the active order's quantity.
    reg [kOrderIdWidth-1:0]    working_order_id;   ///< Latches the active order's identifier.
    reg [kQuantityWidth-1:0]   remaining_quantity; ///< Tracks unconsumed quantity during consume.
    reg [kPriceIndexWidth-1:0] cancel_level_index; ///< Holds the price index being scanned for cancel.
    reg [kPointerWidth-1:0]    scan_pointer;       ///< Points to the current FIFO node during cancel.
    reg [kPointerWidth-1:0]    previous_pointer;   ///< Points to the preceding FIFO node during cancel.
    reg                        cancel_is_head;     ///< Determines whether the scanned node is the FIFO head.

    integer i;

    always @(posedge clk or negedge rst_n) begin : main_proc
        // Declares local variables shared across multiple states at the top of the named block.
        reg [kPointerWidth-1:0]    slot;
        reg [kPointerWidth-1:0]    head_slot;
        reg [kQuantityWidth-1:0]   head_order_quantity;
        reg [kQuantityWidth-1:0]   new_level_quantity;
        reg [kQuantityWidth-1:0]   cancelled_quantity;
        reg [kPriceIndexWidth-1:0] insert_index;

        if (!rst_n) begin
            state             <= kStateIdle;
            command_ready     <= 1'b1;
            response_valid    <= 1'b0;
            response_found    <= 1'b0;
            response_order_id <= {kOrderIdWidth{1'b0}};
            response_quantity <= {kQuantityWidth{1'b0}};
            level_count       <= {kLevelCountWidth{1'b0}};
            free_pointer      <= kMaxOrders[kPointerWidth:0];

            for (i = 0; i < kPriceRange; i = i + 1) begin
                level_valid[i]        <= 1'b0;
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
            // Clears response_valid after each single-cycle pulse.
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
                            kCommandInsert: state <= kStateInsert;
                            kCommandConsume: begin
                                remaining_quantity <= command_quantity;
                                state              <= kStateConsumePop;
                            end
                            kCommandCancel: begin
                                cancel_level_index <= {kPriceIndexWidth{1'b0}};
                                state              <= kStateCancelScan;
                            end
                            default: command_ready <= 1'b1;
                        endcase
                    end
                end

                // Performs a direct-mapped insert where the price itself serves as the storage
                // index. Rejects the insert when the price exceeds the addressable range or no
                // free order slots remain; both rejections use the same zero-quantity response path.
                kStateInsert: begin
                    if (working_price >= kPriceRange[kPriceWidth-1:0] || free_pointer == 0) begin
                        response_valid    <= 1'b1;
                        response_order_id <= {kOrderIdWidth{1'b0}};
                        response_quantity <= {kQuantityWidth{1'b0}};
                        response_found    <= 1'b0;
                        state             <= kStateDone;
                    end else begin
                        insert_index = working_price[kPriceIndexWidth-1:0];
                        slot         = free_stack[free_pointer - 1];

                        order_id[slot]       <= working_order_id;
                        order_quantity[slot] <= working_quantity;
                        order_next[slot]     <= {kPointerWidth{1'b0}};
                        order_valid[slot]    <= 1'b1;

                        if (!level_valid[insert_index]) begin
                            // Activates a new price level at this index.
                            level_valid[insert_index]        <= 1'b1;
                            level_head_pointer[insert_index] <= slot;
                            level_tail_pointer[insert_index] <= slot;
                            level_quantity[insert_index]     <= working_quantity;
                            level_count                      <= level_count + 1'b1;
                        end else begin
                            // Appends the new order to the existing FIFO tail.
                            order_next[level_tail_pointer[insert_index]] <= slot;
                            level_tail_pointer[insert_index]             <= slot;
                            level_quantity[insert_index]                 <=
                                level_quantity[insert_index] + working_quantity;
                        end

                        free_pointer <= free_pointer - 1'b1;

                        response_valid    <= 1'b1;
                        response_quantity <= working_quantity;
                        response_order_id <= working_order_id;
                        response_found    <= 1'b1;
                        state             <= kStateDone;
                    end
                end

                // Removes quantity from the best price level by popping orders from the FIFO head.
                // When a level's aggregate quantity reaches zero, the level is deactivated in-place;
                // the priority encoder surfaces the next best level on the following cycle with no
                // shift required.
                kStateConsumePop: begin
                    if (level_count == 0 || remaining_quantity == 0) begin
                        // Reports the total consumed quantity when no more can be removed. Preserves
                        // response_order_id from the final fill iteration; zeroes it only when the
                        // book was empty at the start of the consume.
                        response_valid    <= 1'b1;
                        response_quantity <= working_quantity - remaining_quantity;
                        response_found    <= (remaining_quantity != working_quantity);
                        if (remaining_quantity == working_quantity)
                            response_order_id <= {kOrderIdWidth{1'b0}};
                        state             <= kStateDone;
                    end else begin
                        head_slot           = level_head_pointer[best_price_index];
                        head_order_quantity = order_quantity[head_slot];

                        response_order_id <= order_id[head_slot];

                        if (remaining_quantity >= head_order_quantity) begin
                            // Fully consumes the head order and frees its slot.
                            new_level_quantity = level_quantity[best_price_index] - head_order_quantity;

                            level_quantity[best_price_index] <= new_level_quantity;
                            remaining_quantity              <= remaining_quantity - head_order_quantity;
                            response_quantity               <= head_order_quantity;

                            level_head_pointer[best_price_index] <= order_next[head_slot];
                            order_valid[head_slot]              <= 1'b0;
                            free_stack[free_pointer]            <= head_slot;
                            free_pointer                        <= free_pointer + 1'b1;

                            if (new_level_quantity == 0) begin
                                // Deactivates the level in place; no array shifting is required.
                                level_valid[best_price_index] <= 1'b0;
                                level_count                  <= level_count - 1'b1;
                            end

                            response_valid <= 1'b1;
                            state          <= kStateConsumePop;
                        end else begin
                            // Partially fills the head order and completes the consume operation.
                            order_quantity[head_slot]       <= head_order_quantity - remaining_quantity;
                            level_quantity[best_price_index] <= level_quantity[best_price_index] - remaining_quantity;
                            response_quantity               <= remaining_quantity;
                            remaining_quantity              <= {kQuantityWidth{1'b0}};

                            response_valid <= 1'b1;
                            response_found <= 1'b1;
                            state          <= kStateDone;
                        end
                    end
                end

                // Advances the cancel scan to the next occupied price index. Sparse occupancy in
                // the direct-mapped layout means this may step over empty slots until an active
                // level is reached, or until the scan runs off the end of the addressable range.
                kStateCancelScan: begin
                    if (level_count == 0) begin
                        response_valid    <= 1'b1;
                        response_order_id <= working_order_id;
                        response_quantity <= {kQuantityWidth{1'b0}};
                        response_found    <= 1'b0;
                        state             <= kStateDone;
                    end else if (level_valid[cancel_level_index]) begin
                        scan_pointer     <= level_head_pointer[cancel_level_index];
                        previous_pointer <= {kPointerWidth{1'b1}};
                        cancel_is_head   <= 1'b1;
                        state            <= kStateCancelUnlink;
                    end else if (cancel_level_index == kMaxPriceIndex[kPriceIndexWidth-1:0]) begin
                        // Reports a not-found result after reaching the end of the addressable range.
                        response_valid    <= 1'b1;
                        response_order_id <= working_order_id;
                        response_quantity <= {kQuantityWidth{1'b0}};
                        response_found    <= 1'b0;
                        state             <= kStateDone;
                    end else begin
                        cancel_level_index <= cancel_level_index + 1'b1;
                    end
                end

                // Traverses the FIFO at the current level to locate the cancelled order.
                kStateCancelUnlink: begin
                    if (!order_valid[scan_pointer]) begin
                        // Continues scanning from the next price index after exhausting the current
                        // FIFO without a match, or terminates at the end of the addressable range.
                        if (cancel_level_index == kMaxPriceIndex[kPriceIndexWidth-1:0]) begin
                            response_valid    <= 1'b1;
                            response_order_id <= working_order_id;
                            response_quantity <= {kQuantityWidth{1'b0}};
                            response_found    <= 1'b0;
                            state             <= kStateDone;
                        end else begin
                            cancel_level_index <= cancel_level_index + 1'b1;
                            state              <= kStateCancelScan;
                        end
                    end else if (order_id[scan_pointer] == working_order_id) begin
                        // Unlinks the matched order from its FIFO and frees the slot.
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

                        order_valid[scan_pointer] <= 1'b0;
                        free_stack[free_pointer]  <= scan_pointer;
                        free_pointer              <= free_pointer + 1'b1;

                        level_quantity[cancel_level_index] <=
                            level_quantity[cancel_level_index] - cancelled_quantity;

                        // Deactivates the price level when the cancelled order was the last one.
                        if (level_quantity[cancel_level_index] == cancelled_quantity) begin
                            level_valid[cancel_level_index] <= 1'b0;
                            level_count                     <= level_count - 1'b1;
                        end

                        response_order_id <= working_order_id;
                        response_quantity <= cancelled_quantity;
                        response_found    <= 1'b1;
                        response_valid    <= 1'b1;
                        state             <= kStateDone;
                    end else begin
                        // Advances to the next node in the FIFO.
                        previous_pointer <= scan_pointer;
                        scan_pointer     <= order_next[scan_pointer];
                        cancel_is_head   <= 1'b0;
                    end
                end

                // Signals command completion and re-enables command acceptance.
                kStateDone: begin
                    command_ready <= 1'b1;
                    state         <= kStateIdle;
                end

                default: state <= kStateIdle;
            endcase
        end
    end

endmodule
