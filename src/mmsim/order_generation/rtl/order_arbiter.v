// Funnels NUM_UNITS agent packets onto a single valid/ready bus through round-robin arbitration.

module order_arbiter #(
    parameter NUM_UNITS  = 16,
    parameter PTR_WIDTH  = 4
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [NUM_UNITS-1:0]      order_valid_in,
    input  wire [NUM_UNITS*32-1:0]   order_packet_in,
    output reg  [NUM_UNITS-1:0]      order_granted,
    output wire [31:0]               order_packet,
    output wire                      order_valid,
    input  wire                      order_ready
);

    reg [PTR_WIDTH-1:0] grant_pointer;
    reg [PTR_WIDTH-1:0] scan_index;
    reg [PTR_WIDTH-1:0] next_grant;
    reg                 found;
    integer             i;
    integer             j;

    // Drives the bus combinationally; agents hold order_valid_in[next_grant] until the grant returns.
    assign order_valid  = found;
    assign order_packet = order_packet_in[next_grant*32 +: 32];

    // Scans round-robin and picks the lowest-index requester past grant_pointer.
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

    // Pulses order_granted[next_grant] only when the consumer accepts.
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

    // Advances grant_pointer past the just-accepted unit for the next scan.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_pointer <= 'd0;
        end else if (found && order_ready) begin
            grant_pointer <= (next_grant + 1'b1) & {PTR_WIDTH{1'b1}};
        end
    end

endmodule
