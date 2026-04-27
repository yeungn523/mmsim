///
/// @file order_arbiter.v
/// @brief Round-robin arbiter that funnels NUM_UNITS agent unit packets into a single FIFO write port.
///

module order_arbiter #(
    parameter NUM_UNITS  = 16,                           ///< Number of upstream agent units feeding the arbiter.
    parameter PTR_WIDTH  = 4                             ///< Bit width of the round-robin pointer (log2 of NUM_UNITS).
)(
    input  wire                      clk,                ///< System clock.
    input  wire                      rst_n,              ///< Active-low asynchronous reset.
    input  wire [NUM_UNITS-1:0]      order_valid_in,     ///< Per-unit order_valid request lines.
    input  wire [NUM_UNITS*32-1:0]   order_packet_in,    ///< Concatenated 32-bit packets, one per unit.
    output reg  [NUM_UNITS-1:0]      order_granted,      ///< One-hot grant pulse returned to the granted unit.
    output reg                       fifo_wr_en,         ///< FIFO write enable, asserted with fifo_din.
    output reg  [31:0]               fifo_din,           ///< Selected packet driven onto the FIFO write port.
    input  wire                      fifo_almost_full,   ///< FIFO almost-full backpressure signal.
    input  wire                      fifo_full           ///< FIFO full backpressure signal.
);

    reg [PTR_WIDTH-1:0] grant_pointer;
    reg [PTR_WIDTH-1:0] scan_index;

    reg                  found;
    reg [PTR_WIDTH-1:0]  next_grant;
    integer i;

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_pointer <= 'd0;
            fifo_wr_en    <= 1'b0;
            fifo_din      <= 32'd0;
            order_granted <= 'd0;
        end else begin
            fifo_wr_en    <= 1'b0;
            order_granted <= 'd0;

            if (!fifo_almost_full && !fifo_full) begin
                if (found) begin
                    fifo_wr_en                <= 1'b1;
                    fifo_din                  <= order_packet_in[next_grant*32 +: 32];
                    order_granted[next_grant] <= 1'b1;
                    grant_pointer             <= (next_grant + 1) & {PTR_WIDTH{1'b1}};
                end
            end
        end
    end

endmodule
