///
/// @file order_arbiter.v
/// @brief Round-robin arbiter that funnels NUM_UNITS agent unit packets onto a single valid/ready bus.
///

module order_arbiter #(
    parameter NUM_UNITS  = 16,                           ///< Number of upstream agent units feeding the arbiter.
    parameter PTR_WIDTH  = 4                             ///< Bit width of the round-robin pointer (log2 of NUM_UNITS).
)(
    input  wire                      clk,                ///< System clock.
    input  wire                      rst_n,              ///< Active-low asynchronous reset.
    input  wire [NUM_UNITS-1:0]      order_valid_in,     ///< Per-unit order_valid request lines.
    input  wire [NUM_UNITS*32-1:0]   order_packet_in,    ///< Concatenated 32-bit packets, one per unit.
    output reg  [NUM_UNITS-1:0]      order_granted,      ///< One-hot grant pulse returned to the granted unit on accepted handshake.
    output wire [31:0]               order_packet,       ///< Selected packet driven onto the downstream bus.
    output wire                      order_valid,        ///< Asserts when a granted unit is presenting a packet.
    input  wire                      order_ready         ///< Consumer accepts the packet when high alongside order_valid.
);

    reg [PTR_WIDTH-1:0] grant_pointer;
    reg [PTR_WIDTH-1:0] scan_index;
    reg [PTR_WIDTH-1:0] next_grant;
    reg                 found;
    integer             i;
    integer             j;

    // Drives the bus combinationally; the agent module holds order_valid_in[next_grant] high
    // until the grant pulse returns, so the data path needs no internal register.
    assign order_valid  = found;
    assign order_packet = order_packet_in[next_grant*32 +: 32];

    // Scans the units in round-robin order and selects the lowest-index unit asserting
    // order_valid_in.
    always @(*) begin
        found      = 1'b0;
        next_grant = grant_pointer;
        scan_index = 'd0;
        for (i = 0; i < NUM_UNITS; i = i + 1) begin
            if (!found) begin
                scan_index = (grant_pointer + i[PTR_WIDTH-1:0]) & {PTR_WIDTH{1'b1}};
                if (order_valid_in[scan_index]) begin
                    next_grant = scan_index;
                    found      = 1'b1;
                end
            end
        end
    end

    // Pulses order_granted[next_grant] only on the cycle the downstream consumer accepts.
    always @(*) begin
        order_granted = {NUM_UNITS{1'b0}};
        if (found && order_ready) begin
            for (j = 0; j < NUM_UNITS; j = j + 1) begin
                if (j[PTR_WIDTH-1:0] == next_grant) begin
                    order_granted[j] = 1'b1;
                end
            end
        end
    end

    // Advances grant_pointer past the just-accepted unit so the next scan starts from the slot
    // after it.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_pointer <= 'd0;
        end else if (found && order_ready) begin
            grant_pointer <= (next_grant + 1'b1) & {PTR_WIDTH{1'b1}};
        end
    end

endmodule
