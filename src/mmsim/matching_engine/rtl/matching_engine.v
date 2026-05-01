`timescale 1ns/1ns

///
/// @file matching_engine.v
/// @brief Three-stage pipelined matching engine over two no-cancellation price level stores.
///
/// Stage A latches one order packet on an accepted valid/ready handshake whenever Stage B is idle and the prior
/// packet has retired through Stage C; the upstream FIFO holds queued packets until then. Stage B runs the match loop
/// on the latched packet, driving CONSUME commands into the opposite-side book and emitting trade pulses on every
/// fill. Stage C commits any unmatched limit remainder via a single INSERT to the same-side book. The B-to-C handoff
/// register lets Stage B start the next packet while Stage C is still committing the previous one.
///

module matching_engine #(
    parameter kPriceWidth      = 32,    ///< Bit width of the internal price field.
    parameter kQuantityWidth   = 16,    ///< Bit width of the quantity field.
    parameter kPriceRange      = 480,   ///< Number of addressable price ticks.
    parameter kTickShiftBits   = 23     ///< Left-shift applied to a tick to expose last_executed_price as Q8.24.
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Latches one order packet per accepted handshake whenever Stage B is idle and the prior packet has fully retired
    // through Stage C; the upstream FIFO absorbs bursts.
    input  wire [31:0]                 order_packet,
    input  wire                        order_valid,
    output wire                        order_ready,

    // Pulses once per filled price level during a sweep.
    output reg  [kPriceWidth-1:0]      trade_price,
    output reg  [kQuantityWidth-1:0]   trade_quantity,
    output reg                         trade_side,           ///< 0 = buy aggressor, 1 = sell aggressor.
    output reg                         trade_valid,

    // Holds the most recent fill price across packets, exposed as a Q8.24 unsigned price so it matches the agent
    // execution unit's last_executed_price contract directly. trade_price and best_*_price remain in raw tick units;
    // only last_executed_price crosses the agent boundary.
    output reg  [kPriceWidth-1:0]      last_executed_price,
    output reg                         last_executed_price_valid,

    // Exposes top-of-book state via combinational taps from each store.
    output wire [kPriceWidth-1:0]      best_bid_price,
    output wire [kQuantityWidth-1:0]   best_bid_quantity,
    output wire                        best_bid_valid,
    output wire [kPriceWidth-1:0]      best_ask_price,
    output wire [kQuantityWidth-1:0]   best_ask_quantity,
    output wire                        best_ask_valid,

    // Pulses for one cycle per packet retired through Stage C and reports that packet's exact trade aggregates. Stage
    // B and Stage C run concurrently on adjacent packets, so the TB cannot derive per-packet trade counts from the
    // trade bus alone.
    output reg                         order_retire_valid,
    output reg  [kQuantityWidth-1:0]   order_retire_trade_count,    ///< Trade pulses emitted for this packet.
    output reg  [kQuantityWidth-1:0]   order_retire_fill_quantity,  ///< Total shares filled across this packet.

    // VGA depth-read tap forwarded to both books. HPS drives a single tick index and the engine returns the bid-side
    // and ask-side quantities at that tick; adds one cycle of staleness to each best-quantity readout (see
    // price_level_store).
    input  wire [8:0]                  depth_rd_addr,
    output wire [kQuantityWidth-1:0]   bid_depth_rd_data,
    output wire [kQuantityWidth-1:0]   ask_depth_rd_data,
	 
	 output reg [1:0] order_retire_agent_type
);

    // Book command opcodes (must match price_level_store).
    localparam [1:0] kCommandNop     = 2'd0;  ///< Skips the cycle without modifying the book.
    localparam [1:0] kCommandInsert  = 2'd1;  ///< Adds shares to the level at command_price.
    localparam [1:0] kCommandConsume = 2'd2;  ///< Consumes shares from the current best price.

    // Stage B substate encoding.
    localparam [2:0] kBIdle       = 3'd0;  ///< Latches the next order packet from the boundary handshake.
    localparam [2:0] kBClassify   = 3'd1;  ///< Routes the packet into match or handoff.
    localparam [2:0] kBMatchCheck = 3'd2;  ///< Inspects the opposite side for a crossable level.
    localparam [2:0] kBMatchExec  = 3'd3;  ///< Issues a CONSUME on the opposite store.
    localparam [2:0] kBMatchWait  = 3'd4;  ///< Awaits the consume response and emits a trade pulse.
    localparam [2:0] kBHandoff    = 3'd5;  ///< Writes the B-to-C register and returns to idle.

    // Stage C substate encoding.
    localparam [1:0] kCIdle   = 2'd0;  ///< Waits for a B-to-C register write.
    localparam [1:0] kCDrive  = 2'd1;  ///< Issues an INSERT on the same-side store.
    localparam [1:0] kCWait   = 2'd2;  ///< Awaits the insert response.
    localparam [1:0] kCSettle = 2'd3;  ///< Lets best_* propagate, then pulses order_retire_valid.

    // Latches Stage B's working packet on accepted handshake and tracks remaining shares through fills.
    reg [2:0]                   b_state;
    reg                         b_working_is_buy;
    reg                         b_working_is_market;
    reg [kPriceWidth-1:0]       b_working_price;
    reg [kQuantityWidth-1:0]    b_working_remaining;
    reg [kPriceWidth-1:0]       b_working_trade_price;

    // Accumulates per-packet trade aggregates across Stage B's match loop and copies them into the B-to-C register at
    // handoff.
    reg [kQuantityWidth-1:0]    b_packet_trade_count;
    reg [kQuantityWidth-1:0]    b_packet_fill_quantity;

    // Holds one packet's tail data while Stage C commits or retires it, decoupling Stage B so it can immediately start
    // the next packet.
    reg                         b_to_c_valid;
    reg                         b_to_c_for_insert;       ///< 1 = Stage C must INSERT, 0 = retire only.
    reg [kPriceWidth-1:0]       b_to_c_price;
    reg [kQuantityWidth-1:0]    b_to_c_remaining;
    reg                         b_to_c_is_buy;
    reg [kQuantityWidth-1:0]    b_to_c_trade_count;
    reg [kQuantityWidth-1:0]    b_to_c_fill_quantity;

    // Tracks Stage C's substate.
    reg [1:0]                   c_state;

    // Wires Stage B and Stage C to the two book stores through the bus mux below.
    reg  [1:0]                  bid_command;
    reg  [kPriceWidth-1:0]      bid_command_price;
    reg  [kQuantityWidth-1:0]   bid_command_quantity;
    reg                         bid_command_valid;
    wire                        bid_command_ready;
    wire [kQuantityWidth-1:0]   bid_response_quantity;
    wire                        bid_response_valid;

    reg  [1:0]                  ask_command;
    reg  [kPriceWidth-1:0]      ask_command_price;
    reg  [kQuantityWidth-1:0]   ask_command_quantity;
    reg                         ask_command_valid;
    wire                        ask_command_ready;
    wire [kQuantityWidth-1:0]   ask_response_quantity;
    wire                        ask_response_valid;

    // Tracks whether a command is in flight on each book so the engine cannot issue a duplicate before the store
    // completes. Clears when the store reasserts command_ready.
    reg                         bid_in_flight;
    reg                         ask_in_flight;
	 
	 reg [1:0] b_working_agent_type;
	 reg [1:0] b_to_c_agent_type;

    // Instantiates the bid-side and ask-side aggregate-quantity stores.
    price_level_store #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kIsBid         (1),
        .kPriceRange    (kPriceRange)
    ) bid_book (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (bid_command),
        .command_price     (bid_command_price),
        .command_quantity  (bid_command_quantity),
        .command_valid     (bid_command_valid),
        .command_ready     (bid_command_ready),
        .response_quantity (bid_response_quantity),
        .response_valid    (bid_response_valid),
        .best_price        (best_bid_price),
        .best_quantity     (best_bid_quantity),
        .best_valid        (best_bid_valid),
        .depth_rd_addr     (depth_rd_addr),
        .depth_rd_data     (bid_depth_rd_data)
    );

    price_level_store #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kIsBid         (0),
        .kPriceRange    (kPriceRange)
    ) ask_book (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (ask_command),
        .command_price     (ask_command_price),
        .command_quantity  (ask_command_quantity),
        .command_valid     (ask_command_valid),
        .command_ready     (ask_command_ready),
        .response_quantity (ask_response_quantity),
        .response_valid    (ask_response_valid),
        .best_price        (best_ask_price),
        .best_quantity     (best_ask_quantity),
        .best_valid        (best_ask_valid),
        .depth_rd_addr     (depth_rd_addr),
        .depth_rd_data     (ask_depth_rd_data)
    );

    // Asserts order_ready only when Stage B is idle and the prior packet has fully retired through Stage C, so the
    // upstream FIFO holds new packets while the engine processes the current one.
    assign order_ready = (b_state == kBIdle) && !b_to_c_valid;
    wire   accept_packet = order_valid && order_ready;

    // Decodes the incoming order packet directly off the boundary; the producer holds these bits stable while
    // order_valid is high.
    wire        head_side    = order_packet[31];
    wire        head_type    = order_packet[30];
    wire [8:0]  head_price   = order_packet[24:16];
    wire [15:0] head_volume  = order_packet[15:0];

    // Names the opposite-side best relative to Stage B's working packet.
    wire [kPriceWidth-1:0] opposite_best_price = b_working_is_buy ? best_ask_price : best_bid_price;
    wire                   opposite_best_valid = b_working_is_buy ? best_ask_valid : best_bid_valid;

    // Determines whether Stage B's working limit crosses the opposite-side best.
    wire b_limit_crosses = b_working_is_buy
        ? (opposite_best_price <= b_working_price)
        : (opposite_best_price >= b_working_price);
    wire b_can_match     = opposite_best_valid && (b_working_is_market || b_limit_crosses);


    // Routes Stage B's CONSUMEs and Stage C's INSERTs to the right store, granting Stage C priority on the shared bus
    // because it is draining an older packet.
    wire b_targets_bid = (b_state == kBMatchExec) && !b_working_is_buy;
    wire b_targets_ask = (b_state == kBMatchExec) &&  b_working_is_buy;
    wire c_targets_bid = (c_state == kCDrive)     &&  b_to_c_is_buy;
    wire c_targets_ask = (c_state == kCDrive)     && !b_to_c_is_buy;

    // Grants the bus to Stage C over Stage B on ties.
    wire bid_grant_c = c_targets_bid && bid_command_ready && !bid_in_flight;
    wire bid_grant_b = b_targets_bid && bid_command_ready && !bid_in_flight && !c_targets_bid;
    wire ask_grant_c = c_targets_ask && ask_command_ready && !ask_in_flight;
    wire ask_grant_b = b_targets_ask && ask_command_ready && !ask_in_flight && !c_targets_ask;

    always @(*) begin
        bid_command          = kCommandNop;
        bid_command_price    = {kPriceWidth{1'b0}};
        bid_command_quantity = {kQuantityWidth{1'b0}};
        bid_command_valid    = 1'b0;
        if (bid_grant_c) begin
            bid_command          = kCommandInsert;
            bid_command_price    = b_to_c_price;
            bid_command_quantity = b_to_c_remaining;
            bid_command_valid    = 1'b1;
        end else if (bid_grant_b) begin
            bid_command          = kCommandConsume;
            bid_command_price    = {kPriceWidth{1'b0}};
            bid_command_quantity = b_working_remaining;
            bid_command_valid    = 1'b1;
        end

        ask_command          = kCommandNop;
        ask_command_price    = {kPriceWidth{1'b0}};
        ask_command_quantity = {kQuantityWidth{1'b0}};
        ask_command_valid    = 1'b0;
        if (ask_grant_c) begin
            ask_command          = kCommandInsert;
            ask_command_price    = b_to_c_price;
            ask_command_quantity = b_to_c_remaining;
            ask_command_valid    = 1'b1;
        end else if (ask_grant_b) begin
            ask_command          = kCommandConsume;
            ask_command_price    = {kPriceWidth{1'b0}};
            ask_command_quantity = b_working_remaining;
            ask_command_valid    = 1'b1;
        end
    end

    // Drives Stage B's substate machine and the trade bus. Stage B is the sole writer of every trade-related output.
    always @(posedge clk) begin
        if (!rst_n) begin
            b_state               <= kBIdle;
            b_working_is_buy      <= 1'b0;
            b_working_is_market   <= 1'b0;
            b_working_price       <= {kPriceWidth{1'b0}};
            b_working_remaining   <= {kQuantityWidth{1'b0}};
            b_working_trade_price <= {kPriceWidth{1'b0}};

            b_packet_trade_count   <= {kQuantityWidth{1'b0}};
            b_packet_fill_quantity <= {kQuantityWidth{1'b0}};

            trade_valid            <= 1'b0;
            trade_price            <= {kPriceWidth{1'b0}};
            trade_quantity         <= {kQuantityWidth{1'b0}};
            trade_side             <= 1'b0;
            last_executed_price       <= {kPriceWidth{1'b0}};
            last_executed_price_valid <= 1'b0;

            bid_in_flight <= 1'b0;
            ask_in_flight <= 1'b0;
        end else begin
            // Deasserts trade_valid by default; case branches reassert when a fill emits.
            trade_valid <= 1'b0;

            // Clears the in-flight flags on store completion.
            if (bid_in_flight && bid_command_ready) bid_in_flight <= 1'b0;
            if (ask_in_flight && ask_command_ready) ask_in_flight <= 1'b0;

            // Sets the in-flight flag when the mux issues a command on either store this cycle.
            if (bid_grant_c || bid_grant_b) bid_in_flight <= 1'b1;
            if (ask_grant_c || ask_grant_b) ask_in_flight <= 1'b1;

            case (b_state)
                kBIdle: begin
                    // Latches the next packet on an accepted handshake; order_ready already gates this on (kBIdle &&
                    // !b_to_c_valid) so Stage B is serialized with C and kBClassify reads coherent best_* values.
                    if (accept_packet) begin
                        b_working_is_buy       <= ~head_side;
                        b_working_is_market    <= head_type;
                        b_working_price        <= {{(kPriceWidth - 9){1'b0}}, head_price};
                        b_working_remaining    <= head_volume;
                        b_packet_trade_count   <= {kQuantityWidth{1'b0}};
                        b_packet_fill_quantity <= {kQuantityWidth{1'b0}};
                        b_state                <= kBClassify;
								b_working_agent_type <= order_packet[29:28];
                    end
                end

                kBClassify: begin
                    // Sends market and crossing-limit packets into the match loop; non-crossing limits go straight to
                    // handoff for insert.
                    if (b_working_is_market) begin
                        b_state <= kBMatchCheck;
                    end else if (opposite_best_valid && b_limit_crosses) begin
                        b_state <= kBMatchCheck;
                    end else begin
                        b_state <= kBHandoff;
                    end
                end

                kBMatchCheck: begin
                    // Exits the loop when filled, when the opposite side is empty, or when the next-best opposite
                    // price no longer crosses (limits only).
                    if (b_working_remaining == {kQuantityWidth{1'b0}}) begin
                        b_state <= kBHandoff;
                    end else if (!b_can_match) begin
                        b_state <= kBHandoff;
                    end else begin
                        b_state <= kBMatchExec;
                    end
                end

                kBMatchExec: begin
                    // Latches the opposite-side best price for this fill and waits for the bus mux grant. Stalls here
                    // when Stage C holds the same store or it is busy.
                    b_working_trade_price <= opposite_best_price;
                    if ((b_working_is_buy ? ask_grant_b : bid_grant_b)) begin
                        b_state <= kBMatchWait;
                    end
                end

                kBMatchWait: begin
                    if (b_working_is_buy && ask_response_valid) begin
                        if (ask_response_quantity != {kQuantityWidth{1'b0}}) begin
                            trade_valid            <= 1'b1;
                            trade_price            <= b_working_trade_price;
                            trade_quantity         <= ask_response_quantity;
                            trade_side             <= 1'b0;
                            last_executed_price       <= b_working_trade_price << kTickShiftBits;
                            last_executed_price_valid <= 1'b1;
                            b_working_remaining    <= b_working_remaining - ask_response_quantity;
                            b_packet_trade_count   <= b_packet_trade_count + 1'b1;
                            b_packet_fill_quantity <= b_packet_fill_quantity + ask_response_quantity;
                        end
                        b_state <= kBMatchCheck;
                    end else if (!b_working_is_buy && bid_response_valid) begin
                        if (bid_response_quantity != {kQuantityWidth{1'b0}}) begin
                            trade_valid            <= 1'b1;
                            trade_price            <= b_working_trade_price;
                            trade_quantity         <= bid_response_quantity;
                            trade_side             <= 1'b1;
                            last_executed_price       <= b_working_trade_price << kTickShiftBits;
                            last_executed_price_valid <= 1'b1;
                            b_working_remaining    <= b_working_remaining - bid_response_quantity;
                            b_packet_trade_count   <= b_packet_trade_count + 1'b1;
                            b_packet_fill_quantity <= b_packet_fill_quantity + bid_response_quantity;
                        end
                        b_state <= kBMatchCheck;
                    end
                end

                kBHandoff: begin
                    // Waits for the B-to-C register to drain, then returns to idle. The B-to-C block writes the
                    // register on the same cycle and flags fully consumed packets via b_to_c_for_insert = 0.
                    if (!b_to_c_valid) begin
                        b_state <= kBIdle;
                    end
                end

                default: begin
                    b_state <= kBIdle;
                end
            endcase
        end
    end

    // Manages the B-to-C handoff register. Stage B writes on handoff; Stage C clears on retire. Co-locating both
    // writes in one block prevents a race between the two stages.
    always @(posedge clk) begin
        if (!rst_n) begin
            b_to_c_valid         <= 1'b0;
            b_to_c_for_insert    <= 1'b0;
            b_to_c_price         <= {kPriceWidth{1'b0}};
            b_to_c_remaining     <= {kQuantityWidth{1'b0}};
            b_to_c_is_buy        <= 1'b0;
            b_to_c_trade_count   <= {kQuantityWidth{1'b0}};
            b_to_c_fill_quantity <= {kQuantityWidth{1'b0}};
				b_to_c_agent_type    <= 2'b00;
        end else begin
            // Clears the register on the retire-only path the cycle Stage C enters kCSettle.
            if ((c_state == kCIdle) && b_to_c_valid && !b_to_c_for_insert) begin
                b_to_c_valid <= 1'b0;
            end
            // Clears the register on the insert path the cycle Stage C observes response_valid.
            if ((c_state == kCWait) && (b_to_c_is_buy ? bid_response_valid : ask_response_valid)) begin
                b_to_c_valid <= 1'b0;
            end
            // Writes Stage B's working packet into the register on the cycle it leaves kBHandoff.
            if ((b_state == kBHandoff) && !b_to_c_valid) begin
                b_to_c_valid         <= 1'b1;
                b_to_c_for_insert    <= !b_working_is_market &&
                                        (b_working_remaining != {kQuantityWidth{1'b0}});
                b_to_c_price         <= b_working_price;
                b_to_c_remaining     <= b_working_remaining;
                b_to_c_is_buy        <= b_working_is_buy;
                b_to_c_trade_count   <= b_packet_trade_count;
                b_to_c_fill_quantity <= b_packet_fill_quantity;
            end
        end
    end

    // Drives Stage C's substate machine and the order_retire_valid pulse, exporting one clean snapshot point per
    // retired packet for the TB to log against.
    always @(posedge clk) begin
        if (!rst_n) begin
            c_state                    <= kCIdle;
            order_retire_valid         <= 1'b0;
            order_retire_trade_count   <= {kQuantityWidth{1'b0}};
            order_retire_fill_quantity <= {kQuantityWidth{1'b0}};
				order_retire_agent_type 	<= 2'b00;
        end else begin
            order_retire_valid <= 1'b0;

            case (c_state)
                kCIdle: begin
                    if (b_to_c_valid && !b_to_c_for_insert) begin
                        c_state <= kCSettle;
                    end else if (b_to_c_valid && b_to_c_for_insert) begin
                        c_state <= kCDrive;
                    end
                end

                kCDrive: begin
                    if ((b_to_c_is_buy ? bid_grant_c : ask_grant_c)) begin
                        c_state <= kCWait;
                    end
                end

                kCWait: begin
                    if (b_to_c_is_buy ? bid_response_valid : ask_response_valid) begin
                        c_state <= kCSettle;
                    end
                end

                kCSettle: begin
                    order_retire_valid         <= 1'b1;
                    order_retire_trade_count   <= b_to_c_trade_count;
                    order_retire_fill_quantity <= b_to_c_fill_quantity;
						  order_retire_agent_type <= b_to_c_agent_type;
                    c_state                    <= kCIdle;
                end

                default: c_state <= kCIdle;
            endcase
        end
    end

endmodule
