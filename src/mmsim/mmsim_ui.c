///////////////////////////////////////////////////////////////////////////////
// mmsim_ui_debug.c
// compile: gcc -Wall -std=c99 -o mmsim_ui mmsim_ui_debug.c -lm -lrt
// run:     sudo ./mmsim_ui [seed]
//
// Layout matches vga_test.c exactly:
//   Top bar:        y 0-39,   full width    — ticker text
//   Left top:       x 0-319,  y 40-369     — candlestick + area shading
//   Left bot:       x 0-319,  y 370-479    — volume histogram
//   Right top:      x 320-639 y 40-369     — depth of market
//   Right bot:      x 320-639 y 370-479    — trader composition
//
// Debug stdout: one line per second showing FRAME/EXEC/BID/ASK/VOL/DEPTH.
//   FRAME ticking, EXEC=0    -> orders not reaching price_level_store
//   FRAME ticking, EXEC=200  -> trades firing, VGA rendering
//   FRAME=0                  -> AnalogClock / reset problem
///////////////////////////////////////////////////////////////////////////////
#define _GNU_SOURCE
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

// ============================================================
// Memory map
// ============================================================
#define LW_BRIDGE_BASE      0xFF200000
#define LW_BRIDGE_SPAN      0x00200000
#define SDRAM_BASE          0xC0000000
#define SDRAM_SPAN          0x04000000
#define FPGA_CHAR_BASE      0xC9000000
#define FPGA_CHAR_SPAN      0x00002000
#define ORDERBOOK_MEM_BASE  0x00000000
#define NUM_UNITS           16
#define SLOTS_PER_UNIT      1024
#define AGENT_MEM_BASE      0x00010000
#define AGENT_MEM_STRIDE    0x00001000

// ============================================================
// Agent types
// ============================================================
#define TYPE_NOISE    0
#define TYPE_MM       1
#define TYPE_MOMENTUM 2
#define TYPE_VALUE    3

#define PACK_AGENT(type, p1, p2, p3) \
    (((uint32_t)(type & 0x3) << 30) | \
     ((uint32_t)(p1 & 0x3FF) << 20) | \
     ((uint32_t)(p2 & 0x3FF) << 10) | \
     ((uint32_t)(p3 & 0x3FF)))

uint32_t rand_range(uint32_t mn, uint32_t mx) {
    return mn + (rand() % (mx - mn + 1));
}

// ============================================================
// VGA colors
// ============================================================
#define RGB(r,g,b)   ((short)(((r)<<11)|((g)<<5)|(b)))
#define black        RGB(0,  0,  0)
#define bright_green RGB(0,  50, 0)
#define dim_green    RGB(0,  25, 0)
#define bright_red   RGB(28, 0,  0)
#define dim_red      RGB(14, 0,  0)
#define yellow       RGB(31, 63, 0)
#define gray         RGB(6,  12, 6)
#define dark_gray    RGB(2,  4,  2)
#define col_noise    RGB(8,  16, 8)
#define col_mm       RGB(0,  20, 28)
#define col_momentum RGB(28, 20, 0)
#define col_value    RGB(4,  0,  20)

// ============================================================
// Layout — mirrors vga_test.c
// ============================================================
#define BAR_H         40
#define CHART_Y0      BAR_H         // 40
#define CHART_H       330           // candle panel: y 40..369

#define CANDLE_X0     0
#define CANDLE_W      320

// Volume histogram — bottom-left
#define VOL_X0        0
#define VOL_W         CANDLE_W
#define VOL_Y0        370
#define VOL_H         110
#define VOL_Y1        (VOL_Y0 + VOL_H - 1)   // 479

// Depth — top-right
#define DEPTH_X0      320
#define DEPTH_W       320
#define DEPTH_Y0      CHART_Y0      // 40
#define DEPTH_H       330
#define DEPTH_Y1      (DEPTH_Y0 + DEPTH_H - 1)   // 369

// Composition — bottom-right
#define COMP_X0       320
#define COMP_W        320
#define COMP_Y0       370
#define COMP_H        110
#define COMP_Y1       (COMP_Y0 + COMP_H - 1)     // 479

// Candle geometry
#define BODY_W            5
#define GAP               1
#define SLOT              (BODY_W + GAP)
#define MAX_CANDLES       (CANDLE_W / SLOT)        // 53
#define TICKS_PER_CANDLE  10

// Depth binning
#define DEPTH_BIN_SIZE    4
#define DEPTH_BINS        (400 / DEPTH_BIN_SIZE)   // 100
#define DEPTH_PRICE_MAX   399

// Composition chart
#define COMP_LABEL_W      40
#define COMP_COL_W        8
#define COMP_MAX_COLS     ((COMP_W - COMP_LABEL_W) / COMP_COL_W)
#define NUM_TRADER_TYPES  4

#define CANDLE_TOP_MARGIN 0.20
#define CANDLE_BOT_MARGIN 0.10
#define NUM_LEVELS        400

#define Q824_TO_TICK(x)  ((x) >> 23)

// ============================================================
// FPGA orderbook memory
// ============================================================
static volatile uint32_t *fpga_ob = NULL;
static uint32_t ob_mem[1024];

#define OB_BUY(i)    ob_mem[i]
#define OB_SELL(i)   ob_mem[400+(i)]
#define OB_EXEC      ob_mem[800]
#define OB_BEST_BID  ob_mem[801]
#define OB_BEST_ASK  ob_mem[802]
#define OB_VOLUME    ob_mem[803]
#define OB_FRAME     ob_mem[804]
#define OB_NOISE_VOL ob_mem[805]
#define OB_MM_VOL    ob_mem[806]
#define OB_MOM_VOL   ob_mem[807]
#define OB_VALUE_VOL ob_mem[808]

static uint32_t prev_noise_vol = 0;
static uint32_t prev_mm_vol    = 0;
static uint32_t prev_mom_vol   = 0;
static uint32_t prev_value_vol = 0;

// ============================================================
// Candle + volume + composition state
// ============================================================
typedef struct { uint32_t open, close, high, low; int green; } Candle;
static Candle   candles[MAX_CANDLES];
static int      candle_count = 0;
static int      candle_head  = 0;
static uint32_t cur_open = 0, cur_high = 0, cur_low = UINT32_MAX, cur_close = 0;
static int      window_tick  = 0;
static uint32_t open_price   = 200;
static uint32_t last_frame   = 0xFFFFFFFF;
static int      axis_min     = 150;
static int      axis_max     = 250;
static int      last_label_rows[20];
static int      last_label_count = 0;

static uint32_t vol_hist[MAX_CANDLES];
static int      vol_head    = 0;
static int      vol_count   = 0;
static uint32_t vol_max     = 1;
static uint32_t vol_at_open = 0;

static uint8_t comp_hist[COMP_MAX_COLS][NUM_TRADER_TYPES];
static int     comp_head  = 0;
static int     comp_count = 0;

// ============================================================
// Debug state
// ============================================================
static uint32_t debug_last_print_sec = 0;
static uint32_t debug_frame_prev     = 0;
static uint32_t debug_exec_prev      = 0;
static uint32_t debug_vol_prev       = 0;
static int      debug_first_trade    = 0;

// ============================================================
// VGA pointers
// ============================================================
volatile unsigned int *vga_pixel_ptr = NULL;
void                  *vga_pixel_virtual_base;
volatile unsigned int *vga_char_ptr  = NULL;
void                  *vga_char_virtual_base;

// ============================================================
// VGA primitives
// ============================================================
#define VGA_PIXEL(x, y, color) \
    do { \
        int *_p = (int *)((char *)vga_pixel_ptr + (((y)*640+(x))<<1)); \
        *(short *)_p = (color); \
    } while(0)

void VGA_hline(int x1, int x2, int y, short c) {
    int x;
    if (y < 0 || y > 479) return;
    if (x1 < 0) x1=0; if (x2 > 639) x2=639;
    for (x = x1; x <= x2; x++) VGA_PIXEL(x, y, c);
}
void VGA_vline(int x, int y1, int y2, short c) {
    int y;
    if (x < 0 || x > 639) return;
    if (y1 < 0) y1=0; if (y2 > 479) y2=479;
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

// ============================================================
// Read FPGA snapshot
// ============================================================
void read_fpga_snapshot(void) {
    int i;
    for (i = 0; i < 800; i++) ob_mem[i] = fpga_ob[i];
    ob_mem[800] = Q824_TO_TICK(fpga_ob[800]);
    ob_mem[801] = Q824_TO_TICK(fpga_ob[801]);
    ob_mem[802] = Q824_TO_TICK(fpga_ob[802]);
    ob_mem[803] = fpga_ob[803];
    ob_mem[804] = fpga_ob[804];
    ob_mem[805] = fpga_ob[805];
    ob_mem[806] = fpga_ob[806];
    ob_mem[807] = fpga_ob[807];
    ob_mem[808] = fpga_ob[808];
}

// ============================================================
// Debug print — once per second
// ============================================================
void debug_print_status(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint32_t now_sec = (uint32_t)ts.tv_sec;
    if (now_sec == debug_last_print_sec) return;
    debug_last_print_sec = now_sec;

    uint32_t frame = OB_FRAME;
    uint32_t exec  = OB_EXEC;
    uint32_t bid   = OB_BEST_BID;
    uint32_t ask   = OB_BEST_ASK;
    uint32_t vol   = OB_VOLUME;
    int bid_levels = 0, ask_levels = 0, j;
    for (j = 0; j < 400; j++) {
        if (OB_BUY(j)  > 0) bid_levels++;
        if (OB_SELL(j) > 0) ask_levels++;
    }
    int frame_delta = (int)(frame - debug_frame_prev);
    debug_frame_prev = frame;

    const char *exec_flag = "";
    if (exec != 0 && !debug_first_trade) {
        exec_flag = "  <-- FIRST TRADE!"; debug_first_trade = 1;
    } else if (exec != debug_exec_prev) {
        exec_flag = "  <-- price changed";
    }
    debug_exec_prev = exec;
    const char *vol_flag = (vol != debug_vol_prev) ? "  <-- volume up" : "";
    debug_vol_prev = vol;

    printf("[t=%-5u] FRAME=%-8u (+%-4d/s)  EXEC=%-4u%s\n",
           now_sec, frame, frame_delta, exec, exec_flag);
    printf("          BID=%-4u  ASK=%-4u  SPREAD=%d  VOL=%-8u%s\n",
           bid, ask, (ask > bid) ? (int)(ask-bid) : -1, vol, vol_flag);
    printf("          DEPTH: bid_levels=%-3d  ask_levels=%-3d\n",
           bid_levels, ask_levels);
    printf("          RAW[800]=0x%08X  (>>23=%u)\n",
           fpga_ob[800], Q824_TO_TICK(fpga_ob[800]));
    if (frame == 0)
        printf("  !! FRAME=0 — orderbook_writer not running. Check KEY[0].\n");
    else if (frame_delta == 0)
        printf("  !! Frame stalled — FPGA may be in reset.\n");
    else if (exec == 0 && bid_levels == 0 && ask_levels == 0)
        printf("  !! No depth, no exec — BUY never reached price_level_store.\n");
    else if (exec == 0 && (bid_levels > 0 || ask_levels > 0))
        printf("  !! Depth exists but no exec — orders not crossing.\n");
    else if (exec > 0)
        printf("  OK: Trades firing. VGA rendering.\n");
    printf("\n");
    fflush(stdout);
}

// ============================================================
// Coordinate helpers
// ============================================================
static inline int candle_price_to_y(int price) {
    int range = axis_max - axis_min;
    int y;
    if (range <= 0) return CHART_Y0 + CHART_H / 2;
    y = CHART_Y0 + CHART_H - 1 - ((price - axis_min) * (CHART_H - 1)) / range;
    if (y < CHART_Y0) y = CHART_Y0;
    if (y > 479)      y = 479;
    return y;
}
static inline int depth_price_to_y(int price) {
    int y = DEPTH_Y0 + DEPTH_H - 1 - (price * (DEPTH_H - 1)) / DEPTH_PRICE_MAX;
    if (y < DEPTH_Y0) y = DEPTH_Y0;
    if (y > DEPTH_Y1) y = DEPTH_Y1;
    return y;
}

// ============================================================
// Axis update
// ============================================================
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
    else axis_min += min_diff / 8;
    if (max_diff != 0 && max_diff > -8 && max_diff < 8)
        axis_max += (max_diff > 0) ? 1 : -1;
    else axis_max += max_diff / 8;
    if (axis_min < -50)  axis_min = -50;
    if (axis_max > 450)  axis_max = 450;
    if (axis_max - axis_min < 10) axis_max = axis_min + 10;
}

// ============================================================
// Candle update — FPGA exec price, per-candle volume
// ============================================================
void update_candle(void) {
    uint32_t price = OB_EXEC;
    if (price == 0) return;

    if (window_tick == 0) {
        cur_open    = price;
        cur_high    = price;
        cur_low     = price;
        vol_at_open = OB_VOLUME;
    }
    if (price > cur_high) cur_high = price;
    if (price < cur_low)  cur_low  = price;
    cur_close = price;

    if (++window_tick >= TICKS_PER_CANDLE) {
        Candle c;
        c.open = cur_open; c.close = cur_close;
        c.high = cur_high; c.low   = cur_low;
        c.green = (cur_close >= cur_open);
        candles[candle_head] = c;

        // Per-candle volume
        {
            uint32_t candle_vol = OB_VOLUME - vol_at_open;
            vol_hist[candle_head] = candle_vol;
            if (candle_vol >= vol_max) {
                vol_max = candle_vol;
            } else if (vol_count == MAX_CANDLES) {
                int j; vol_max = 1;
                for (j = 0; j < MAX_CANDLES; j++)
                    if (vol_hist[j] > vol_max) vol_max = vol_hist[j];
            }
        }

        // Trader composition
        {
            uint32_t d_noise = OB_NOISE_VOL - prev_noise_vol;
            uint32_t d_mm    = OB_MM_VOL    - prev_mm_vol;
            uint32_t d_mom   = OB_MOM_VOL   - prev_mom_vol;
            uint32_t d_value = OB_VALUE_VOL - prev_value_vol;
            prev_noise_vol = OB_NOISE_VOL;
            prev_mm_vol    = OB_MM_VOL;
            prev_mom_vol   = OB_MOM_VOL;
            prev_value_vol = OB_VALUE_VOL;
            uint32_t total = d_noise + d_mm + d_mom + d_value;
            if (total == 0) {
                memset(comp_hist[comp_head], 0, NUM_TRADER_TYPES);
            } else {
                comp_hist[comp_head][0] = (uint8_t)(d_noise * 255 / total);
                comp_hist[comp_head][1] = (uint8_t)(d_mm    * 255 / total);
                comp_hist[comp_head][2] = (uint8_t)(d_mom   * 255 / total);
                comp_hist[comp_head][3] = 255
                    - comp_hist[comp_head][0]
                    - comp_hist[comp_head][1]
                    - comp_hist[comp_head][2];
            }
        }

        candle_head = (candle_head + 1) % MAX_CANDLES;
        comp_head   = (comp_head   + 1) % COMP_MAX_COLS;
        vol_head    = candle_head;

        if (candle_count < MAX_CANDLES)   candle_count++;
        if (comp_count   < COMP_MAX_COLS) comp_count++;
        if (vol_count    < MAX_CANDLES)   vol_count++;

        window_tick = 0;
        cur_high = 0; cur_low = UINT32_MAX;
    }
}

// ============================================================
// render_topbar
// ============================================================
void render_topbar(void) {
    char buf[80];
    uint32_t exec = OB_EXEC;
    uint32_t bid  = OB_BEST_BID;
    uint32_t ask  = OB_BEST_ASK;
    uint32_t vol  = OB_VOLUME;
    int sprd  = (int)ask - (int)bid;
    int pct10 = (int)((int)(exec - open_price) * 1000
                      / (int)(open_price ? open_price : 1));
    VGA_text(1, 1, "NASDAQ:VHA");
    sprintf(buf, "LAST:%-3u  %+d.%01d%%   ", exec, pct10/10, abs(pct10%10));
    VGA_text(14, 1, buf);
    sprintf(buf, "BID:%-3u  ASK:%-3u  SPR:%d  VOL:%-7u", bid, ask, sprd, vol);
    VGA_text(1, 2, buf);
}

// ============================================================
// render_candles — dynamic axis + area shading below close line
// Chart bottom = COMP_Y0-1 = 369
// ============================================================
void render_candles(void) {
    int i, idx, x, y, g;
    char buf[8];
    int grid_step, grid_start, grid_p, n, start_x;
    int new_label_rows[20];
    int new_label_count = 0;
    int chart_bottom = COMP_Y0 - 1;   // 369

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
            if (gy > chart_bottom) continue;
            if (grid_line_count < 20) {
                grid_y_lines[grid_line_count++] = gy;
                sprintf(buf, "%3d", grid_p);
                int crow = gy >> 3;
                VGA_text(1, crow, buf);
                if (new_label_count < 20) new_label_rows[new_label_count++] = crow;
            }
        }
    }
    for (i = 0; i < new_label_count; i++) last_label_rows[i] = new_label_rows[i];
    last_label_count = new_label_count;

    n       = candle_count;
    start_x = (n < MAX_CANDLES) ? CANDLE_X0 : CANDLE_X0 + CANDLE_W - n * SLOT;

    int c_high[MAX_CANDLES], c_low[MAX_CANDLES];
    int c_top[MAX_CANDLES],  c_bot[MAX_CANDLES];
    int c_close_y[MAX_CANDLES];
    short c_body_col[MAX_CANDLES], c_wick_col[MAX_CANDLES];

    for (i = 0; i < n; i++) {
        idx = (candle_head - n + i + MAX_CANDLES) % MAX_CANDLES;
        Candle *c = &candles[idx];
        c_high[i]    = candle_price_to_y((int)c->high);
        c_low[i]     = candle_price_to_y((int)c->low);
        c_close_y[i] = candle_price_to_y((int)c->close);
        int y_open  = candle_price_to_y((int)c->open);
        int y_close = c_close_y[i];
        c_top[i] = (y_open < y_close) ? y_open : y_close;
        c_bot[i] = (y_open > y_close) ? y_open : y_close;
        if (c_top[i] == c_bot[i]) c_bot[i] = c_top[i] + 1;
        if (c_high[i]    > chart_bottom) c_high[i]    = chart_bottom;
        if (c_low[i]     > chart_bottom) c_low[i]     = chart_bottom;
        if (c_top[i]     > chart_bottom) c_top[i]     = chart_bottom;
        if (c_bot[i]     > chart_bottom) c_bot[i]     = chart_bottom;
        if (c_close_y[i] > chart_bottom) c_close_y[i] = chart_bottom;
        c_body_col[i] = c->green ? dim_green    : dim_red;
        c_wick_col[i] = c->green ? bright_green : bright_red;
    }

    int cur_close_y = candle_price_to_y((int)cur_close);
    if (cur_close_y > chart_bottom) cur_close_y = chart_bottom;

    int exec_y = candle_price_to_y((int)OB_EXEC);
    if (exec_y > chart_bottom) exec_y = chart_bottom;

    for (y = CHART_Y0; y <= chart_bottom; y++) {
        int is_grid = 0;
        for (g = 0; g < grid_line_count; g++)
            if (y == grid_y_lines[g]) { is_grid = 1; break; }

        for (x = CANDLE_X0; x < CANDLE_X0 + CANDLE_W - 1; x++) {
            short col = black;

            // Area shading below interpolated close line
            {
                int slot_i = (x - start_x) / SLOT;
                if (slot_i >= 0 && slot_i < n) {
                    int x_cur  = start_x + slot_i * SLOT + BODY_W / 2;
                    int y_cur  = c_close_y[slot_i];
                    int y_next = (slot_i + 1 < n) ? c_close_y[slot_i + 1]
                                                   : cur_close_y;
                    int x_next = x_cur + SLOT;
                    int dx     = x_next - x_cur;
                    int interp_y = (dx > 0)
                        ? y_cur + ((y_next - y_cur) * (x - x_cur)) / dx
                        : y_cur;
                    if (interp_y > chart_bottom) interp_y = chart_bottom;

                    if (y == interp_y) {
                        col = RGB(0, 20, 31);   // bright cyan trace
                    } else if (y > interp_y) {
                        int depth     = y - interp_y;
                        int max_depth = chart_bottom - interp_y;
                        if (max_depth < 1) max_depth = 1;
                        if      (depth < max_depth / 3)        col = RGB(0, 4, 8);
                        else if (depth < (max_depth * 2) / 3)  col = RGB(0, 2, 5);
                        else                                    col = RGB(0, 1, 3);
                    }
                }
            }

            // Exec price dashed line
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

    VGA_hline(CANDLE_X0, CANDLE_X0 + CANDLE_W - 1, COMP_Y0 - 1, gray);
    VGA_vline(CANDLE_X0 + CANDLE_W - 1, CHART_Y0, chart_bottom, gray);
}

// ============================================================
// render_depth — top-right, fixed 0-399 axis
// ============================================================
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
        bin_bid[b] = bq; bin_ask[b] = aq;
        if (bq > max_qty) max_qty = bq;
        if (aq > max_qty) max_qty = aq;
    }

    for (y = DEPTH_Y0; y <= DEPTH_Y1 - 1; y++) {
        int bin_row = ((y - DEPTH_Y0) * DEPTH_BINS) / DEPTH_H;
        if (bin_row < 0 || bin_row >= DEPTH_BINS) {
            VGA_hline(DEPTH_X0, DEPTH_X0 + DEPTH_W - 1, y, black); continue;
        }
        int price_bin = (DEPTH_BINS - 1) - bin_row;
        uint32_t bq = bin_bid[price_bin];
        uint32_t aq = bin_ask[price_bin];

        if (bq > 0) {
            int bar_w = (int)((double)bq / max_qty * half);
            if (bar_w < 1) bar_w = 1; if (bar_w > half) bar_w = half;
            int g_val = 15 + (int)(((uint64_t)bq * 48) / max_qty);
            short bid_col = RGB(0, g_val, 0);
            for (x = DEPTH_X0; x < DEPTH_X0 + half; x++)
                VGA_PIXEL(x, y, (x >= DEPTH_X0 + half - bar_w) ? bid_col : black);
        } else { VGA_hline(DEPTH_X0, DEPTH_X0 + half - 1, y, black); }

        if (aq > 0) {
            int bar_w = (int)((double)aq / max_qty * half);
            if (bar_w < 1) bar_w = 1; if (bar_w > half) bar_w = half;
            int r_val = 8 + (aq * 23) / max_qty;
            short ask_col = RGB(r_val, 0, 0);
            for (x = DEPTH_X0 + half; x < DEPTH_X0 + DEPTH_W; x++)
                VGA_PIXEL(x, y, (x < DEPTH_X0 + half + bar_w) ? ask_col : black);
        } else { VGA_hline(DEPTH_X0 + half, DEPTH_X0 + DEPTH_W - 1, y, black); }
    }
    VGA_text(40, 6, "Depth of Market");
}

// ============================================================
// render_volume_histogram — bottom-left panel
// Scrolling bar chart aligned with candles, newest on right.
// ============================================================
void render_volume_histogram(void) {
    int i, x, y;
    int n = vol_count;

    uint32_t max_vol = 1;
    for (i = 0; i < n; i++) {
        int idx = (vol_head - n + i + MAX_CANDLES) % MAX_CANDLES;
        if (vol_hist[idx] > max_vol) max_vol = vol_hist[idx];
    }

    int ref_y[3];
    ref_y[0] = VOL_Y0 + (VOL_H * 1) / 4;
    ref_y[1] = VOL_Y0 + (VOL_H * 2) / 4;
    ref_y[2] = VOL_Y0 + (VOL_H * 3) / 4;

    for (y = VOL_Y0; y <= VOL_Y1; y++) {
        int y_frac = ((VOL_Y1 - y) * 255) / (VOL_H - 1);
        int is_ref = (y == ref_y[0] || y == ref_y[1] || y == ref_y[2]);

        for (x = VOL_X0; x < VOL_X0 + VOL_W; x++) {
            int slot   = (x - VOL_X0) / SLOT;
            int slot_x = (x - VOL_X0) % SLOT;

            if (slot_x == SLOT - 1) { VGA_PIXEL(x, y, black); continue; }

            if (slot >= n) {
                VGA_PIXEL(x, y, is_ref && ((x >> 2) & 1) ? dark_gray : black);
                continue;
            }

            int hist_idx = (vol_head - n + slot + MAX_CANDLES) % MAX_CANDLES;
            uint32_t v   = vol_hist[hist_idx];
            int bar_frac = (int)(((uint64_t)v * 255) / max_vol);

            if (y_frac <= bar_frac) {
                int intensity = 10 + (int)(((uint64_t)v * 53) / max_vol);
                VGA_PIXEL(x, y, RGB(0, intensity, intensity));
            } else if (is_ref && ((x >> 2) & 1)) {
                VGA_PIXEL(x, y, dark_gray);
            } else {
                VGA_PIXEL(x, y, black);
            }
        }
    }
    VGA_hline(VOL_X0, VOL_X0 + VOL_W - 1, VOL_Y0, gray);
}

// ============================================================
// render_comp — bottom-right, stacked trader composition
// ============================================================
void render_comp(void) {
    int x, y;
    int n = comp_count;
    static const short trader_colors[NUM_TRADER_TYPES] = {
        col_noise, col_mm, col_momentum, col_value
    };
    for (y = COMP_Y0; y <= COMP_Y1; y++) {
        int y_frac = ((COMP_Y1 - y) * 255) / (COMP_H - 1);
        for (x = COMP_X0; x < COMP_X0 + COMP_W; x++) {
            int slot   = (x - COMP_X0) / COMP_COL_W;
            int slot_x = (x - COMP_X0) % COMP_COL_W;
            if (slot_x == COMP_COL_W - 1) { VGA_PIXEL(x, y, black); continue; }
            if (slot >= n)                 { VGA_PIXEL(x, y, black); continue; }
            int hist_idx   = (comp_head - n + slot + COMP_MAX_COLS) % COMP_MAX_COLS;
            int cumulative = 0;
            short col_color = black;
            int t;
            for (t = 0; t < NUM_TRADER_TYPES; t++) {
                cumulative += comp_hist[hist_idx][t];
                if (y_frac <= cumulative) { col_color = trader_colors[t]; break; }
            }
            VGA_PIXEL(x, y, col_color);
        }
    }
}

// ============================================================
// render_debug_overlay — VGA char buffer, top-right corner
// ============================================================
void render_debug_overlay(void) {
    char buf[48];
    sprintf(buf, "FRM:%-8u EXEC:%-4u    ", OB_FRAME, OB_EXEC);
    VGA_text(40, 0, buf);
    int sprd = (OB_BEST_ASK > OB_BEST_BID)
               ? (int)(OB_BEST_ASK - OB_BEST_BID) : -1;
    sprintf(buf, "BID:%-4u ASK:%-4u SPR:%-3d  ", OB_BEST_BID, OB_BEST_ASK, sprd);
    VGA_text(40, 1, buf);
    sprintf(buf, "VOL:%-10u            ", OB_VOLUME);
    VGA_text(40, 2, buf);
    sprintf(buf, "RAW800:0x%08X       ", fpga_ob[800]);
    VGA_text(40, 3, buf);
    if (OB_EXEC == 0 && OB_FRAME == 0)
        VGA_text(40, 4, "STATUS: NO FRAME - CHK RESET");
    else if (OB_EXEC == 0)
        VGA_text(40, 4, "STATUS: WAITING FOR TRADE...");
    else
        VGA_text(40, 4, "STATUS: TRADING OK          ");
}

// ============================================================
// Main
// ============================================================
int main(int argc, char *argv[]) {
    if (argc > 1) {
        unsigned int seed = (unsigned int)atoi(argv[1]);
        srand(seed);
        printf("Using seed: %u\n", seed);
    } else {
        unsigned int seed = (unsigned int)time(NULL);
        srand(seed);
        printf("Using random seed: %u\n", seed);
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    void *lw_base = mmap(NULL, LW_BRIDGE_SPAN, PROT_READ|PROT_WRITE,
                         MAP_SHARED, fd, LW_BRIDGE_BASE);
    if (lw_base == MAP_FAILED) { perror("mmap lw"); close(fd); return 1; }

    vga_pixel_virtual_base = mmap(NULL, SDRAM_SPAN, PROT_READ|PROT_WRITE,
                                  MAP_SHARED, fd, SDRAM_BASE);
    if (vga_pixel_virtual_base == MAP_FAILED) { perror("mmap sdram"); return 1; }
    vga_pixel_ptr = (unsigned int *)vga_pixel_virtual_base;

    vga_char_virtual_base = mmap(NULL, FPGA_CHAR_SPAN, PROT_READ|PROT_WRITE,
                                 MAP_SHARED, fd, FPGA_CHAR_BASE);
    if (vga_char_virtual_base == MAP_FAILED) { perror("mmap char"); return 1; }
    vga_char_ptr = (unsigned int *)vga_char_virtual_base;

    fpga_ob = (volatile uint32_t *)((uint8_t *)lw_base + ORDERBOOK_MEM_BASE);

    // Agent init
    printf("\n=== Initializing 16,384 Hardware Agents ===\n");
    int counts[4] = {0,0,0,0};
    uint32_t local_agents[NUM_UNITS][SLOTS_PER_UNIT];
    for (int unit = 0; unit < NUM_UNITS; unit++) {
        for (int slot = 0; slot < SLOTS_PER_UNIT; slot++) {
            int roll = rand() % 100;
            uint32_t type, p1, p2, p3;
            if (roll < 45) {
                type=TYPE_NOISE;
                p1=rand_range(700,800); p2=rand_range(20,40); p3=rand_range(50,100);
            } else if (roll < 70) {
                type=TYPE_MM;
                p1=rand_range(400,500); p2=rand_range(2,5); p3=rand_range(10,20);
            } else if (roll < 85) {
                type=TYPE_MOMENTUM;
                p1=rand_range(3,8); p2=rand_range(300,400); p3=rand_range(50,80);
            } else {
                type=TYPE_VALUE;
                p1=rand_range(10,20); p2=rand_range(300,400); p3=rand_range(100,150);
            }
            counts[type]++;
            local_agents[unit][slot] = PACK_AGENT(type,p1,p2,p3);
        }
    }
    for (int unit = 0; unit < NUM_UNITS; unit++) {
        volatile uint32_t *agent_mem = (volatile uint32_t *)
            ((uint8_t *)lw_base + AGENT_MEM_BASE + unit * AGENT_MEM_STRIDE);
        for (int slot = 0; slot < SLOTS_PER_UNIT; slot++)
            agent_mem[slot] = local_agents[unit][slot];
    }
    printf("  Noise:%d MM:%d Momentum:%d Value:%d\n",
           counts[0], counts[1], counts[2], counts[3]);

    // Initial snapshot
    printf("\n=== Initial FPGA snapshot ===\n");
    read_fpga_snapshot();
    printf("  RAW[800]=0x%08X -> tick %u\n", fpga_ob[800], Q824_TO_TICK(fpga_ob[800]));
    printf("  OB_FRAME=%u  OB_VOLUME=%u\n\n", OB_FRAME, OB_VOLUME);

    // VGA init
    VGA_box(0, 0, 639, 479, black);
    VGA_text_clear();

    // Static dividers
    VGA_hline(0, 639, BAR_H - 1, gray);                              // top bar
    VGA_hline(0, 639, COMP_Y0 - 1, gray);                            // full-width horizontal divider y=369
    VGA_vline(CANDLE_X0 + CANDLE_W - 1, CHART_Y0, COMP_Y0 - 1, gray); // left/right vertical split
    VGA_vline(DEPTH_X0 + DEPTH_W / 2, DEPTH_Y0, DEPTH_Y1, gray);    // depth centre spine

    // Depth axis labels
    {
        char buf[8]; int prices[4] = {100,200,300,399}; int ii;
        for (ii = 0; ii < 4; ii++) {
            int gy = depth_price_to_y(prices[ii]);
            sprintf(buf, "%-3d", prices[ii]);
            VGA_text(76, gy >> 3, buf);
        }
    }

    // Composition labels
    {
        static const char *names[4] = {"VAL","MOM","MM ","NSE"};
        int label_char_col = ((COMP_X0 + COMP_W - COMP_LABEL_W) >> 3) + 1;
        int label_rows[4]  = {47,50,53,56};
        int t;
        for (t = 0; t < 4; t++)
            VGA_text(label_char_col, label_rows[t], (char *)names[t]);
    }

    // Wait for first FPGA frame
    printf("Waiting for first FPGA frame");
    fflush(stdout);
    {
        int wc = 0;
        while (OB_FRAME == 0 && wc < 100) {
            read_fpga_snapshot();
            usleep(100000);
            wc++;
            if (wc % 10 == 0) { printf("."); fflush(stdout); }
        }
        printf(OB_FRAME == 0
               ? "\n!! WARNING: FRAME still 0. Check KEY[0].\n"
               : " OK (frame=%u)\n", OB_FRAME);
    }

    open_price = (OB_EXEC > 0) ? OB_EXEC : 200;
    last_frame = OB_FRAME;
    printf("Running. Debug prints every 1s. Ctrl+C to exit.\n\n");

    // Main loop
    while (1) {
        read_fpga_snapshot();
        debug_print_status();

        if (OB_FRAME == last_frame) { usleep(1000); continue; }
        last_frame = OB_FRAME;

        update_candle();
        update_axis();
        render_topbar();
        render_candles();
        render_depth();
        render_volume_histogram();
        render_comp();
        render_debug_overlay();
    }

    munmap(lw_base, LW_BRIDGE_SPAN);
    munmap(vga_pixel_virtual_base, SDRAM_SPAN);
    munmap(vga_char_virtual_base, FPGA_CHAR_SPAN);
    close(fd);
    return 0;
}
