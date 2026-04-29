`timescale 1ns/1ns

///
/// @file renderer.v
/// @brief Combinational RGB332 pixel renderer for the mmsim VGA visualization.
///
/// Splits the 640x480 active region in half horizontally:
/// Columns 0..319  : rolling price chart fed by circular_buffer. One column per stored sample, so the 320-deep
///                   history maps 1:1 onto the chart width with no resampling.                    
/// Columns 320..639: bid/ask depth histogram fed by the matching engine's price level stores. Each row is one
///                   $0.50 tick, so the full 480-tick book is visible vertically. Bar length per row is proportional
///                   to the resting quantity.

module renderer (
    input  wire [9:0]  next_x,                ///< Pixel column the driver wants colored (0..639).
    input  wire [9:0]  next_y,                ///< Pixel row the driver wants colored.

    // Chart history side -- circular_buffer.
    output wire [8:0]  rd_offset,             ///< 0 = newest window, 319 = oldest.
    input  wire [8:0]  rd_top_pixel_y,        ///< Pixel-Y of the window max price (top of the high-low bar).
    input  wire [8:0]  rd_bottom_pixel_y,     ///< Pixel-Y of the window min price (bottom of the high-low bar).

    // Depth strip side -- matching_engine.
    output wire [8:0]  depth_rd_addr,         ///< Tick index 0..479 currently being queried.
    input  wire [15:0] bid_depth_rd_data,     ///< Resting bid quantity at depth_rd_addr.
    input  wire [15:0] ask_depth_rd_data,     ///< Resting ask quantity at depth_rd_addr.

    output wire [7:0]  color_in               ///< RGB332 color for the upcoming pixel.
);

    localparam [9:0] kChartEndCol    = 10'd319;
    localparam [9:0] kDepthStartCol  = 10'd320;
    localparam [9:0] kDepthBarMax    = 10'd319;   ///< Cap on bar length in pixels (depth region width).
    localparam [8:0] kPixelYBottom   = 9'd479;    ///< Bottom-most active row.

    // Selects the chart region for the left half of the screen and the depth region for the right.
    wire in_chart = (next_x <= kChartEndCol);

    // Maps column N to history slot N so the 320-deep buffer fills the chart width 1:1.
    assign rd_offset = next_x[8:0];

    // Splits each chart column into three vertical bands: dim blue background above the window's max, the high-low span
    // drawn in the line color (collapses to a single pixel when min == max), and a dim amber shadow below the min.
    wire [8:0] chart_y    = next_y[8:0];
    wire       above_span = (chart_y <  rd_top_pixel_y);
    wire       in_span    = (chart_y >= rd_top_pixel_y) && (chart_y <= rd_bottom_pixel_y);

    localparam [7:0] kColorChartBg     = 8'b000_000_01;  ///< Very dim blue (kept for contrast).
    localparam [7:0] kColorChartLine   = 8'b111_100_00;  ///< Bloomberg amber (R=7, G=4, B=0).
    localparam [7:0] kColorChartFilled = 8'b011_010_00;  ///< Dim amber, the span's shadow.

    wire [7:0] chart_color = above_span ? kColorChartBg     :
                             in_span    ? kColorChartLine   :
                                          kColorChartFilled;

    // Maps row N to tick (479 - N) so the highest-priced tick sits at the top of the screen and the lowest at the bottom.
    assign depth_rd_addr = kPixelYBottom - next_y[8:0];

    // Picks whichever side has nonzero quantity at this tick; bids and asks never coexist on the same level under the
    // matching engine's no-cancellation invariant, so the choice is unambiguous and yields a clean two-color ladder.
    wire        depth_is_bid = (bid_depth_rd_data != 16'd0);
    wire [15:0] depth_value  = depth_is_bid ? bid_depth_rd_data : ask_depth_rd_data;

    // Scales the 16-bit quantity into a bar length in [0, 319] by dropping the bottom six bits, then saturates at the
    // depth-region width so heavy levels fill rather than wrap around.
    wire [9:0] bar_raw    = depth_value[15:6];
    wire [9:0] bar_pixels = (bar_raw > kDepthBarMax) ? kDepthBarMax : bar_raw;

    // Measures the offset into the depth region; bar_filled is true while the pixel falls within the scaled bar length.
    wire [9:0] depth_x    = next_x - kDepthStartCol;
    wire       bar_filled = (depth_x < bar_pixels);

    localparam [7:0] kColorDepthBg = 8'b000_000_00;  ///< Black background.
    localparam [7:0] kColorBidBar  = 8'b000_111_00;  ///< Bright green.
    localparam [7:0] kColorAskBar  = 8'b111_000_00;  ///< Bright red.

    wire [7:0] depth_color = bar_filled ? (depth_is_bid ? kColorBidBar : kColorAskBar)
                                        : kColorDepthBg;

    assign color_in = in_chart ? chart_color : depth_color;

endmodule
