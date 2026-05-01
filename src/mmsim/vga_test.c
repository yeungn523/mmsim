///////////////////////////////////////////////////////////////////////////////
// vga_test.c
// compile: gcc vga_test.c -o vga_test -O2 -lm -std=c99
// run:     sudo ./vga_test
///////////////////////////////////////////////////////////////////////////////
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

#define SDRAM_BASE     0xC0000000
#define SDRAM_SPAN     0x04000000
#define FPGA_CHAR_BASE 0xC9000000
#define FPGA_CHAR_SPAN 0x00002000

#define _BSD_SOURCE

#define RGB(r,g,b)   ((short)(((r)<<11)|((g)<<5)|(b)))
#define black        RGB(0,  0,  0)
#define bright_green RGB(0,  50, 0)
#define dim_green    RGB(0,  25, 0)
#define bright_red   RGB(28, 0,  0)
#define dim_red      RGB(14, 0,  0)
#define yellow       RGB(31, 63, 0)
#define gray         RGB(6,  12, 6)
#define dark_gray    RGB(2,  4,  2)
// Trader type colors
#define col_noise    RGB(8,  16, 8)   // dark gray-green: noise traders
#define col_mm       RGB(0,  20, 28)  // dark cyan: market makers
#define col_momentum RGB(28, 20, 0)   // dark orange: momentum traders
#define col_value    RGB(4,  0,  20)  // dark purple: value investors

// ============================================================
// Layout
// Top bar:          y 0-39,   full width
// Left panel:       x 0-319,  y 40-479  candlesticks
// Right top panel:  x 320-639 y 40-259  depth histogram  (220px tall)
// Right bot panel:  x 320-639 y 260-479 trader composition (220px tall)
// ============================================================
#define BAR_H         40
#define CHART_Y0      BAR_H
#define CHART_H       440

#define CANDLE_X0     0
#define CANDLE_W      320

#define DEPTH_X0      320
#define DEPTH_W       320
#define DEPTH_Y0      CHART_Y0          // 40
#define DEPTH_H       330
#define DEPTH_Y1      (DEPTH_Y0 + DEPTH_H - 1)   // 369

#define COMP_X0       320
#define COMP_W        320
#define COMP_Y0       370
#define COMP_H        110
#define COMP_Y1       (COMP_Y0 + COMP_H - 1)     // 479

// Candle geometry
#define BODY_W            5
#define GAP               1
#define SLOT              (BODY_W + GAP)
#define MAX_CANDLES       (CANDLE_W / SLOT)
#define TICKS_PER_CANDLE  10

// Depth binning — now mapped to DEPTH_H (220px) not full CHART_H
#define DEPTH_BIN_SIZE    4
#define DEPTH_BINS        (400 / DEPTH_BIN_SIZE)   // 100
#define DEPTH_PRICE_MAX   399

// Trader composition chart
#define COMP_LABEL_W      40                              // 4 chars wide on right
#define COMP_COL_W        8
#define COMP_MAX_COLS     ((COMP_W - COMP_LABEL_W) / COMP_COL_W)   // 36 columns
#define NUM_TRADER_TYPES  4

#define CANDLE_TOP_MARGIN 0.20
#define CANDLE_BOT_MARGIN 0.10

#define NUM_LEVELS 400
static uint32_t ob_mem[1024];
#define OB_BUY(i)   ob_mem[i]
#define OB_SELL(i)  ob_mem[400+(i)]
#define OB_EXEC     ob_mem[800]
#define OB_BEST_BID ob_mem[801]
#define OB_BEST_ASK ob_mem[802]
#define OB_VOLUME   ob_mem[803]
#define OB_FRAME    ob_mem[804]

typedef struct { uint32_t open, close, high, low; int green; } Candle;
static Candle   candles[MAX_CANDLES];
static int      candle_count = 0;
static int      candle_head  = 0;
static uint32_t cur_open = 0, cur_high = 0, cur_low = UINT32_MAX, cur_close = 0;
static int      window_tick = 0;
static uint32_t open_price  = 200;
static uint32_t last_frame  = 0xFFFFFFFF;
static int      axis_min    = 150;
static int      axis_max    = 250;

// Y axis label tracking
static int last_label_rows[20];
static int last_label_count = 0;

// Trader composition history — each entry is 4 fractions summing to 256
// stored as uint8 proportions (0-255) per trader type per time slot
static uint8_t comp_hist[COMP_MAX_COLS][NUM_TRADER_TYPES];
static int     comp_head  = 0;
static int     comp_count = 0;

volatile unsigned int *vga_pixel_ptr = NULL;
void                  *vga_pixel_virtual_base;
volatile unsigned int *vga_char_ptr  = NULL;
void                  *vga_char_virtual_base;
int fd;

#define VGA_PIXEL(x, y, color) \
    do { \
        int *_p = (int *)((char *)vga_pixel_ptr + (((y)*640+(x))<<1)); \
        *(short *)_p = (color); \
    } while(0)

void VGA_hline(int x1, int x2, int y, short c) {
    int x;
    if (y < 0 || y > 479) return;
    if (x1 < 0) x1 = 0; if (x2 > 639) x2 = 639;
    for (x = x1; x <= x2; x++) VGA_PIXEL(x, y, c);
}
void VGA_vline(int x, int y1, int y2, short c) {
    int y;
    if (x < 0 || x > 639) return;
    if (y1 < 0) y1 = 0; if (y2 > 479) y2 = 479;
    for (y = y1; y <= y2; y++) VGA_PIXEL(x, y, c);
}
void VGA_box(int x1, int y1, int x2, int y2, short c) {
    int x, y;
    if (x1 < 0) x1=0; if (y1 < 0) y1=0;
    if (x2 > 639) x2=639; if (y2 > 479) y2=479;
    for (y = y1; y <= y2; y++)
        for (x = x1; x <= x2; x++)
            VGA_PIXEL(x, y, c);
}
void VGA_dashed_hline(int x1, int x2, int y, short c) {
    int x;
    if (y < 0 || y > 479) return;
    if (x1 < 0) x1=0; if (x2 > 639) x2=639;
    for (x = x1; x <= x2; x++)
        if ((x >> 2) & 1) VGA_PIXEL(x, y, c);
}
void VGA_text(int x, int y, char *s) {
    volatile char *cb = (char *)vga_char_ptr;
    int off = (y << 7) + x;
    while (*s) cb[off++] = *s++;
}
void VGA_text_clear(void) {
    int x, y;
    volatile char *cb = (char *)vga_char_ptr;
    for (y = 0; y < 60; y++)
        for (x = 0; x < 80; x++)
            cb[(y << 7) + x] = ' ';
}

// Candle panel: dynamic axis
static inline int candle_price_to_y(int price) {
    int range = axis_max - axis_min;
    int y;
    if (range <= 0) return CHART_Y0 + CHART_H / 2;
    y = CHART_Y0 + CHART_H - 1
        - ((price - axis_min) * (CHART_H - 1)) / range;
    if (y < CHART_Y0) y = CHART_Y0;
    if (y > 479)      y = 479;
    return y;
}

// Depth panel: fixed 0-399 mapped into DEPTH_H pixels
static inline int depth_price_to_y(int price) {
    int y = DEPTH_Y0 + DEPTH_H - 1
            - (price * (DEPTH_H - 1)) / DEPTH_PRICE_MAX;
    if (y < DEPTH_Y0) y = DEPTH_Y0;
    if (y > DEPTH_Y1) y = DEPTH_Y1;
    return y;
}

void update_axis(void) {
    int i, idx, vis_min, vis_max, range, new_min, new_max, min_diff, max_diff;
    int n = candle_count;
    vis_min = 999; vis_max = 0;
    if (n < 1) { axis_min = 0; axis_max = 399; return; }
    for (i = 0; i < n; i++) {
        idx = (candle_head - n + i + MAX_CANDLES) % MAX_CANDLES;
        if ((int)candles[idx].low  < vis_min) vis_min = (int)candles[idx].low;
        if ((int)candles[idx].high > vis_max) vis_max = (int)candles[idx].high;
    }
    if (window_tick > 0) {
        if ((int)cur_low  < vis_min) vis_min = (int)cur_low;
        if ((int)cur_high > vis_max) vis_max = (int)cur_high;
    }
    range = vis_max - vis_min;
    if (range < 10) range = 10;
    {
        double total_range = range / (1.0 - CANDLE_TOP_MARGIN - CANDLE_BOT_MARGIN);
        new_min = (int)(vis_min - total_range * CANDLE_BOT_MARGIN);
        new_max = (int)(new_min + total_range);
    }
    min_diff = new_min - axis_min;
    max_diff = new_max - axis_max;
    if (min_diff != 0 && min_diff > -8 && min_diff < 8)
        axis_min += (min_diff > 0) ? 1 : -1;
    else
        axis_min += min_diff / 8;
    if (max_diff != 0 && max_diff > -8 && max_diff < 8)
        axis_max += (max_diff > 0) ? 1 : -1;
    else
        axis_max += max_diff / 8;
    if (axis_min < -50)  axis_min = -50;
    if (axis_max > 450)  axis_max = 450;
    if (axis_max - axis_min < 10) axis_max = axis_min + 10;
}

// ============================================================
// Dummy data — also generates fake trader composition per candle
// ============================================================
static double mid   = 200.0;
static double trend = 0.0;

void dummy_tick(void) {
    int d, mp, exec, bp, ap, qty;
    trend += ((double)rand()/RAND_MAX - 0.5) * 0.4;
    trend *= 0.90;
    mid   += trend + ((double)rand()/RAND_MAX - 0.5) * 1.8;
    if (mid < 30)  { mid = 30;  trend =  1.0; }
    if (mid > 370) { mid = 370; trend = -1.0; }
    mp = (int)round(mid);
    memset(ob_mem, 0, sizeof(uint32_t) * 800);
    for (d = 1; d <= 40; d++) {
        qty = (int)((40 - d * 0.65) * (0.5 + (double)rand()/RAND_MAX) * 2.8);
        if (qty < 1) qty = 1;
        bp = mp - d; ap = mp + d;
        if (bp >= 0 && bp < NUM_LEVELS) ob_mem[bp]       = (uint32_t)qty;
        if (ap >= 0 && ap < NUM_LEVELS) ob_mem[400 + ap] = (uint32_t)qty;
    }
    if (rand()%35==0) { int w=mp-(3+rand()%10); if(w>=0&&w<NUM_LEVELS) ob_mem[w]+=60+rand()%100; }
    if (rand()%35==0) { int w=mp+(3+rand()%10); if(w>=0&&w<NUM_LEVELS) ob_mem[400+w]+=60+rand()%100; }
    exec = mp + (rand()%3) - 1;
    if (exec < 0) exec = 0;
    if (exec >= NUM_LEVELS) exec = NUM_LEVELS - 1;
    OB_EXEC     = (uint32_t)exec;
    OB_BEST_BID = (uint32_t)(mp - 1);
    OB_BEST_ASK = (uint32_t)(mp + 1);
    OB_VOLUME++;
    OB_FRAME++;
}

void update_candle(void) {
    uint32_t price = OB_EXEC;
    if (window_tick == 0) { cur_open = price; cur_high = price; cur_low = price; }
    if (price > cur_high) cur_high = price;
    if (price < cur_low)  cur_low  = price;
    cur_close = price;
    if (++window_tick >= TICKS_PER_CANDLE) {
        Candle c;
        c.open  = cur_open;  c.close = cur_close;
        c.high  = cur_high;  c.low   = cur_low;
        c.green = (cur_close >= cur_open);
        candles[candle_head] = c;
        candle_head = (candle_head + 1) % MAX_CANDLES;
        if (candle_count < MAX_CANDLES) candle_count++;
        window_tick = 0;
        cur_high = 0; cur_low = UINT32_MAX;

        // Push a new trader composition column — dummy random for now
        // Replace these four values with real agent trade counts from ob_mem
        {
            int r0 = 40 + rand()%40;   // noise
            int r1 = 30 + rand()%40;   // market makers
            int r2 = 20 + rand()%40;   // momentum
            int r3 = 10 + rand()%40;   // value
            int total = r0 + r1 + r2 + r3;
            comp_hist[comp_head][0] = (uint8_t)(r0 * 255 / total);
            comp_hist[comp_head][1] = (uint8_t)(r1 * 255 / total);
            comp_hist[comp_head][2] = (uint8_t)(r2 * 255 / total);
            comp_hist[comp_head][3] = 255 - comp_hist[comp_head][0]
                                          - comp_hist[comp_head][1]
                                          - comp_hist[comp_head][2];
            comp_head = (comp_head + 1) % COMP_MAX_COLS;
            if (comp_count < COMP_MAX_COLS) comp_count++;
        }
    }
}

void render_topbar(void) {
    char buf[80];
    uint32_t exec = OB_EXEC;
    uint32_t bid  = OB_BEST_BID;
    uint32_t ask  = OB_BEST_ASK;
    uint32_t vol  = OB_VOLUME;
    int sprd      = (int)ask - (int)bid;
    int pct10     = (int)((int)(exec - open_price) * 1000
                          / (int)(open_price ? open_price : 1));
    VGA_text(1, 1, "NASDAQ:VHA");
    sprintf(buf, "LAST:%-3u  %+d.%01d%%   ", exec, pct10/10, abs(pct10%10));
    VGA_text(14, 1, buf);
    sprintf(buf, "BID:%-3u  ASK:%-3u  SPR:%d  VOL:%-7u", bid, ask, sprd, vol);
    VGA_text(1, 2, buf);
}

void render_candles(void) {
    int i, idx, x, y, g;
    char buf[8];
    int grid_step, grid_start, grid_p, n, start_x;
    int new_label_rows[20];
    int new_label_count = 0;

    // Erase old grid labels — shifted to char col 1 to avoid overscan clip
    for (i = 0; i < last_label_count; i++)
        VGA_text(1, last_label_rows[i], "   ");

    int grid_y_lines[20];
    int grid_line_count = 0;
    {
        int range = axis_max - axis_min;
        if      (range < 20)  grid_step = 5;
        else if (range < 50)  grid_step = 10;
        else if (range < 100) grid_step = 20;
        else if (range < 200) grid_step = 50;
        else                  grid_step = 100;
        grid_start = ((axis_min / grid_step) + 1) * grid_step;
        for (grid_p = grid_start; grid_p < axis_max; grid_p += grid_step) {
            int gy = candle_price_to_y(grid_p);
            if (grid_line_count < 20) {
                grid_y_lines[grid_line_count++] = gy;
                sprintf(buf, "%3d", grid_p);
                int crow = gy >> 3;
                // Write at col 1 not col 0 — avoids overscan cutoff
                VGA_text(1, crow, buf);
                if (new_label_count < 20) new_label_rows[new_label_count++] = crow;
            }
        }
    }
    for (i = 0; i < new_label_count; i++) last_label_rows[i] = new_label_rows[i];
    last_label_count = new_label_count;

    n       = candle_count;
    start_x = (n < MAX_CANDLES) ? CANDLE_X0 : CANDLE_X0 + CANDLE_W - n * SLOT;

    int c_high[MAX_CANDLES], c_low[MAX_CANDLES], c_top[MAX_CANDLES], c_bot[MAX_CANDLES];
    short c_body_col[MAX_CANDLES], c_wick_col[MAX_CANDLES];
    for (i = 0; i < n; i++) {
        idx = (candle_head - n + i + MAX_CANDLES) % MAX_CANDLES;
        Candle *c = &candles[idx];
        c_high[i] = candle_price_to_y((int)c->high);
        c_low[i]  = candle_price_to_y((int)c->low);
        int y_open  = candle_price_to_y((int)c->open);
        int y_close = candle_price_to_y((int)c->close);
        c_top[i] = (y_open < y_close) ? y_open : y_close;
        c_bot[i] = (y_open > y_close) ? y_open : y_close;
        if (c_top[i] == c_bot[i]) c_bot[i] = c_top[i] + 1;
        c_body_col[i] = c->green ? dim_green    : dim_red;
        c_wick_col[i] = c->green ? bright_green : bright_red;
    }
    int exec_y = candle_price_to_y((int)OB_EXEC);

    // Row-major render
    for (y = CHART_Y0; y <= 479; y++) {
        int is_grid = 0;
        for (g = 0; g < grid_line_count; g++)
            if (y == grid_y_lines[g]) { is_grid = 1; break; }

        for (x = CANDLE_X0; x < CANDLE_X0 + CANDLE_W - 1; x++) {
            short col = black;
            if (y == exec_y && ((x >> 2) & 1)) {
                col = yellow;
            } else {
                int slot_i = (x - start_x) / SLOT;
                int slot_x = (x - start_x) % SLOT;
                if (n > 0 && slot_i >= 0 && slot_i < n && slot_x < BODY_W) {
                    if (y >= c_high[slot_i] && y <= c_low[slot_i]) {
                        if (y >= c_top[slot_i] && y <= c_bot[slot_i])
                            col = c_body_col[slot_i];
                        else if (slot_x == BODY_W / 2)
                            col = c_wick_col[slot_i];
                    }
                }
                if (col == black && is_grid) col = dark_gray;
            }
            VGA_PIXEL(x, y, col);
        }
    }
    VGA_vline(CANDLE_X0 + CANDLE_W - 1, CHART_Y0, 479, gray);
}

// Depth histogram — top-right panel, fixed 0-399 axis, DEPTH_H tall
// Row-major render with intentional 1px black gap between bins
void render_depth(void) {
    int b, p, y, x;
    uint32_t max_qty = 1;
    int half = DEPTH_W / 2;
    static uint32_t bin_bid[DEPTH_BINS];
    static uint32_t bin_ask[DEPTH_BINS];

    for (b = 0; b < DEPTH_BINS; b++) {
        uint32_t bq = 0, aq = 0;
        for (p = 0; p < DEPTH_BIN_SIZE; p++) {
            int level = b * DEPTH_BIN_SIZE + p;
            bq += OB_BUY(level);
            aq += OB_SELL(level);
        }
        bin_bid[b] = bq;
        bin_ask[b] = aq;
        if (bq > max_qty) max_qty = bq;
        if (aq > max_qty) max_qty = aq;
    }

    // Stop at DEPTH_Y1 - 1 so divider line at DEPTH_Y1 is never overwritten
    for (y = DEPTH_Y0; y <= DEPTH_Y1 - 1; y++) {
        // bin_row: 0 = highest price (top of panel), DEPTH_BINS-1 = lowest (bottom)
        int bin_row = ((y - DEPTH_Y0) * DEPTH_BINS) / DEPTH_H;
        if (bin_row < 0 || bin_row >= DEPTH_BINS) {
            VGA_hline(DEPTH_X0, DEPTH_X0 + DEPTH_W - 1, y, black);
            continue;
        }

        // Bins are indexed from top: bin 0 = highest price level
        // Flip so bin 0 = price 396-399, bin 99 = price 0-3
        int price_bin = (DEPTH_BINS - 1) - bin_row;
        uint32_t bq = bin_bid[price_bin];
        uint32_t aq = bin_ask[price_bin];

        // Bid side
        if (bq > 0) {
            int bar_w = (int)((double)bq / max_qty * half);
            if (bar_w < 1) bar_w = 1;
            if (bar_w > half) bar_w = half;
            
            // DYNAMIC COLOR: Volume-weighted Green (0-63 scale)
            // Base intensity is 15, scales up to 63 based on relative volume
            int g_val = 15 + (int)(((uint64_t)bq * 48) / max_qty);
            short bid_col = RGB(0, g_val, 0);

            // erase left then draw bar
            for (x = DEPTH_X0; x < DEPTH_X0 + half; x++)
                VGA_PIXEL(x, y, (x >= DEPTH_X0 + half - bar_w) ? bid_col : black);
        } else {
            VGA_hline(DEPTH_X0, DEPTH_X0 + half - 1, y, black);
        }

        // Ask side
        if (aq > 0) {
            int bar_w = (int)((double)aq / max_qty * half);
            if (bar_w < 1) bar_w = 1;
            if (bar_w > half) bar_w = half;

            // DYNAMIC COLOR: Volume-weighted Red (0-31 scale)
            // Base intensity is 8, scales up to 31 based on relative volume
            int r_val = 8 + (aq * 23) / max_qty;
            short ask_col = RGB(r_val, 0, 0);

            for (x = DEPTH_X0 + half; x < DEPTH_X0 + DEPTH_W; x++)
                VGA_PIXEL(x, y, (x < DEPTH_X0 + half + bar_w) ? ask_col : black);
        } else {
            VGA_hline(DEPTH_X0 + half, DEPTH_X0 + DEPTH_W - 1, y, black);
        }
    }
}

// Trader composition chart — bottom-right panel
// Scrolling stacked 100% bar, one column per candle, newest on right
// 4 trader types: noise(gray-green), MM(cyan), momentum(orange), value(purple)
void render_comp(void) {
    int col, x, y;
    int n = comp_count;
    static const short trader_colors[NUM_TRADER_TYPES] = {
        col_noise, col_mm, col_momentum, col_value
    };

    // Row-major: for each row in comp panel, for each x pixel
    for (y = COMP_Y0; y <= COMP_Y1; y++) {
        // Normalize y to 0-255 within panel (0=bottom=255, top=0)
        int y_frac = ((COMP_Y1 - y) * 255) / (COMP_H - 1);

        for (x = COMP_X0; x < COMP_X0 + COMP_W; x++) {
            // Which column slot is this x in?
            int slot = (x - COMP_X0) / COMP_COL_W;
            int slot_x = (x - COMP_X0) % COMP_COL_W;

            // 1px vertical separator between columns — draw black
            if (slot_x == COMP_COL_W - 1) {
                VGA_PIXEL(x, y, black);
                continue;
            }

            if (slot >= n) {
                VGA_PIXEL(x, y, black);
                continue;
            }

            // Map slot to history index — oldest on left, newest on right
            int hist_idx = (comp_head - n + slot + COMP_MAX_COLS) % COMP_MAX_COLS;

            // Stack the four trader proportions bottom to top
            // Each proportion is 0-255, they sum to 255
            int cumulative = 0;
            short col_color = black;
            int t;
            for (t = 0; t < NUM_TRADER_TYPES; t++) {
                cumulative += comp_hist[hist_idx][t];
                if (y_frac <= cumulative) {
                    col_color = trader_colors[t];
                    break;
                }
            }
            VGA_PIXEL(x, y, col_color);
        }
    }

    // Static label row at top of comp panel — drawn once in main
}

int main(void) {
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd == -1) { perror("open /dev/mem"); return 1; }

    vga_char_virtual_base = mmap(NULL, FPGA_CHAR_SPAN,
                                 PROT_READ|PROT_WRITE, MAP_SHARED, fd, FPGA_CHAR_BASE);
    if (vga_char_virtual_base == MAP_FAILED) { perror("mmap char"); close(fd); return 1; }
    vga_char_ptr = (unsigned int *)vga_char_virtual_base;

    vga_pixel_virtual_base = mmap(NULL, SDRAM_SPAN,
                                  PROT_READ|PROT_WRITE, MAP_SHARED, fd, SDRAM_BASE);
    if (vga_pixel_virtual_base == MAP_FAILED) { perror("mmap pixel"); close(fd); return 1; }
    vga_pixel_ptr = (unsigned int *)vga_pixel_virtual_base;

    VGA_box(0, 0, 639, 479, black);
    VGA_text_clear();

    // Static elements drawn once — never redrawn in loop
    VGA_hline(0, 639, BAR_H - 1, gray);              // top bar border
    VGA_hline(DEPTH_X0, DEPTH_X0 + DEPTH_W - 1, COMP_Y0 - 1, gray);
    VGA_vline(DEPTH_X0 + DEPTH_W / 2,
              DEPTH_Y0, DEPTH_Y1, gray);              // depth center spine

    // Depth axis labels on far right — fixed prices, drawn once
    {
        char buf[8];
        int prices[4] = {100, 200, 300, 399};
        int i;
        for (i = 0; i < 4; i++) {
            int gy = depth_price_to_y(prices[i]);
            sprintf(buf, "%-3d", prices[i]);
            VGA_text(76, gy >> 3, buf);
        }
    }

    {
        // Vertically stacked labels in the right-hand strip of the comp panel
        // Order matches bar stacking: trader type 3 (value) at top, 0 (noise) at bottom
        // 4 labels across COMP_H pixels = one label every COMP_H/4 rows
        static const char *trader_names_top_to_bot[4] = {"VAL", "MOM", "MM ", "NSE"};
        int t;
        int label_char_col = ((COMP_X0 + COMP_W - COMP_LABEL_W) >> 3) + 1;  // char col of strip
        {
            int label_rows[4] = {47, 50, 53, 56};
            for (t = 0; t < 4; t++)
                VGA_text(label_char_col, label_rows[t], (char *)trader_names_top_to_bot[t]);
        }
    }

    memset(ob_mem, 0, sizeof(ob_mem));
    OB_EXEC     = 200;
    OB_BEST_BID = 199;
    OB_BEST_ASK = 201;
    open_price  = 200;
    last_label_count = 0;
    comp_head  = 0;
    comp_count = 0;
    memset(comp_hist, 0, sizeof(comp_hist));

    printf("Running. Ctrl+C to exit.\n");

    while (1) {
        dummy_tick();
        if (OB_FRAME == last_frame) { usleep(1000); continue; }
        last_frame = OB_FRAME;
        update_candle();
        update_axis();
        render_topbar();
        render_candles();
        render_depth();
        render_comp();
        usleep(80000);
    }
    return 0;
}
