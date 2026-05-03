`timescale 1ns/1ps

// Pins price_level_store at kPriceRange=480 for synthesis.

module price_level_quartus #(
    parameter kPriceWidth    = 32,
    parameter kQuantityWidth = 16,
    parameter kIsBid         = 1,
    parameter kPriceRange    = 480
)(
    input  wire                        clk,
    input  wire                        rst_n,

    input  wire [1:0]                  command,
    input  wire [kPriceWidth-1:0]      command_price,
    input  wire [kQuantityWidth-1:0]   command_quantity,
    input  wire                        command_valid,
    output reg                         command_ready_o,

    output reg  [kQuantityWidth-1:0]   response_quantity_o,
    output reg                         response_valid_o,

    output reg  [kPriceWidth-1:0]      best_price_o,
    output reg  [kQuantityWidth-1:0]   best_quantity_o,
    output reg                         best_valid_o
);

    reg [1:0]                  command_q;
    reg [kPriceWidth-1:0]      command_price_q;
    reg [kQuantityWidth-1:0]   command_quantity_q;
    reg                        command_valid_q;

    always @(posedge clk) begin
        command_q          <= command;
        command_price_q    <= command_price;
        command_quantity_q <= command_quantity;
        command_valid_q    <= command_valid;
    end

    wire                       command_ready_w;
    wire [kQuantityWidth-1:0]  response_quantity_w;
    wire                       response_valid_w;
    wire [kPriceWidth-1:0]     best_price_w;
    wire [kQuantityWidth-1:0]  best_quantity_w;
    wire                       best_valid_w;

    price_level_store #(
        .kPriceWidth    (kPriceWidth),
        .kQuantityWidth (kQuantityWidth),
        .kIsBid         (kIsBid),
        .kPriceRange    (kPriceRange)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .command           (command_q),
        .command_price     (command_price_q),
        .command_quantity  (command_quantity_q),
        .command_valid     (command_valid_q),
        .command_ready     (command_ready_w),
        .response_quantity (response_quantity_w),
        .response_valid    (response_valid_w),
        .best_price        (best_price_w),
        .best_quantity     (best_quantity_w),
        .best_valid        (best_valid_w)
    );

    always @(posedge clk) begin
        command_ready_o     <= command_ready_w;
        response_quantity_o <= response_quantity_w;
        response_valid_o    <= response_valid_w;
        best_price_o        <= best_price_w;
        best_quantity_o     <= best_quantity_w;
        best_valid_o        <= best_valid_w;
    end

endmodule
