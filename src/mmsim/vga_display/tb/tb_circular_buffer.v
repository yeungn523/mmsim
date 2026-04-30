`timescale 1ns/1ns

///
/// @file tb_circular_buffer.v
/// @brief Self-checking test for circular_buffer's wrap math and price-to-pixel mapping.
///
/// Three checks:
///   1. Reset state -- every offset reads the midline pre-fill so the first frame after reset renders flat.
///   2. Boundary clipping -- prices below PRICE_MIN map to PIXEL_Y_BOT, prices above PRICE_MAX map to PIXEL_Y_TOP, and
///      the midline price maps to the midline row.
///   3. Wrap and recency ordering -- after writing N > DEPTH samples, rd_offset=0 returns the newest sample and
///      rd_offset=DEPTH-1 returns the (N-DEPTH)th sample so the chart always shows the most recent window in order.
///
/// ModelSim:
///   vlog circular_buffer.v tb_circular_buffer.v
///   vsim -c -do "run -all; quit -f" tb_circular_buffer
///

module tb_circular_buffer;
    localparam integer kDepth      = 16;          // Small DEPTH so the wrap test runs fast.
    localparam integer kPixelBits  = 9;
    localparam integer kPixelYTop  = 32;
    localparam integer kPixelYBot  = 479;
    localparam [31:0]  kPriceMin   = 32'h60000000;
    localparam [31:0]  kPriceMax   = 32'h68000000;
    localparam [31:0]  kPriceSpan  = kPriceMax - kPriceMin;
    localparam integer kYRange     = kPixelYBot - kPixelYTop;
    localparam [kPixelBits-1:0] kMidlineY = (kPixelYTop + kPixelYBot) / 2;
    localparam integer kClockPeriod = 20;

    reg                       clk;
    reg                       rst_n;
    reg                       wr_en;
    reg  [31:0]               wr_min_price;
    reg  [31:0]               wr_max_price;
    reg  [$clog2(kDepth)-1:0] rd_offset;
    wire [kPixelBits-1:0]     rd_top_pixel_y;
    wire [kPixelBits-1:0]     rd_bottom_pixel_y;

    initial clk = 0;
    always #(kClockPeriod / 2) clk = ~clk;

    circular_buffer #(
        .DEPTH       (kDepth),
        .PIXEL_BITS  (kPixelBits),
        .PIXEL_Y_TOP (kPixelYTop),
        .PIXEL_Y_BOT (kPixelYBot),
        .PRICE_MIN   (kPriceMin),
        .PRICE_MAX   (kPriceMax)
    ) dut (
        .wr_clk            (clk),
        .rst_n             (rst_n),
        .wr_en             (wr_en),
        .wr_min_price      (wr_min_price),
        .wr_max_price      (wr_max_price),
        .rd_clk            (clk),
        .rd_offset         (rd_offset),
        .rd_top_pixel_y    (rd_top_pixel_y),
        .rd_bottom_pixel_y (rd_bottom_pixel_y)
    );

    integer fail_count;

    task check_eq;
        input [31:0] actual;
        input [31:0] expected;
        input [255:0] label;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s -- expected %0d, got %0d", label, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Mirrors the DUT's price_to_pixel_y so the testbench predicts what the buffer should store.
    function [kPixelBits-1:0] expected_pixel_y;
        input [31:0] price;
        reg   [31:0] clipped;
        reg   [31:0] offset;
        reg   [63:0] scaled;
        begin
            if (price <= kPriceMin)      clipped = kPriceMin;
            else if (price >= kPriceMax) clipped = kPriceMax;
            else                         clipped = price;
            offset = clipped - kPriceMin;
            scaled = (offset * kYRange) / kPriceSpan;
            expected_pixel_y = kPixelYBot[kPixelBits-1:0] - scaled[kPixelBits-1:0];
        end
    endfunction

    // Pulses wr_en for one cycle with the supplied min/max prices, advancing head_ptr by one.
    task write_window;
        input [31:0] min_price;
        input [31:0] max_price;
        begin
            @(negedge clk);
            wr_en        = 1'b1;
            wr_min_price = min_price;
            wr_max_price = max_price;
            @(negedge clk);
            wr_en        = 1'b0;
        end
    endtask

    // Drives rd_offset and waits one read clock so rd_top/bottom_pixel_y reflects the addressed slot. The DUT registers
    // the read on rd_clk so a single edge after the address change is sufficient.
    task read_offset;
        input [$clog2(kDepth)-1:0] offset;
        begin
            @(negedge clk);
            rd_offset = offset;
            @(posedge clk);
            #1;
        end
    endtask

    integer i;
    reg [31:0] price_seq [0:99];

    initial begin
        fail_count   = 0;
        rst_n        = 1'b0;
        wr_en        = 1'b0;
        wr_min_price = kPriceMin;
        wr_max_price = kPriceMax;
        rd_offset    = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Test 1: reset pre-fill. Every offset should read the midline pair (top == bottom).
        for (i = 0; i < kDepth; i = i + 1) begin
            read_offset(i[$clog2(kDepth)-1:0]);
            check_eq(rd_top_pixel_y,    {{(32-kPixelBits){1'b0}}, kMidlineY}, "reset top == midline");
            check_eq(rd_bottom_pixel_y, {{(32-kPixelBits){1'b0}}, kMidlineY}, "reset bottom == midline");
        end

        // Test 2: boundary clipping. Writes one window spanning the full price range to probe both ends of the
        // price-to-pixel mapping, then walks across the midline price and out-of-range prices on either side.
        write_window(kPriceMin,             kPriceMax);
        read_offset(0);
        check_eq(rd_top_pixel_y,    expected_pixel_y(kPriceMax), "max -> top pixel_y");
        check_eq(rd_bottom_pixel_y, expected_pixel_y(kPriceMin), "min -> bottom pixel_y");

        write_window(kPriceMin - 32'd1, kPriceMax + 32'd1);
        read_offset(0);
        check_eq(rd_top_pixel_y,    {{(32-kPixelBits){1'b0}}, kPixelYTop[kPixelBits-1:0]},
                 "above-max clips to top");
        check_eq(rd_bottom_pixel_y, {{(32-kPixelBits){1'b0}}, kPixelYBot[kPixelBits-1:0]},
                 "below-min clips to bottom");

        write_window(kPriceMin + (kPriceSpan >> 1), kPriceMin + (kPriceSpan >> 1));
        read_offset(0);
        check_eq(rd_top_pixel_y,    expected_pixel_y(kPriceMin + (kPriceSpan >> 1)),
                 "midline price -> midline pixel_y (top)");
        check_eq(rd_bottom_pixel_y, expected_pixel_y(kPriceMin + (kPriceSpan >> 1)),
                 "midline price -> midline pixel_y (bottom)");

        // Test 3: wrap and recency. Writes 3*kDepth distinct windows so head_ptr wraps multiple times, then verifies
        // offset N reads the (last-1-N)th write so the most recent kDepth samples are visible in recency order.
        for (i = 0; i < 3 * kDepth; i = i + 1) begin
            price_seq[i] = kPriceMin + ((i + 1) * (kPriceSpan / (3 * kDepth + 1)));
            write_window(price_seq[i], price_seq[i]);
        end
        for (i = 0; i < kDepth; i = i + 1) begin
            read_offset(i[$clog2(kDepth)-1:0]);
            check_eq(rd_top_pixel_y,    expected_pixel_y(price_seq[3*kDepth - 1 - i]),
                     "wrap recency top");
            check_eq(rd_bottom_pixel_y, expected_pixel_y(price_seq[3*kDepth - 1 - i]),
                     "wrap recency bottom");
        end

        if (fail_count == 0) $display("=== PASS ===");
        else                 $display("=== FAIL: %0d check(s) failed ===", fail_count);
        $finish;
    end

endmodule
