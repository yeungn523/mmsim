// order_arbiter.v
// Round-robin arbiter: NUM_UNITS agent units -> 1 FIFO write port
// Advances grant pointer only on successful grant
// Halts on fifo_almost_full as safety rail
module order_arbiter #(
    parameter NUM_UNITS  = 16,
    parameter PTR_WIDTH  = 4  
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [NUM_UNITS-1:0]      order_valid_in,
    input  wire [NUM_UNITS*32-1:0]   order_packet_in,  
    output reg  [NUM_UNITS-1:0]      order_granted,
    output reg                       fifo_wr_en,
    output reg  [31:0]               fifo_din,
    input  wire                      fifo_almost_full,  
    input  wire                      fifo_full          
);

    reg [PTR_WIDTH-1:0] grant_ptr;
    reg [PTR_WIDTH-1:0] scan_idx;

    reg                  found;
    reg [PTR_WIDTH-1:0]  next_grant;
    integer i;

    always @(*) begin
        found      = 1'b0;
        next_grant = grant_ptr;
        scan_idx   = 'd0;       
        for (i = 0; i < NUM_UNITS; i = i + 1) begin
            if (!found) begin
                scan_idx = (grant_ptr + i[PTR_WIDTH-1:0]) & {PTR_WIDTH{1'b1}};
                if (order_valid_in[scan_idx]) begin
                    next_grant = scan_idx;
                    found      = 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_ptr     <= 'd0;
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
                    grant_ptr                 <= (next_grant + 1) & {PTR_WIDTH{1'b1}};
                end
            end
        end
    end

endmodule