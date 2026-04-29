`timescale 1ns/1ns

///
/// @file circular_buffer.v
/// @brief Caches the most recent DEPTH wall-clock windows as pre-mapped (top, bottom) pixel-Y pairs for the VGA chart.

module circular_buffer #(
    parameter integer DEPTH       = 320,                ///< Number of windows retained.
    parameter integer PIXEL_BITS  = 9,                  ///< Bit width of each cached pixel-Y value.
    parameter integer PIXEL_Y_TOP = 32,                 ///< First active pixel row below the text strip.
    parameter integer PIXEL_Y_BOT = 479,                ///< Last visible pixel row of the chart region.
    parameter [31:0]  PRICE_MIN   = 32'h60000000,       ///< Lower bound of the price window (Q8.24).
    parameter [31:0]  PRICE_MAX   = 32'h68000000        ///< Upper bound of the price window (Q8.24).
)(
    input  wire                     wr_clk,             ///< 50 MHz matching engine clock (CLOCK_50).
    input  wire                     rst_n,              ///< Active-low asynchronous reset.
    input  wire                     wr_en,              ///< Asserts for one cycle per closed window.
    input  wire [31:0]              wr_min_price,       ///< Window minimum trade price (Q8.24).
    input  wire [31:0]              wr_max_price,       ///< Window maximum trade price (Q8.24).

    input  wire                     rd_clk,             ///< 25 MHz VGA pixel clock from vga_pll.
    input  wire [$clog2(DEPTH)-1:0] rd_offset,          ///< Sample age: 0 = newest, DEPTH-1 = oldest.
    output reg  [PIXEL_BITS-1:0]    rd_top_pixel_y,     ///< Pixel-Y of the window max (top of the high-low bar).
    output reg  [PIXEL_BITS-1:0]    rd_bottom_pixel_y   ///< Pixel-Y of the window min (bottom of the high-low bar).
);

    localparam integer ADDR_BITS  = $clog2(DEPTH);
    localparam integer Y_RANGE    = PIXEL_Y_BOT - PIXEL_Y_TOP;
    localparam [31:0]  PRICE_SPAN = PRICE_MAX - PRICE_MIN;
    localparam integer SLOT_BITS  = 2 * PIXEL_BITS;

    // Maps a Q8.24 price to a chart pixel-Y row, inverting the offset so higher prices land at the top of the screen.
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

    // Holds {top_pixel_y, bottom_pixel_y} per slot in a single M10K so each chart column gets the high-low pair.
    reg [SLOT_BITS-1:0] mem [0:DEPTH-1] /* synthesis ramstyle = "no_rw_check, M10K" */;

    // Points at the next slot to overwrite; head_ptr - 1 - rd_offset (mod DEPTH) is the read address.
    reg [ADDR_BITS-1:0] head_ptr;

    // Pre-fills the buffer at the chart midline (top == bottom == midline) so the first frame after reset renders flat.
    localparam [PIXEL_BITS-1:0] kMidlineY = (PIXEL_Y_TOP + PIXEL_Y_BOT) / 2;
    integer init_iterator;
    initial begin
        for (init_iterator = 0; init_iterator < DEPTH; init_iterator = init_iterator + 1) begin
            mem[init_iterator] = {kMidlineY, kMidlineY};
        end
        head_ptr = {ADDR_BITS{1'b0}};
    end

    // Maps the window's max price to the smallest pixel-Y (top of the bar) and min price to the largest (bottom).
    wire [PIXEL_BITS-1:0] wr_top_pixel_y    = price_to_pixel_y(wr_max_price);
    wire [PIXEL_BITS-1:0] wr_bottom_pixel_y = price_to_pixel_y(wr_min_price);

    // Captures one (top, bottom) pair per closed window; the head wraps naturally since DEPTH is a power of two.
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= {ADDR_BITS{1'b0}};
        end else if (wr_en) begin
            mem[head_ptr] <= {wr_top_pixel_y, wr_bottom_pixel_y};
            head_ptr      <= head_ptr + 1'b1;
        end
    end

    // Reads head_ptr unsynchronized from the pixel-clock domain. Window writes run at sub-kHz versus 25 MHz reads,
    // so the worst case is one stale row per frame.
    wire [ADDR_BITS-1:0] rd_addr = head_ptr - {{(ADDR_BITS-1){1'b0}}, 1'b1} - rd_offset;

    // Tolerates one-cycle read latency because the renderer feeds next_x for the upcoming pixel.
    always @(posedge rd_clk) begin
        {rd_top_pixel_y, rd_bottom_pixel_y} <= mem[rd_addr];
    end

endmodule
