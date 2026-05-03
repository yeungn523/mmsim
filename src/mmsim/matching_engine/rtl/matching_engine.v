`timescale 1ns/1ns

// Matches order packets across two no-cancellation price level stores in a three-stage pipeline:
// Stage A latches a packet, Stage B runs the match loop driving CONSUMEs and emitting trade pulses,
// Stage C INSERTs any unmatched limit remainder. The B-to-C handoff lets B start the next packet
// while C is still committing the previous one.
//
// Order packet layout (must match agent_execution_unit.v):
//   bit  [31]       side        (0 = buy, 1 = sell)
//   bit  [30]       order_type  (0 = limit, 1 = market)
//   bits [29:28]    agent_type  (unused by the engine)
//   bits [27:25]    reserved
//   bits [24:16]    price       (9-bit tick index, 0..kPriceRange-1)
//   bits [15:0]     volume      (16-bit unsigned share count)

module matching_engine #(
    parameter kPriceWidth      = 32,
    parameter kQuantityWidth   = 16,
    parameter kPriceRange      = 480,
    // Shifts a tick left to expose last_executed_price as Q8.24.
    parameter kTickShiftBits   = 23
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Latches on accepted handshake when Stage B is idle and the prior packet has fully retired.
    input  wire [31:0]                 order_packet,
    input  wire                        order_valid,
    output wire                        order_ready,

    // Pulses once per filled price level. trade_side: 0 = buy aggressor, 1 = sell aggressor.
    output reg  [kPriceWidth-1:0]      trade_price,
    output reg  [kQuantityWidth-1:0]   trade_quantity,
    output reg                         trade_side,
    output reg                         trade_valid,

    // Holds the most recent fill price as Q8.24 unsigned to match the agent unit's contract.
    output reg  [kPriceWidth-1:0]      last_executed_price,
    output reg                         last_executed_price_valid,

    // Exposes top-of-book taps from each store.
    output wire [kPriceWidth-1:0]      best_bid_price,
    output wire [kQuantityWidth-1:0]   best_bid_quantity,
    output wire                        best_bid_valid,
    output wire [kPriceWidth-1:0]      best_ask_price,
    output wire [kQuantityWidth-1:0]   best_ask_quantity,
    output wire                        best_ask_valid,

    // Pulses once per packet retired through Stage C with that packet's exact trade aggregates.
    output reg                         order_retire_valid,
    output reg  [kQuantityWidth-1:0]   order_retire_trade_count,
    output reg  [kQuantityWidth-1:0]   order_retire_fill_quantity,

    // Forwards the VGA depth-read tap to both books; adds one cycle of staleness to best_quantity.
    input  wire [8:0]                  depth_rd_addr,
    output wire [kQuantityWidth-1:0]   bid_depth_rd_data,
    output wire [kQuantityWidth-1:0]   ask_depth_rd_data,

	 output reg [1:0] order_retire_agent_type
);

    // Book command opcodes (must match price_level_store).
    localparam [1:0] kCommandNop     = 2'd0;
    localparam [1:0] kCommandInsert  = 2'd1;
    localparam [1:0] kCommandConsume = 2'd2;

    // Stage B substates.
    localparam [2:0] kBIdle       = 3'd0;
    localparam [2:0] kBClassify   = 3'd1;
    localparam [2:0] kBMatchCheck = 3'd2;
    localparam [2:0] kBMatchExec  = 3'd3;
    localparam [2:0] kBMatchWait  = 3'd4;
    localparam [2:0] kBHandoff    = 3'd5;

    // Stage C substates.
    localparam [1:0] kCIdle   = 2'd0;
    localparam [1:0] kCDrive  = 2'd1;
    localparam [1:0] kCWait   = 2'd2;
    localparam [1:0] kCSettle = 2'd3;

    // Tracks Stage B's working packet and per-fill share remainder.
    reg [2:0]                   b_state;
    reg                         b_working_is_buy;
    reg                         b_working_is_market;
    reg [kPriceWidth-1:0]       b_working_price;
    reg [kQuantityWidth-1:0]    b_working_remaining;
    reg [kPriceWidth-1:0]       b_working_trade_price;

    // Accumulates per-packet trade aggregates and copies them into the B-to-C register at handoff.
    reg [kQuantityWidth-1:0]    b_packet_trade_count;
    reg [kQuantityWidth-1:0]    b_packet_fill_quantity;

    // Holds one packet's tail data while Stage C commits, decoupling Stage B for the next packet.
    // b_to_c_for_insert: 1 = Stage C must INSERT, 0 = retire only.
    reg                         b_to_c_valid;
    reg                         b_to_c_for_insert;
    reg [kPriceWidth-1:0]       b_to_c_price;
    reg [kQuantityWidth-1:0]    b_to_c_remaining;
    reg                         b_to_c_is_buy;
    reg [kQuantityWidth-1:0]    b_to_c_trade_count;
    reg [kQuantityWidth-1:0]    b_to_c_fill_quantity;

    reg [1:0]                   c_state;

    // Wires Stage B and C onto both book stores through the bus mux below.
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

    // Blocks a duplicate command on either book until the store reasserts command_ready.
    reg                         bid_in_flight;
    reg                         ask_in_flight;

	 reg [1:0] b_working_agent_type;
	 reg [1:0] b_to_c_agent_type;

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

    // Holds the upstream FIFO until Stage B is idle and the prior packet has retired through Stage C.
    assign order_ready = (b_state == kBIdle) && !b_to_c_valid;
    wire   accept_packet = order_valid && order_ready;

    // Decodes the boundary packet; producer holds these bits stable while order_valid is high.
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


    // Routes B's CONSUMEs and C's INSERTs; C wins ties since it is draining an older packet.
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

    // Drives Stage B's FSM and the trade bus; Stage B is the sole writer of every trade output.
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
//            last_executed_price    <= {kPriceWidth{1'b0}};
			   last_executed_price       <= 32'h64000000;
            last_executed_price_valid <= 1'b0;

            bid_in_flight <= 1'b0;
            ask_in_flight <= 1'b0;
				
        end else begin
            trade_valid <= 1'b0;

            if (bid_in_flight && bid_command_ready) bid_in_flight <= 1'b0;
            if (ask_in_flight && ask_command_ready) ask_in_flight <= 1'b0;

            if (bid_grant_c || bid_grant_b) bid_in_flight <= 1'b1;
            if (ask_grant_c || ask_grant_b) ask_in_flight <= 1'b1;

            case (b_state)
                kBIdle: begin
                    // order_ready already serializes B with C, so kBClassify sees coherent best_* values.
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
                    // Market and crossing-limit packets enter the match loop; non-crossing limits go to handoff.
                    if (b_working_is_market) begin
                        b_state <= kBMatchCheck;
                    end else if (opposite_best_valid && b_limit_crosses) begin
                        b_state <= kBMatchCheck;
                    end else begin
                        b_state <= kBHandoff;
                    end
                end

                kBMatchCheck: begin
                    // Exits when filled, opposite empty, or next-best price no longer crosses (limits only).
                    if (b_working_remaining == {kQuantityWidth{1'b0}}) begin
                        b_state <= kBHandoff;
                    end else if (!b_can_match) begin
                        b_state <= kBHandoff;
                    end else begin
                        b_state <= kBMatchExec;
                    end
                end

                kBMatchExec: begin
                    // Latches the fill price and waits for the bus grant; stalls if C holds the same store.
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
                    // Waits for the B-to-C register to drain; the handoff block writes it the same cycle.
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

    // Manages the B-to-C handoff register; one block prevents a race between the writers.
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
            // Clears on retire-only path when C enters kCSettle.
            if ((c_state == kCIdle) && b_to_c_valid && !b_to_c_for_insert) begin
                b_to_c_valid <= 1'b0;
            end
            // Clears on insert path when C observes response_valid.
            if ((c_state == kCWait) && (b_to_c_is_buy ? bid_response_valid : ask_response_valid)) begin
                b_to_c_valid <= 1'b0;
            end
            // Writes the working packet on the cycle B leaves kBHandoff.
            if ((b_state == kBHandoff) && !b_to_c_valid) begin
                b_to_c_valid         <= 1'b1;
                b_to_c_for_insert    <= !b_working_is_market &&
                                        (b_working_remaining != {kQuantityWidth{1'b0}});
                b_to_c_price         <= b_working_price;
                b_to_c_remaining     <= b_working_remaining;
                b_to_c_is_buy        <= b_working_is_buy;
                b_to_c_trade_count   <= b_packet_trade_count;
                b_to_c_fill_quantity <= b_packet_fill_quantity;
					 b_to_c_agent_type    <= b_working_agent_type;
            end
        end
    end

    // Drives Stage C's FSM and the order_retire_valid pulse, exporting one snapshot per retired packet.
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
