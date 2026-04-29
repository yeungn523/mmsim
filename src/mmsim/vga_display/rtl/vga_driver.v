`timescale 1ns/1ns

///
/// @file vga_driver.v
/// @brief 640x480@60Hz VGA timing generator with a registered RGB332 color path.
///
/// Walks the screen at the 25.175 MHz pixel clock and presents next_x, next_y to the
/// downstream renderer one cycle ahead of the pixel they describe. The renderer reacts
/// combinationally and feeds color_in back; this module then registers the color into the
/// red/green/blue outputs aligned with hsync/vsync. Outside the active region the color
/// outputs hold zero so the display blanks cleanly during front porch, sync pulse, and
/// back porch.
///

module vga_driver (
    input  wire       clock,                                     ///< 25.175 MHz VGA pixel clock.
    input  wire       reset,                                     ///< Active-high synchronous reset.
    input  wire [7:0] color_in,                                  ///< RGB332 color from the renderer (3R, 3G, 2B).

    output wire [9:0] next_x,                                    ///< Pixel column the renderer should color (0..639).
    output wire [9:0] next_y,                                    ///< Pixel row the renderer should color (0..479).

    output wire       hsync,                                     ///< Horizontal sync, active low during the pulse window.
    output wire       vsync,                                     ///< Vertical sync, active low during the pulse window.
    output wire [7:0] red,                                       ///< 8-bit red channel to the DAC.
    output wire [7:0] green,                                     ///< 8-bit green channel to the DAC.
    output wire [7:0] blue,                                      ///< 8-bit blue channel to the DAC.
    output wire       sync,                                      ///< Composite sync, tied low (DE1-SoC ignores).
    output wire       clk,                                       ///< Pixel clock to the DAC.
    output wire       blank                                      ///< Active-low blanking; high while inside hsync/vsync windows.
);

    // Encodes the standard VGA 640x480@60 timing as the count of clock cycles spent in each
    // horizontal phase and the number of full horizontal lines spent in each vertical phase.
    parameter [9:0] H_ACTIVE = 10'd639;
    parameter [9:0] H_FRONT  = 10'd15;
    parameter [9:0] H_PULSE  = 10'd95;
    parameter [9:0] H_BACK   = 10'd47;

    parameter [9:0] V_ACTIVE = 10'd479;
    parameter [9:0] V_FRONT  = 10'd9;
    parameter [9:0] V_PULSE  = 10'd1;
    parameter [9:0] V_BACK   = 10'd32;

    parameter LOW  = 1'b0;
    parameter HIGH = 1'b1;

    parameter [7:0] H_ACTIVE_STATE = 8'd0;
    parameter [7:0] H_FRONT_STATE  = 8'd1;
    parameter [7:0] H_PULSE_STATE  = 8'd2;
    parameter [7:0] H_BACK_STATE   = 8'd3;

    parameter [7:0] V_ACTIVE_STATE = 8'd0;
    parameter [7:0] V_FRONT_STATE  = 8'd1;
    parameter [7:0] V_PULSE_STATE  = 8'd2;
    parameter [7:0] V_BACK_STATE   = 8'd3;

    // Holds the registered sync, color, and end-of-line strobe. line_done pulses on the last
    // back-porch cycle so the vertical state machine advances in lockstep with horizontal wraps.
    reg       hsync_reg;
    reg       vsync_reg;
    reg [7:0] red_reg;
    reg [7:0] green_reg;
    reg [7:0] blue_reg;
    reg       line_done;

    reg [9:0] h_counter;
    reg [9:0] v_counter;
    reg [7:0] h_state;
    reg [7:0] v_state;

    always @(posedge clock) begin
        if (reset) begin
            h_counter <= 10'd0;
            v_counter <= 10'd0;
            h_state   <= H_ACTIVE_STATE;
            v_state   <= V_ACTIVE_STATE;
            line_done <= LOW;
        end else begin
            // Horizontal scan walks ACTIVE → FRONT → PULSE → BACK and back to ACTIVE; each phase
            // owns its dwell counter and wraps when the count hits its terminal parameter.
            if (h_state == H_ACTIVE_STATE) begin
                h_counter <= (h_counter == H_ACTIVE) ? 10'd0 : (h_counter + 10'd1);
                hsync_reg <= HIGH;
                line_done <= LOW;
                h_state   <= (h_counter == H_ACTIVE) ? H_FRONT_STATE : H_ACTIVE_STATE;
            end
            if (h_state == H_FRONT_STATE) begin
                h_counter <= (h_counter == H_FRONT) ? 10'd0 : (h_counter + 10'd1);
                hsync_reg <= HIGH;
                h_state   <= (h_counter == H_FRONT) ? H_PULSE_STATE : H_FRONT_STATE;
            end
            if (h_state == H_PULSE_STATE) begin
                h_counter <= (h_counter == H_PULSE) ? 10'd0 : (h_counter + 10'd1);
                hsync_reg <= LOW;
                h_state   <= (h_counter == H_PULSE) ? H_BACK_STATE : H_PULSE_STATE;
            end
            if (h_state == H_BACK_STATE) begin
                h_counter <= (h_counter == H_BACK) ? 10'd0 : (h_counter + 10'd1);
                hsync_reg <= HIGH;
                h_state   <= (h_counter == H_BACK) ? H_ACTIVE_STATE : H_BACK_STATE;
                line_done <= (h_counter == (H_BACK - 10'd1)) ? HIGH : LOW;
            end

            // Vertical scan only advances on line_done so it tracks completed scanlines rather
            // than pixel columns.
            if (v_state == V_ACTIVE_STATE) begin
                v_counter <= (line_done == HIGH) ? ((v_counter == V_ACTIVE) ? 10'd0 : (v_counter + 10'd1)) : v_counter;
                vsync_reg <= HIGH;
                v_state   <= (line_done == HIGH) ? ((v_counter == V_ACTIVE) ? V_FRONT_STATE : V_ACTIVE_STATE) : V_ACTIVE_STATE;
            end
            if (v_state == V_FRONT_STATE) begin
                v_counter <= (line_done == HIGH) ? ((v_counter == V_FRONT) ? 10'd0 : (v_counter + 10'd1)) : v_counter;
                vsync_reg <= HIGH;
                v_state   <= (line_done == HIGH) ? ((v_counter == V_FRONT) ? V_PULSE_STATE : V_FRONT_STATE) : V_FRONT_STATE;
            end
            if (v_state == V_PULSE_STATE) begin
                v_counter <= (line_done == HIGH) ? ((v_counter == V_PULSE) ? 10'd0 : (v_counter + 10'd1)) : v_counter;
                vsync_reg <= LOW;
                v_state   <= (line_done == HIGH) ? ((v_counter == V_PULSE) ? V_BACK_STATE : V_PULSE_STATE) : V_PULSE_STATE;
            end
            if (v_state == V_BACK_STATE) begin
                v_counter <= (line_done == HIGH) ? ((v_counter == V_BACK) ? 10'd0 : (v_counter + 10'd1)) : v_counter;
                vsync_reg <= HIGH;
                v_state   <= (line_done == HIGH) ? ((v_counter == V_BACK) ? V_ACTIVE_STATE : V_BACK_STATE) : V_BACK_STATE;
            end

            // Expands the RGB332 color_in into the DAC's 8-bit channels and forces zero whenever
            // the scan is outside the active rectangle so the display blanks during sync/porch.
            red_reg   <= (h_state == H_ACTIVE_STATE) ? ((v_state == V_ACTIVE_STATE) ? {color_in[7:5], 5'd0} : 8'd0) : 8'd0;
            green_reg <= (h_state == H_ACTIVE_STATE) ? ((v_state == V_ACTIVE_STATE) ? {color_in[4:2], 5'd0} : 8'd0) : 8'd0;
            blue_reg  <= (h_state == H_ACTIVE_STATE) ? ((v_state == V_ACTIVE_STATE) ? {color_in[1:0], 6'd0} : 8'd0) : 8'd0;
        end
    end

    // Exposes the upcoming pixel coordinates to the renderer. Both go to zero outside the active
    // window so the renderer doesn't produce garbage during blanking.
    assign next_x = (h_state == H_ACTIVE_STATE) ? h_counter : 10'd0;
    assign next_y = (v_state == V_ACTIVE_STATE) ? v_counter : 10'd0;

    assign hsync = hsync_reg;
    assign vsync = vsync_reg;
    assign red   = red_reg;
    assign green = green_reg;
    assign blue  = blue_reg;
    assign clk   = clock;
    assign sync  = 1'b0;
    assign blank = hsync_reg & vsync_reg;

endmodule
