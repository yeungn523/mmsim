module quartus_price (
    input  wire       clk,      ///< Accepts the board clock.
    input  wire       rst_n,    ///< Accepts the synchronous active-low reset.
    output wire       led       ///< Drives an anti-pruning output sink for the DUT's outputs.
);

    // Generates pseudo-random stimulus from a 32-bit Galois LFSR.
    reg [31:0] lfsr;
    always @(posedge clk) begin
        if (!rst_n)
            lfsr <= 32'hDEADBEEF;
        else
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    end

    reg [2:0]  stimulus_command;
    reg [31:0] stimulus_price;
    reg [15:0] stimulus_quantity;
    reg [15:0] stimulus_order_id;
    reg        stimulus_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            stimulus_command  <= 3'd0;
            stimulus_price    <= 32'd0;
            stimulus_quantity <= 16'd0;
            stimulus_order_id <= 16'd0;
            stimulus_valid    <= 1'b0;
        end else begin
            stimulus_command  <= lfsr[2:0];
            stimulus_price    <= {16'd0, lfsr[18:3]};
            stimulus_quantity <= lfsr[25:10];
            stimulus_order_id <= lfsr[31:16];
            stimulus_valid    <= lfsr[7];
        end
    end

    wire        price_level_store_command_ready;
    wire [15:0] price_level_store_response_order_id;
    wire [15:0] price_level_store_response_quantity;
    wire        price_level_store_response_valid;
    wire        price_level_store_response_found;
    wire [31:0] price_level_store_best_price;
    wire [15:0] price_level_store_best_quantity;
    wire        price_level_store_best_valid;
    wire        price_level_store_full;

    (* keep_hierarchy = "yes" *) price_level_store #(
        .kDepth         (16),
        .kMaxOrders     (32),
        .kPriceWidth    (32),
        .kQuantityWidth (16),
        .kOrderIdWidth  (16),
        .kIsBid         (1),
        .kPriceRange    (2048)
    ) price_level_store_instance (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (stimulus_command),
        .command_price     (stimulus_price),
        .command_quantity  (stimulus_quantity),
        .command_order_id  (stimulus_order_id),
        .command_valid     (stimulus_valid),
        .command_ready     (price_level_store_command_ready),
        .response_order_id (price_level_store_response_order_id),
        .response_quantity (price_level_store_response_quantity),
        .response_valid    (price_level_store_response_valid),
        .response_found    (price_level_store_response_found),
        .best_price        (price_level_store_best_price),
        .best_quantity     (price_level_store_best_quantity),
        .best_valid        (price_level_store_best_valid),
        .full              (price_level_store_full)
    );

    // XOR-reduces the DUT outputs into a single registered bit to prevent synthesis pruning.
    wire price_level_store_sink = ^{
        price_level_store_command_ready,
        price_level_store_response_order_id,
        price_level_store_response_quantity,
        price_level_store_response_valid,
        price_level_store_response_found,
        price_level_store_best_price,
        price_level_store_best_quantity,
        price_level_store_best_valid,
        price_level_store_full
    };

    (* keep = 1 *) reg price_level_store_sink_register;

    always @(posedge clk) begin
        price_level_store_sink_register <= price_level_store_sink;
    end

    assign led = price_level_store_sink_register;

endmodule
