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
    reg                                               order_valid    [0:kMaxOrders-1];  ///< Determines whether each order slot is occupied (stays in flops so reset can broadcast-clear and the 1-bit width does not waste an M10K block).

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

    // Registers the level_quantity read at best_price_index to let Quartus infer M10K for level_quantity.
    reg [kQuantityWidth-1:0] best_quantity_reg = {kQuantityWidth{1'b0}};  ///< Stores the registered best-price aggregate quantity.

    always @(posedge clk) begin : best_quantity_read
        if (!rst_n)
            best_quantity_reg <= {kQuantityWidth{1'b0}};
        else
            best_quantity_reg <= level_quantity[best_price_index];
    end

    assign best_price    = {{(kPriceWidth - kPriceIndexWidth){1'b0}}, best_price_index};
    assign best_quantity = best_quantity_reg;
    assign best_valid    = (level_count != 0);
    assign full          = (free_pointer == 0);

    // M10K ports for the order-indexed arrays. Each uses the canonical Altera 1R+1W
    // simple-dual-port template so Quartus pattern-matches the storage onto a Cyclone V
    // M10K block. The read path is registered, so rdata reflects the value at raddr with
    // one cycle of latency; the FSM pipelines its state transitions to account for that.
    // order_price has no FSM read port because price is a downstream-consumer metric only.
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

    // FSM state encoding. The consume and cancel paths each add a single wait state so
    // that a freshly-issued raddr has one full cycle to propagate through the M10K read
    // port before the consuming state latches rdata.
    localparam kStateIdle              = 4'd0;   ///< Waits for a new command.
    localparam kStateInsert            = 4'd1;   ///< Performs a direct-mapped insert at index = price.
    localparam kStateConsumePop        = 4'd2;   ///< Issues order-array reads for the current best head, or emits the terminating response.
    localparam kStateConsumeWait       = 4'd3;   ///< Holds one cycle so the order-array read port latches the head slot's rdata.
    localparam kStateConsumeExecute    = 4'd4;   ///< Consumes the head order using the registered order reads.
    localparam kStateCancelScan        = 4'd5;   ///< Advances the scan index to the next occupied price level.
    localparam kStateCancelWait        = 4'd6;   ///< Holds one cycle so the order-array read port latches the scan slot's rdata.
    localparam kStateCancelFetchNode   = 4'd7;   ///< Evaluates the registered scan node and advances, matches, or skips.
    localparam kStateCancelCleanup     = 4'd8;   ///< Clears the freed slot's order_next so later re-inserts inherit a zero tail.
    localparam kStateDone              = 4'd9;   ///< Signals command completion and returns to idle.
    localparam kStateSettle            = 4'd10;  ///< Stalls one cycle for the pipelined encoder before pulsing response_valid.
    localparam kStateRescan            = 4'd11;  ///< Stalls one cycle during consume for the encoder to settle.

    reg [3:0] state;  ///< Stores the current FSM state.

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
    reg [kPointerWidth-1:0]    head_slot_reg;      ///< Latches the head-of-FIFO slot so the execute state can act on registered order reads.

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
            state             <= kStateIdle;
            command_ready     <= 1'b1;
            response_valid    <= 1'b0;
            response_found    <= 1'b0;
            response_order_id <= {kOrderIdWidth{1'b0}};
            response_quantity <= {kQuantityWidth{1'b0}};
            level_count       <= {kLevelCountWidth{1'b0}};
            free_pointer      <= kMaxOrders[kPointerWidth:0];
            consumed_so_far   <= {kQuantityWidth{1'b0}};
            head_slot_reg     <= {kPointerWidth{1'b0}};

            // Port enables default to zero after reset. The M10K-backed arrays rely on
            // the power-up initial block and the freed-slot-clears-order_next invariant
            // for their valid state; reset does not re-zero them here because broadcast
            // writes through a single-port memory are not inferable on Cyclone V.
            order_id_we          <= 1'b0;
            order_quantity_we    <= 1'b0;
            order_next_we        <= 1'b0;
            order_price_we       <= 1'b0;
            order_id_raddr       <= {kPointerWidth{1'b0}};
            order_quantity_raddr <= {kPointerWidth{1'b0}};
            order_next_raddr     <= {kPointerWidth{1'b0}};

            for (i = 0; i < kPriceRange; i = i + 1) begin
                level_valid[i] <= 1'b0;
            end

            for (i = 0; i < kMaxOrders; i = i + 1) begin
                order_valid[i] <= 1'b0;
                free_stack[i]  <= i[kPointerWidth-1:0];
            end
        end else begin
            // Defaults applied before the case statement so that port writes and the
            // response pulse are single-cycle events unless a specific state re-asserts them.
            response_valid    <= 1'b0;
            order_id_we       <= 1'b0;
            order_quantity_we <= 1'b0;
            order_next_we     <= 1'b0;
            order_price_we    <= 1'b0;

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
                                consumed_so_far    <= {kQuantityWidth{1'b0}};
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

                // Performs a direct-mapped insert; rejects when the price is out of range or the store is full.
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

                        // Drives the order-indexed M10K writes through their dedicated ports.
                        order_id_we         <= 1'b1;
                        order_id_waddr      <= slot;
                        order_id_wdata      <= working_order_id;

                        order_quantity_we    <= 1'b1;
                        order_quantity_waddr <= slot;
                        order_quantity_wdata <= working_quantity;

                        order_price_we       <= 1'b1;
                        order_price_waddr    <= slot;
                        order_price_wdata    <= insert_index;

                        order_valid[slot]    <= 1'b1;

                        if (!level_valid[insert_index]) begin
                            // Activates a new price level at this index. The slot's order_next
                            // remains zero by the freed-slot invariant (consume pop and cancel
                            // cleanup clear it on release), so no port cycle is spent here.
                            level_valid[insert_index]        <= 1'b1;
                            level_head_pointer[insert_index] <= slot;
                            level_tail_pointer[insert_index] <= slot;
                            level_quantity[insert_index]     <= working_quantity;
                            level_count                      <= level_count + 1'b1;
                        end else begin
                            // Appends the new order to the existing FIFO tail. One port write
                            // links the old tail to the new slot; the new slot's own order_next
                            // stays zero by the same freed-slot invariant.
                            order_next_we    <= 1'b1;
                            order_next_waddr <= level_tail_pointer[insert_index];
                            order_next_wdata <= slot;
                            level_tail_pointer[insert_index] <= slot;
                            level_quantity[insert_index]     <=
                                level_quantity[insert_index] + working_quantity;
                        end

                        free_pointer <= free_pointer - 1'b1;

                        response_quantity <= working_quantity;
                        response_order_id <= working_order_id;
                        response_found    <= 1'b1;
                        state             <= kStateSettle;
                    end
                end

                // Decides whether to terminate the consume or issue reads for the next head order.
                kStateConsumePop: begin
                    if (level_count == 0 || remaining_quantity == 0) begin
                        // Emits the aggregate consumed quantity; zeroes response_order_id only when the book was empty.
                        response_valid    <= 1'b1;
                        response_quantity <= consumed_so_far;
                        response_found    <= (consumed_so_far != {kQuantityWidth{1'b0}});
                        if (consumed_so_far == {kQuantityWidth{1'b0}})
                            response_order_id <= {kOrderIdWidth{1'b0}};
                        state <= kStateDone;
                    end else begin
                        // Issues the order-array reads for the current best head and latches the
                        // head slot. The consuming state picks the rdata up two cycles later,
                        // after kStateConsumeWait covers the read-port propagation delay.
                        head_slot_local      = level_head_pointer[best_price_index];
                        head_slot_reg        <= head_slot_local;
                        order_id_raddr       <= head_slot_local;
                        order_quantity_raddr <= head_slot_local;
                        order_next_raddr     <= head_slot_local;
                        state                <= kStateConsumeWait;
                    end
                end

                // Holds one cycle so the M10K read port latches order rdata for head_slot_reg.
                kStateConsumeWait: begin
                    state <= kStateConsumeExecute;
                end

                // Consumes the head order using the registered order-array reads.
                kStateConsumeExecute: begin
                    head_order_quantity = order_quantity_rdata;
                    response_order_id   <= order_id_rdata;

                    if (remaining_quantity >= head_order_quantity) begin
                        // Fully consumes the head order, frees its slot, and accumulates the fill.
                        new_level_quantity = level_quantity[best_price_index] - head_order_quantity;

                        level_quantity[best_price_index] <= new_level_quantity;
                        remaining_quantity               <= remaining_quantity - head_order_quantity;
                        consumed_so_far                  <= consumed_so_far + head_order_quantity;

                        level_head_pointer[best_price_index] <= order_next_rdata;
                        order_valid[head_slot_reg]           <= 1'b0;
                        free_stack[free_pointer]             <= head_slot_reg;
                        free_pointer                         <= free_pointer + 1'b1;

                        // Clears order_next at the freed slot so a future re-insert inherits
                        // a zero tail pointer without spending an extra port cycle.
                        order_next_we    <= 1'b1;
                        order_next_waddr <= head_slot_reg;
                        order_next_wdata <= {kPointerWidth{1'b0}};

                        if (new_level_quantity == 0) begin
                            // Deactivates the level in place and stalls one cycle to let the encoder settle.
                            level_valid[best_price_index] <= 1'b0;
                            level_count                   <= level_count - 1'b1;
                            state <= kStateRescan;
                        end else begin
                            state <= kStateConsumePop;
                        end
                    end else begin
                        // Partially fills the head order and loops back so the terminating branch emits the final response.
                        order_quantity_we    <= 1'b1;
                        order_quantity_waddr <= head_slot_reg;
                        order_quantity_wdata <= head_order_quantity - remaining_quantity;

                        level_quantity[best_price_index] <= level_quantity[best_price_index] - remaining_quantity;
                        consumed_so_far                  <= consumed_so_far + remaining_quantity;
                        remaining_quantity               <= {kQuantityWidth{1'b0}};

                        state <= kStateConsumePop;
                    end
                end

                // Advances the cancel scan to the next occupied price index, skipping empty direct-mapped slots.
                kStateCancelScan: begin
                    if (level_count == 0) begin
                        response_valid    <= 1'b1;
                        response_order_id <= working_order_id;
                        response_quantity <= {kQuantityWidth{1'b0}};
                        response_found    <= 1'b0;
                        state             <= kStateDone;
                    end else if (level_valid[cancel_level_index]) begin
                        // Latches the head slot and issues order-array reads so the checking
                        // state can match against the registered rdata after the wait cycle.
                        scan_pointer         <= level_head_pointer[cancel_level_index];
                        order_id_raddr       <= level_head_pointer[cancel_level_index];
                        order_quantity_raddr <= level_head_pointer[cancel_level_index];
                        order_next_raddr     <= level_head_pointer[cancel_level_index];
                        previous_pointer     <= {kPointerWidth{1'b1}};
                        cancel_is_head       <= 1'b1;
                        state                <= kStateCancelWait;
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

                // Holds one cycle so the M10K read port latches order rdata for scan_pointer.
                kStateCancelWait: begin
                    state <= kStateCancelFetchNode;
                end

                // Evaluates the registered order-array reads at scan_pointer and either unlinks
                // the matched order, advances to the next FIFO node (reissuing the reads), or
                // moves on to the next level when the scan lands on an unoccupied slot.
                kStateCancelFetchNode: begin
                    if (!order_valid[scan_pointer]) begin
                        // Continues the scan at the next price index, or terminates at the end of the addressable range.
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
                    end else if (order_id_rdata == working_order_id) begin
                        // Unlinks the matched order from its FIFO and frees the slot. The freed
                        // slot's order_next is zeroed in kStateCancelCleanup because the middle
                        // branch already consumed the order_next write port this cycle.
                        cancelled_quantity = order_quantity_rdata;

                        if (cancel_is_head) begin
                            level_head_pointer[cancel_level_index] <= order_next_rdata;
                        end else begin
                            order_next_we    <= 1'b1;
                            order_next_waddr <= previous_pointer;
                            order_next_wdata <= order_next_rdata;
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
                        state             <= kStateCancelCleanup;
                    end else begin
                        // Advances to the next FIFO node and reissues the order-array reads. The
                        // wait state covers the one-cycle propagation delay before the next check.
                        previous_pointer     <= scan_pointer;
                        scan_pointer         <= order_next_rdata;
                        order_id_raddr       <= order_next_rdata;
                        order_quantity_raddr <= order_next_rdata;
                        order_next_raddr     <= order_next_rdata;
                        cancel_is_head       <= 1'b0;
                        state                <= kStateCancelWait;
                    end
                end

                // Zeros order_next at the freed slot so a later re-insert into this slot starts
                // with a clean tail pointer. Only entered from the match branch of FetchNode.
                kStateCancelCleanup: begin
                    order_next_we    <= 1'b1;
                    order_next_waddr <= scan_pointer;
                    order_next_wdata <= {kPointerWidth{1'b0}};
                    state            <= kStateSettle;
                end

                // Signals command completion and re-enables command acceptance.
                kStateDone: begin
                    command_ready <= 1'b1;
                    state         <= kStateIdle;
                end

                // Stalls one cycle for the pipelined encoder to settle, then pulses response_valid.
                kStateSettle: begin
                    response_valid <= 1'b1;
                    state          <= kStateDone;
                end

                // Stalls one cycle for the pipelined encoder to settle, then resumes the consume loop.
                kStateRescan: begin
                    state <= kStateConsumePop;
                end

                default: state <= kStateIdle;
            endcase
        end
    end

endmodule
