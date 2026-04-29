`timescale 1ns/1ns

///
/// @file circular_buffer.v
/// @brief Rolling 320-entry chart history feeding the VGA price line.
///

module circular_buffer #(
    parameter integer DEPTH       = 320,                ///< Number of trades retained on the chart.
    parameter integer PIXEL_BITS  = 9,                  ///< Width of the stored pixel-Y value.
    parameter integer PIXEL_Y_TOP = 32,                 ///< First active row below the text strip.
    parameter integer PIXEL_Y_BOT = 479,                ///< Last visible row.
    parameter [31:0]  PRICE_MIN   = 32'h60000000,       ///< Lower bound of the chart price window (Q8.24).
    parameter [31:0]  PRICE_MAX   = 32'h68000000        ///< Upper bound of the chart price window (Q8.24).
)(
    // Write side runs on the matching engine's 50 MHz domain.
    input  wire                     wr_clk,             ///< CLOCK_50.
    input  wire                     rst_n,              ///< Active-low asynchronous reset.
    input  wire                     wr_en,              ///< Pulses on me_trade_valid; advances the head.
    input  wire [31:0]              wr_price,           ///< Q8.24 price at the executing trade.

    // Read side runs on the 25 MHz pixel clock used by vga_driver.
    input  wire                     rd_clk,             ///< vga_pll pixel clock.
    input  wire [$clog2(DEPTH)-1:0] rd_offset,          ///< 0 = newest sample, DEPTH-1 = oldest.
    output reg  [PIXEL_BITS-1:0]    rd_pixel_y          ///< Stored pixel-Y for the requested sample.
);

    localparam integer ADDR_BITS  = $clog2(DEPTH);
    localparam integer Y_RANGE    = PIXEL_Y_BOT - PIXEL_Y_TOP;
    localparam [31:0]  PRICE_SPAN = PRICE_MAX - PRICE_MIN;

    // Maps a Q8.24 price to a row in [PIXEL_Y_TOP, PIXEL_Y_BOT]. Higher prices sit closer to the
    // top of the screen because pixel-Y grows downward, so the offset is inverted before output.
    function [PIXEL_BITS-1:0] price_to_pixel_y;
        input [31:0] price;
        reg   [31:0] clipped;
        reg   [31:0] offset;
        reg   [63:0] scaled;
        begin
            if (price <= PRICE_MIN)      clipped = PRICE_MIN;
            else if (price >= PRICE_MAX) clipped = PRICE_MAX;
            else                         clipped = price;
            offset = clipped - PRICE_MIN;
            scaled = (offset * Y_RANGE) / PRICE_SPAN;
            price_to_pixel_y = PIXEL_Y_BOT[PIXEL_BITS-1:0] - scaled[PIXEL_BITS-1:0];
        end
    endfunction

    // Simple dual-port M10K with separate write/read clocks. The no_rw_check hint relaxes the
    // read-during-write semantics so Quartus is free to map the array onto a single block memory
    // rather than splitting it into logic flops.
    reg [PIXEL_BITS-1:0] mem [0:DEPTH-1] /* synthesis ramstyle = "no_rw_check, M10K" */;

    // Tracks the next slot to overwrite; head_ptr - 1 - rd_offset (mod DEPTH) is the read address.
    reg [ADDR_BITS-1:0] head_ptr;

    // Pre-fills the buffer at the chart midline so the first frame after reset shows a flat line
    // rather than uninitialized contents.
    integer init_iterator;
    initial begin
        for (init_iterator = 0; init_iterator < DEPTH; init_iterator = init_iterator + 1) begin
            mem[init_iterator] = (PIXEL_Y_TOP + PIXEL_Y_BOT) / 2;
        end
        head_ptr = {ADDR_BITS{1'b0}};
    end

    // Captures one new sample per trade pulse. The head wraps naturally because DEPTH is a
    // power of two by design and ADDR_BITS is sized to it.
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= {ADDR_BITS{1'b0}};
        end else if (wr_en) begin
            mem[head_ptr] <= price_to_pixel_y(wr_price);
            head_ptr      <= head_ptr + 1'b1;
        end
    end

    // Holds the offset-into-history → memory-address arithmetic on the read side. Reading
    // head_ptr from the pixel-clock domain is a CDC; head_ptr only changes on trade events
    // (sub-kHz rate vs 25 MHz reads), so the worst case is one stale row per refresh window.
    wire [ADDR_BITS-1:0] rd_addr = head_ptr - {{(ADDR_BITS-1){1'b0}}, 1'b1} - rd_offset;

    // Drives the registered read on the pixel clock; one cycle of latency is fine because the
    // renderer feeds next_x for the upcoming pixel, not the current one.
    always @(posedge rd_clk) begin
        rd_pixel_y <= mem[rd_addr];
    end

endmodule
