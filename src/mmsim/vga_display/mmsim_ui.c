// Drives the VGA market-simulator UI from the FPGA orderbook snapshot.
// compile: gcc -Wall -std=c99 -o mmsim_ui mmsim_ui.c -lm -lrt
// run:     sudo ./mmsim_ui [seed]

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
#include <termios.h>
#include <signal.h>

// Memory map
#define LW_BRIDGE_BASE        0xFF200000
#define LW_BRIDGE_SPAN        0x00200000
#define SDRAM_BASE            0xC0000000
#define SDRAM_SPAN            0x04000000
#define FPGA_CHAR_BASE        0xC9000000
#define FPGA_CHAR_SPAN        0x00002000
#define ORDERBOOK_MEMORY_BASE 0x00000000
#define NUMBER_UNITS          16
#define SLOTS_PER_UNIT        1024
#define AGENT_MEMORY_BASE     0x00010000
#define AGENT_MEMORY_STRIDE   0x00001000
#define KEY0_PIO_BASE         0x00020000
#define GBM_ENABLE_PIO_BASE   0x00020010
#define GBM_PRICE_OUT_PIO_BASE      0x00020020
#define GBM_STEP_PERIOD_PIO_BASE    0x00020030
#define ANALOG_CLOCK_SPEED_PIO_BASE 0x00020040
#define INJECT_PACKET_PIO_BASE       0x00020050
#define INJECT_TRIGGER_PIO_BASE      0x00020060
#define INJECT_COUNT_PIO_BASE        0x00020070
#define INJECT_ACTIVE_PIO_BASE       0x00020080
#define AGENT_STEP_PERIOD_PIO_BASE   0x00020090

// Agent types
#define TYPE_NOISE    0
#define TYPE_MM       1
#define TYPE_MOMENTUM 2
#define TYPE_VALUE    3

#define PACK_AGENT(type, p1, p2, p3)                                                                          \
    (((uint32_t)(type & 0x3) << 30) | ((uint32_t)(p1 & 0x3FF) << 20) | ((uint32_t)(p2 & 0x3FF) << 10) |    \
     ((uint32_t)(p3 & 0x3FF)))

// VGA colors
#define RGB(r, g, b)   ((short)(((r) << 11) | ((g) << 5) | (b)))
#define black          RGB(0, 0, 0)
#define bright_green   RGB(0, 50, 0)
#define dim_green      RGB(0, 25, 0)
#define bright_red     RGB(28, 0, 0)
#define dim_red        RGB(14, 0, 0)
#define yellow         RGB(31, 63, 0)
#define gray           RGB(6, 12, 6)
#define dark_gray      RGB(2, 4, 2)
#define color_noise    RGB(8, 16, 8)
#define color_mm       RGB(0, 20, 28)
#define color_momentum RGB(28, 20, 0)
#define color_value    RGB(4, 0, 20)

// Layout - mirrors vga_test.c
#define BAR_HEIGHT   40
#define CHART_Y0     BAR_HEIGHT  // 40
#define CHART_HEIGHT 330         // candle panel: y 40..369

#define CANDLE_X0    0
#define CANDLE_WIDTH 320

// Volume histogram - bottom-left
#define VOLUME_X0     0
#define VOLUME_WIDTH  CANDLE_WIDTH
#define VOLUME_Y0     370
#define VOLUME_HEIGHT 110
#define VOLUME_Y1     (VOLUME_Y0 + VOLUME_HEIGHT - 1)  // 479

// Depth - top-right
#define DEPTH_X0     320
#define DEPTH_WIDTH  320
#define DEPTH_Y0     CHART_Y0  // 40
#define DEPTH_HEIGHT 330
#define DEPTH_Y1     (DEPTH_Y0 + DEPTH_HEIGHT - 1)  // 369

// Composition - bottom-right
#define COMPOSITION_X0     320
#define COMPOSITION_WIDTH  320
#define COMPOSITION_Y0     370
#define COMPOSITION_HEIGHT 110
#define COMPOSITION_Y1     (COMPOSITION_Y0 + COMPOSITION_HEIGHT - 1)  // 479

// Candle geometry
#define BODY_WIDTH       5
#define GAP              1
#define SLOT             (BODY_WIDTH + GAP)
#define MAXIMUM_CANDLES  (CANDLE_WIDTH / SLOT)  // 53
#define TICKS_PER_CANDLE 10

// Depth binning
#define DEPTH_BIN_SIZE      4
#define DEPTH_BINS          (400 / DEPTH_BIN_SIZE)  // 100
#define DEPTH_PRICE_MAXIMUM 399

// Composition chart
#define COMPOSITION_LABEL_WIDTH     40
#define COMPOSITION_COLUMN_WIDTH    8
#define COMPOSITION_MAXIMUM_COLUMNS ((COMPOSITION_WIDTH - COMPOSITION_LABEL_WIDTH) / COMPOSITION_COLUMN_WIDTH)
#define NUMBER_TRADER_TYPES         4

#define CANDLE_TOP_MARGIN    0.15
#define CANDLE_BOTTOM_MARGIN 0.15
#define NUMBER_LEVELS        400

#define Q824_TO_TICK(x) ((x) >> 23)

// FPGA orderbook memory
static volatile uint32_t *fpga_orderbook = NULL;
static volatile uint32_t *gbm_price_pio_global = NULL;
static volatile uint32_t *inject_packet_pio    = NULL;
static volatile uint32_t *inject_trigger_pio   = NULL;
static volatile uint32_t *inject_count_pio     = NULL;
static volatile uint32_t *inject_active_pio    = NULL;
static uint32_t orderbook_memory[1024];

#define OB_BUY(i)          orderbook_memory[i]
#define OB_SELL(i)         orderbook_memory[400 + (i)]
#define OB_EXEC            orderbook_memory[800]
#define OB_BEST_BID        orderbook_memory[801]
#define OB_BEST_ASK        orderbook_memory[802]
#define OB_VOLUME          orderbook_memory[803]
#define OB_FRAME           orderbook_memory[804]
#define OB_NOISE_VOLUME    orderbook_memory[805]
#define OB_MM_VOLUME       orderbook_memory[806]
#define OB_MOMENTUM_VOLUME orderbook_memory[807]
#define OB_VALUE_VOLUME    orderbook_memory[808]

static uint32_t previous_noise_volume    = 0;
static uint32_t previous_mm_volume       = 0;
static uint32_t previous_momentum_volume = 0;
static uint32_t previous_value_volume    = 0;

// Candle + volume + composition state
typedef struct
{
    uint32_t open;
    uint32_t close;
    uint32_t high;
    uint32_t low;
    int      green;
} Candle;

static Candle   candles[MAXIMUM_CANDLES];
static int      candle_count  = 0;
static int      candle_head   = 0;
static uint32_t current_open  = 0;
static uint32_t current_high  = 0;
static uint32_t current_low   = UINT32_MAX;
static uint32_t current_close = 0;
static int      window_tick   = 0;
static uint32_t open_price    = 200;
static uint32_t last_frame    = 0xFFFFFFFF;
static int      axis_minimum  = 150;
static int      axis_maximum  = 250;
static int      last_label_rows[20];
static int      last_label_count = 0;

static uint32_t volume_history[MAXIMUM_CANDLES];
static int      volume_head    = 0;
static int      volume_count   = 0;
static uint32_t volume_maximum = 1;
static uint32_t volume_at_open = 0;

static uint8_t composition_history[COMPOSITION_MAXIMUM_COLUMNS][NUMBER_TRADER_TYPES];
static int     composition_head  = 0;
static int     composition_count = 0;

// Debug state
static uint32_t debug_last_print_seconds = 0;
static uint32_t debug_previous_frame     = 0;
static uint32_t debug_previous_exec      = 0;
static uint32_t debug_previous_volume    = 0;
static int      debug_first_trade        = 0;

// Volatility tracking: rolling 10-second price range
static uint32_t price_history[10];
static int      price_hist_idx   = 0;
static int      price_hist_count = 0;

// VGA pointers
volatile unsigned int *vga_pixel_pointer     = NULL;
void                  *vga_pixel_virtual_base;
volatile unsigned int *vga_character_pointer = NULL;
void                  *vga_character_virtual_base;

#define VGA_PIXEL(x, y, color)                                                         \
    do                                                                                 \
    {                                                                                  \
        int *_p      = (int *)((char *)vga_pixel_pointer + (((y) * 640 + (x)) << 1)); \
        *(short *)_p = (color);                                                        \
    } while (0)

// Returns a random integer in the inclusive range [minimum, maximum]
uint32_t rand_range(uint32_t minimum, uint32_t maximum)
{
    return minimum + (rand() % (maximum - minimum + 1));
}

// Triggers a flash injection burst into the FPGA order generator.
// side: 0=buy, 1=sell. price_tick: 0..399. volume: per-order volume. count: number of orders.
// Uses market orders (bit 30 set) so they cross immediately regardless of price.
// Blocks until inject_active deasserts (FPGA signals burst complete).
void flash_inject(int side, int price_tick, int volume, int count)
{
    if (!inject_packet_pio || !inject_trigger_pio ||
        !inject_count_pio  || !inject_active_pio) return;
    uint32_t packet =
        ((uint32_t)(side       & 0x1)   << 31) |
        ((uint32_t)(0)                  << 30) |  // limit order
        ((uint32_t)(TYPE_NOISE & 0x3)   << 28) |  // agent_type = noise so composition chart still works
        ((uint32_t)(price_tick & 0x1FF) << 16) |
        ((uint32_t)(volume     & 0xFFFF));
    *inject_packet_pio  = packet;
    *inject_count_pio   = (uint32_t)count;
    *inject_trigger_pio = 1;
    usleep(1000);                       // give FPGA one or two cycles to latch trigger
    *inject_trigger_pio = 0;
    // Poll until FPGA signals burst complete (inject_active goes low)
    int timeout = 5000;                 // 5s max
    while ((*inject_active_pio & 0x1) && timeout-- > 0) usleep(1000);
    if (timeout <= 0)
        printf("  WARNING: inject_active never deasserted — check FPGA wiring\n");
}

// VGA line primitives
void VGA_hline(int x1, int x2, int y, short color)
{
    int x;
    if (y < 0 || y > 479) return;
    if (x1 < 0) x1 = 0;
    if (x2 > 639) x2 = 639;
    for (x = x1; x <= x2; x++) VGA_PIXEL(x, y, color);
}

void VGA_vline(int x, int y1, int y2, short color)
{
    int y;
    if (x < 0 || x > 639) return;
    if (y1 < 0) y1 = 0;
    if (y2 > 479) y2 = 479;
    for (y = y1; y <= y2; y++) VGA_PIXEL(x, y, color);
}

void VGA_box(int x1, int y1, int x2, int y2, short color)
{
    int x, y;
    if (x1 < 0) x1 = 0;
    if (y1 < 0) y1 = 0;
    if (x2 > 639) x2 = 639;
    if (y2 > 479) y2 = 479;
    for (y = y1; y <= y2; y++)
        for (x = x1; x <= x2; x++) VGA_PIXEL(x, y, color);
}

// VGA text primitives
void VGA_text(int x, int y, char *text)
{
    volatile char *character_buffer = (char *)vga_character_pointer;
    int            offset           = (y << 7) + x;
    while (*text) character_buffer[offset++] = *text++;
}

void VGA_text_clear(void)
{
    int            x, y;
    volatile char *character_buffer = (char *)vga_character_pointer;
    for (y = 0; y < 60; y++)
        for (x = 0; x < 80; x++) character_buffer[(y << 7) + x] = ' ';
}

// Coordinate helpers
static inline int candle_price_to_y(int price)
{
    int range = axis_maximum - axis_minimum;
    int y;
    if (range <= 0) return CHART_Y0 + CHART_HEIGHT / 2;
    y = CHART_Y0 + CHART_HEIGHT - 1 - ((price - axis_minimum) * (CHART_HEIGHT - 1)) / range;
    if (y < CHART_Y0) y = CHART_Y0;
    if (y > 479) y = 479;
    return y;
}

static inline int depth_price_to_y(int price)
{
    int y = DEPTH_Y0 + DEPTH_HEIGHT - 1 - (price * (DEPTH_HEIGHT - 1)) / DEPTH_PRICE_MAXIMUM;
    if (y < DEPTH_Y0) y = DEPTH_Y0;
    if (y > DEPTH_Y1) y = DEPTH_Y1;
    return y;
}

void read_fpga_snapshot(void)
{
    int i;
    for (i = 0; i < 800; i++) orderbook_memory[i] = fpga_orderbook[i];
    orderbook_memory[800] = Q824_TO_TICK(fpga_orderbook[800]);
    orderbook_memory[801] = Q824_TO_TICK(fpga_orderbook[801]);
    orderbook_memory[802] = Q824_TO_TICK(fpga_orderbook[802]);
    orderbook_memory[803] = fpga_orderbook[803];
    orderbook_memory[804] = fpga_orderbook[804];
    orderbook_memory[805] = fpga_orderbook[805];
    orderbook_memory[806] = fpga_orderbook[806];
    orderbook_memory[807] = fpga_orderbook[807];
    orderbook_memory[808] = fpga_orderbook[808];

    uint32_t best_bid = orderbook_memory[801];
    uint32_t best_ask = orderbook_memory[802];
    if (best_bid > 0 && best_ask > 0 && best_ask > best_bid)
    {
        for (i = 0; i < 400; i++)
        {
            // Bid strictly above best_ask is a stale scan artifact
            if (orderbook_memory[i] > 0 && (uint32_t)i > best_ask)
                orderbook_memory[i] = 0;
            // Ask strictly below best_bid is a stale scan artifact
            if (orderbook_memory[400 + i] > 0 && (uint32_t)i < best_bid)
                orderbook_memory[400 + i] = 0;
        }
    }
}

// Prints rate-limited debug status once per second including liquidity and volatility metrics.
// OB_BEST_BID / OB_BEST_ASK are price tick indices; total_bid_qty / total_ask_qty are share counts.
// Spread (ticks) and total resting shares are the primary liquidity proxies.
// Volatility is approximated as the price range across the last 10 seconds.
void debug_print_status(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint32_t now_seconds = (uint32_t)ts.tv_sec;
    if (now_seconds == debug_last_print_seconds) return;
    debug_last_print_seconds = now_seconds;

    uint32_t frame  = OB_FRAME;
    uint32_t exec   = OB_EXEC;
    uint32_t bid    = OB_BEST_BID;   // price tick index of best resting bid
    uint32_t ask    = OB_BEST_ASK;   // price tick index of best resting ask
    uint32_t volume = OB_VOLUME;
    int      bid_levels = 0;
    int      ask_levels = 0;
    int      j;

    // Count non-zero price levels and total resting shares on each side
    uint32_t total_bid_qty = 0;
    uint32_t total_ask_qty = 0;
    for (j = 0; j < 400; j++)
    {
        if (OB_BUY(j) > 0)  { bid_levels++; total_bid_qty += OB_BUY(j);  }
        if (OB_SELL(j) > 0) { ask_levels++; total_ask_qty += OB_SELL(j); }
    }

    int frame_delta      = (int)(frame - debug_previous_frame);
    debug_previous_frame = frame;

    const char *exec_flag = "";
    if (exec != 0 && !debug_first_trade)
    {
        exec_flag         = "  <-- FIRST TRADE!";
        debug_first_trade = 1;
    }
    else if (exec != debug_previous_exec)
    {
        exec_flag = "  <-- price changed";
    }
    debug_previous_exec = exec;

    const char *volume_flag = (volume != debug_previous_volume) ? "  <-- volume up" : "";
    debug_previous_volume   = volume;

    // Update rolling 10-second price history for volatility estimate
    if (exec > 0)
    {
        price_history[price_hist_idx] = exec;
        price_hist_idx                = (price_hist_idx + 1) % 10;
        if (price_hist_count < 10) price_hist_count++;
    }
    uint32_t p_min = price_history[0];
    uint32_t p_max = price_history[0];
    for (j = 1; j < price_hist_count; j++)
    {
        if (price_history[j] < p_min) p_min = price_history[j];
        if (price_history[j] > p_max) p_max = price_history[j];
    }
    uint32_t volatility_range = (price_hist_count > 1) ? (p_max - p_min) : 0;
    
    uint32_t gbm_raw  = gbm_price_pio_global ? *gbm_price_pio_global : 0;
    uint32_t gbm_tick = gbm_raw >> 23;
    int exec_vs_gbm   = (int)exec - (int)gbm_tick;
    printf("          GBM: raw=0x%08X tick=%u  exec=%u  drift=%+d ticks\n",
           gbm_raw, gbm_tick, exec, exec_vs_gbm);
    
    // Also print raw agent type volumes to see who is dominating
    printf("          VOLUMES: noise=%-8u mm=%-8u momentum=%-8u value=%-8u\n",
           OB_NOISE_VOLUME, OB_MM_VOLUME, OB_MOMENTUM_VOLUME, OB_VALUE_VOLUME);
           

    // Spread in ticks between best bid and best ask price indices
    int spread = (ask > bid) ? (int)(ask - bid) : -1;

    printf("[t=%-5u] FRAME=%-8u (+%-4d/s)  EXEC=%-4u%s\n",
           now_seconds, frame, frame_delta, exec, exec_flag);
    printf("          BID=%-4u(tick)  ASK=%-4u(tick)  SPREAD=%d ticks  VOL=%-8u%s\n",
           bid, ask, spread, volume, volume_flag);
    printf("          DEPTH: bid_levels=%-3d bid_shares=%-8u  ask_levels=%-3d ask_shares=%-8u\n",
           bid_levels, total_bid_qty, ask_levels, total_ask_qty);
    printf("          LIQUIDITY: spread=%-3d ticks  total_resting=%-8u shares\n",
           spread, total_bid_qty + total_ask_qty);
    printf("          VOLATILITY: 10s price range = %u ticks\n", volatility_range);
    printf("          RAW[800]=0x%08X  (>>23=%u)\n",
           fpga_orderbook[800], Q824_TO_TICK(fpga_orderbook[800]));

    if (frame == 0)
        printf("  !! FRAME=0 - orderbook_writer not running. Check KEY[0].\n");
    else if (frame_delta == 0)
        printf("  !! Frame stalled - FPGA may be in reset.\n");
    else if (exec == 0 && bid_levels == 0 && ask_levels == 0)
        printf("  !! No depth, no exec - BUY never reached price_level_store.\n");
    else if (exec == 0 && (bid_levels > 0 || ask_levels > 0))
        printf("  !! Depth exists but no exec - orders not crossing.\n");
    else if (exec > 0)
    {
        // Liquidity quality hints
        if (spread <= 3 && (total_bid_qty + total_ask_qty) > 50000)
            printf("  OK: Trades firing. Book is LIQUID (tight spread, deep).\n");
        else if (spread > 10)
            printf("  OK: Trades firing. WIDE SPREAD (%d ticks) - book is thin.\n", spread);
        else
            printf("  OK: Trades firing. VGA rendering.\n");
    }
    printf("\n");
    fflush(stdout);
}

// Renders the top status bar with ticker, last price, bid/ask ticks, spread, and volume
void render_topbar(void)
{
    char     buffer[80];
    uint32_t bid_t  = OB_BEST_BID;
    uint32_t ask_t  = OB_BEST_ASK;
    uint32_t exec   = (bid_t > 0 && ask_t > 0) ? ((bid_t + ask_t) / 2) : OB_EXEC;
    uint32_t bid           = OB_BEST_BID;  // price tick index
    uint32_t ask           = OB_BEST_ASK;  // price tick index
    uint32_t volume        = OB_VOLUME;
    int      spread        = (int)ask - (int)bid;
    int      percent_tenths =
        (int)((int)(exec - open_price) * 1000 / (int)(open_price ? open_price : 1));
    VGA_text(1, 1, "NASDAQ:VHA");
    sprintf(buffer, "LAST:%-3u  %+d.%01d%%   ", exec, percent_tenths / 10, abs(percent_tenths % 10));
    VGA_text(14, 1, buffer);
    sprintf(buffer, "BID:%-3u  ASK:%-3u  SPR:%d  VOL:%-7u", bid, ask, spread, volume);
    VGA_text(1, 2, buffer);
}

// Updates the candle chart Y-axis range with smooth tracking
void update_axis(void)
{
    int i, index, visible_minimum, visible_maximum, range, new_minimum, new_maximum,
        minimum_difference, maximum_difference;
    int n           = candle_count;
    visible_minimum = 999;
    visible_maximum = 0;
    if (n < 1)
    {
        axis_minimum = 0;
        axis_maximum = 399;
        return;
    }
    for (i = 0; i < n; i++)
    {
        index = (candle_head - n + i + MAXIMUM_CANDLES) % MAXIMUM_CANDLES;
        if ((int)candles[index].low < visible_minimum)  visible_minimum = (int)candles[index].low;
        if ((int)candles[index].high > visible_maximum) visible_maximum = (int)candles[index].high;
    }
    if (window_tick > 0)
    {
        if ((int)current_low < visible_minimum)  visible_minimum = (int)current_low;
        if ((int)current_high > visible_maximum) visible_maximum = (int)current_high;
    }
    range = visible_maximum - visible_minimum;
    if (range < 10) range = 10;
    {
        double total_range = range / (1.0 - CANDLE_TOP_MARGIN - CANDLE_BOTTOM_MARGIN);
        new_minimum        = (int)(visible_minimum - total_range * CANDLE_BOTTOM_MARGIN);
        new_maximum        = (int)(new_minimum + total_range);
    }
    minimum_difference = new_minimum - axis_minimum;
    maximum_difference = new_maximum - axis_maximum;
    if (minimum_difference != 0 && minimum_difference > -8 && minimum_difference < 8)
        axis_minimum += (minimum_difference > 0) ? 1 : -1;
    else
        axis_minimum += minimum_difference / 8;
    if (maximum_difference != 0 && maximum_difference > -8 && maximum_difference < 8)
        axis_maximum += (maximum_difference > 0) ? 1 : -1;
    else
        axis_maximum += maximum_difference / 8;
    if (axis_minimum < -50)  axis_minimum = -50;
    if (axis_maximum > 450)  axis_maximum = 450;
    if (axis_maximum - axis_minimum < 10) {
        int mid      = (axis_minimum + axis_maximum) / 2;
        axis_minimum = mid - 5;
        axis_maximum = mid + 5;
    }
}

// Updates the active candle from FPGA exec price and rolls per-candle volume and composition
void update_candle(void)
{
    uint32_t price = OB_EXEC;
    if (price == 0) return;

    if (window_tick == 0)
    {
        current_open   = price;
        current_high   = price;
        current_low    = price;
        volume_at_open = OB_VOLUME;
    }
    if (price > current_high) current_high = price;
    if (price < current_low)  current_low  = price;
    current_close = price;

    if (++window_tick >= TICKS_PER_CANDLE)
    {
        Candle candle;
        candle.open          = current_open;
        candle.close         = current_close;
        candle.high          = current_high;
        candle.low           = current_low;
        candle.green         = (current_close >= current_open);
        candles[candle_head] = candle;

        // Per-candle volume with wrap-around protection
        {
            uint32_t candle_volume =
                (OB_VOLUME >= volume_at_open)
                    ? (OB_VOLUME - volume_at_open)
                    : (0xFFFFFFFF - volume_at_open + OB_VOLUME + 1);
            volume_history[candle_head] = candle_volume;
            if (candle_volume >= volume_maximum)
            {
                volume_maximum = candle_volume;
            }
            else if (volume_count == MAXIMUM_CANDLES)
            {
                int j;
                volume_maximum = 1;
                for (j = 0; j < MAXIMUM_CANDLES; j++)
                    if (volume_history[j] > volume_maximum) volume_maximum = volume_history[j];
            }
        }

        // Trader composition — diffs cumulative per-type volumes across the candle window
        {
            uint32_t delta_noise    = OB_NOISE_VOLUME    - previous_noise_volume;
            uint32_t delta_mm       = OB_MM_VOLUME       - previous_mm_volume;
            uint32_t delta_momentum = OB_MOMENTUM_VOLUME - previous_momentum_volume;
            uint32_t delta_value    = OB_VALUE_VOLUME    - previous_value_volume;
            previous_noise_volume    = OB_NOISE_VOLUME;
            previous_mm_volume       = OB_MM_VOLUME;
            previous_momentum_volume = OB_MOMENTUM_VOLUME;
            previous_value_volume    = OB_VALUE_VOLUME;
            uint32_t total = delta_noise + delta_mm + delta_momentum + delta_value;
            if (total == 0)
            {
                memset(composition_history[composition_head], 0, NUMBER_TRADER_TYPES);
            }
            else
            {
                composition_history[composition_head][0] = (uint8_t)(delta_noise    * 255 / total);
                composition_history[composition_head][1] = (uint8_t)(delta_mm       * 255 / total);
                composition_history[composition_head][2] = (uint8_t)(delta_momentum * 255 / total);
                composition_history[composition_head][3] =
                    255 - composition_history[composition_head][0]
                        - composition_history[composition_head][1]
                        - composition_history[composition_head][2];
            }
        }

        candle_head      = (candle_head + 1) % MAXIMUM_CANDLES;
        composition_head = (composition_head + 1) % COMPOSITION_MAXIMUM_COLUMNS;
        volume_head      = candle_head;

        if (candle_count < MAXIMUM_CANDLES)                candle_count++;
        if (composition_count < COMPOSITION_MAXIMUM_COLUMNS) composition_count++;
        if (volume_count < MAXIMUM_CANDLES)                volume_count++;

        window_tick  = 0;
        current_high = 0;
        current_low  = UINT32_MAX;
    }
}

// Renders candles with dynamic axis and area shading below the close line.
// Chart bottom = COMPOSITION_Y0-1 = 369
void render_candles(void)
{
    int i, index, x, y, g;
    char buffer[8];
    int  grid_step, grid_start, grid_p, n, start_x;
    int  new_label_rows[20];
    int  new_label_count = 0;
    int  chart_bottom    = COMPOSITION_Y0 - 1;  // 369

    for (i = 0; i < last_label_count; i++) VGA_text(1, last_label_rows[i], "   ");

    int grid_y_lines[20];
    int grid_line_count = 0;
    {
        int range = axis_maximum - axis_minimum;
        if      (range < 20)  grid_step = 5;
        else if (range < 50)  grid_step = 10;
        else if (range < 100) grid_step = 20;
        else if (range < 200) grid_step = 50;
        else                  grid_step = 100;
        grid_start = ((axis_minimum / grid_step) + 1) * grid_step;
        for (grid_p = grid_start; grid_p < axis_maximum; grid_p += grid_step)
        {
            int grid_y = candle_price_to_y(grid_p);
            if (grid_y > chart_bottom) continue;
            if (grid_line_count < 20)
            {
                grid_y_lines[grid_line_count++] = grid_y;
                sprintf(buffer, "%3d", grid_p);
                int character_row = grid_y >> 3;
                VGA_text(1, character_row, buffer);
                if (new_label_count < 20) new_label_rows[new_label_count++] = character_row;
            }
        }
    }
    for (i = 0; i < new_label_count; i++) last_label_rows[i] = new_label_rows[i];
    last_label_count = new_label_count;

    n       = candle_count;
    start_x = (n < MAXIMUM_CANDLES) ? CANDLE_X0 : CANDLE_X0 + CANDLE_WIDTH - n * SLOT;

    int   candle_high[MAXIMUM_CANDLES];
    int   candle_low[MAXIMUM_CANDLES];
    int   candle_top[MAXIMUM_CANDLES];
    int   candle_bottom[MAXIMUM_CANDLES];
    int   candle_close_y[MAXIMUM_CANDLES];
    short candle_body_color[MAXIMUM_CANDLES];
    short candle_wick_color[MAXIMUM_CANDLES];

    for (i = 0; i < n; i++)
    {
        index             = (candle_head - n + i + MAXIMUM_CANDLES) % MAXIMUM_CANDLES;
        Candle *candle    = &candles[index];
        candle_high[i]    = candle_price_to_y((int)candle->high);
        candle_low[i]     = candle_price_to_y((int)candle->low);
        candle_close_y[i] = candle_price_to_y((int)candle->close);
        int y_open        = candle_price_to_y((int)candle->open);
        int y_close       = candle_close_y[i];
        candle_top[i]     = (y_open < y_close) ? y_open : y_close;
        candle_bottom[i]  = (y_open > y_close) ? y_open : y_close;
        if (candle_top[i] == candle_bottom[i]) candle_bottom[i] = candle_top[i] + 1;
        if (candle_high[i]    > chart_bottom) candle_high[i]    = chart_bottom;
        if (candle_low[i]     > chart_bottom) candle_low[i]     = chart_bottom;
        if (candle_top[i]     > chart_bottom) candle_top[i]     = chart_bottom;
        if (candle_bottom[i]  > chart_bottom) candle_bottom[i]  = chart_bottom;
        if (candle_close_y[i] > chart_bottom) candle_close_y[i] = chart_bottom;
        candle_body_color[i] = candle->green ? dim_green    : dim_red;
        candle_wick_color[i] = candle->green ? bright_green : bright_red;
    }

    int current_close_y = candle_price_to_y((int)current_close);
    if (current_close_y > chart_bottom) current_close_y = chart_bottom;

    uint32_t mid_bid = OB_BEST_BID;
    uint32_t mid_ask = OB_BEST_ASK;
    uint32_t mid_exec = (mid_bid > 0 && mid_ask > 0) ? ((mid_bid + mid_ask) / 2) : OB_EXEC;
    int exec_y = candle_price_to_y((int)mid_exec);
    if (exec_y > chart_bottom) exec_y = chart_bottom;

    for (y = CHART_Y0; y <= chart_bottom; y++)
    {
        int is_grid = 0;
        for (g = 0; g < grid_line_count; g++)
        {
            if (y == grid_y_lines[g]) { is_grid = 1; break; }
        }

        for (x = CANDLE_X0; x < CANDLE_X0 + CANDLE_WIDTH - 1; x++)
        {
            short col = black;

            // Area shading below interpolated close line
            {
                int slot_index = (x - start_x) / SLOT;
                if (slot_index >= 0 && slot_index < n)
                {
                    int x_current      = start_x + slot_index * SLOT + BODY_WIDTH / 2;
                    int y_current      = candle_close_y[slot_index];
                    int y_next         = (slot_index + 1 < n) ? candle_close_y[slot_index + 1] : current_close_y;
                    int x_next         = x_current + SLOT;
                    int delta_x        = x_next - x_current;
                    int interpolated_y = (delta_x > 0)
                        ? y_current + ((y_next - y_current) * (x - x_current)) / delta_x
                        : y_current;
                    if (interpolated_y > chart_bottom) interpolated_y = chart_bottom;

                    if (y == interpolated_y)
                    {
                        col = RGB(0, 20, 31);  // bright cyan trace
                    }
                    else if (y > interpolated_y)
                    {
                        int depth         = y - interpolated_y;
                        int maximum_depth = chart_bottom - interpolated_y;
                        if (maximum_depth < 1) maximum_depth = 1;
                        if      (depth < maximum_depth / 3)        col = RGB(0, 4, 8);
                        else if (depth < (maximum_depth * 2) / 3)  col = RGB(0, 2, 5);
                        else                                        col = RGB(0, 1, 3);
                    }
                }
            }

            // Exec price dashed line
            if (y == exec_y && ((x >> 2) & 1))
            {
                col = yellow;
            }
            else
            {
                int slot_index = (x - start_x) / SLOT;
                int slot_x     = (x - start_x) % SLOT;
                if (n > 0 && slot_index >= 0 && slot_index < n && slot_x < BODY_WIDTH)
                {
                    if (y >= candle_high[slot_index] && y <= candle_low[slot_index])
                    {
                        if (y >= candle_top[slot_index] && y <= candle_bottom[slot_index])
                            col = candle_body_color[slot_index];
                        else if (slot_x == BODY_WIDTH / 2)
                            col = candle_wick_color[slot_index];
                    }
                }
                if (col == black && is_grid) col = dark_gray;
            }
            VGA_PIXEL(x, y, col);
        }
    }

    VGA_hline(CANDLE_X0, CANDLE_X0 + CANDLE_WIDTH - 1, COMPOSITION_Y0 - 1, gray);
    VGA_vline(CANDLE_X0 + CANDLE_WIDTH - 1, CHART_Y0, chart_bottom, gray);
}

// Renders the volume histogram (bottom-left panel).
// Draws a scrolling bar chart aligned with candles, newest on right.
void render_volume_histogram(void)
{
    int i, x, y;
    int n = volume_count;

    uint32_t maximum_volume = 1;
    for (i = 0; i < n; i++)
    {
        int index = (volume_head - n + i + MAXIMUM_CANDLES) % MAXIMUM_CANDLES;
        if (volume_history[index] > maximum_volume) maximum_volume = volume_history[index];
    }

    int ref_y[3];
    ref_y[0] = VOLUME_Y0 + (VOLUME_HEIGHT * 1) / 4;
    ref_y[1] = VOLUME_Y0 + (VOLUME_HEIGHT * 2) / 4;
    ref_y[2] = VOLUME_Y0 + (VOLUME_HEIGHT * 3) / 4;

    for (y = VOLUME_Y0; y <= VOLUME_Y1; y++)
    {
        int y_fraction = ((VOLUME_Y1 - y) * 255) / (VOLUME_HEIGHT - 1);
        int is_ref     = (y == ref_y[0] || y == ref_y[1] || y == ref_y[2]);

        for (x = VOLUME_X0; x < VOLUME_X0 + VOLUME_WIDTH; x++)
        {
            int slot   = (x - VOLUME_X0) / SLOT;
            int slot_x = (x - VOLUME_X0) % SLOT;

            if (slot_x == SLOT - 1) { VGA_PIXEL(x, y, black); continue; }

            if (slot >= n)
            {
                VGA_PIXEL(x, y, is_ref && ((x >> 2) & 1) ? dark_gray : black);
                continue;
            }

            int      history_index = (volume_head - n + slot + MAXIMUM_CANDLES) % MAXIMUM_CANDLES;
            uint32_t volume_value  = volume_history[history_index];
            int      bar_fraction  = (int)(((uint64_t)volume_value * 255) / maximum_volume);

            if (y_fraction <= bar_fraction)
            {
                int intensity = 10 + (int)(((uint64_t)volume_value * 53) / maximum_volume);
                VGA_PIXEL(x, y, RGB(0, intensity, intensity));
            }
            else if (is_ref && ((x >> 2) & 1))
            {
                VGA_PIXEL(x, y, dark_gray);
            }
            else
            {
                VGA_PIXEL(x, y, black);
            }
        }
    }
    VGA_hline(VOLUME_X0, VOLUME_X0 + VOLUME_WIDTH - 1, VOLUME_Y0, gray);
}

// Renders the stacked trader composition chart (bottom-right).
// Each column is one candle period; colors from bottom to top:
// gray-green = noise, dark cyan = market maker, orange = momentum, purple = value.
void render_composition(void)
{
    int x, y;
    int n = composition_count;
    static const short trader_colors[NUMBER_TRADER_TYPES] = {
        color_noise, color_mm, color_momentum, color_value
    };
    for (y = COMPOSITION_Y0; y <= COMPOSITION_Y1; y++)
    {
        int y_fraction = ((COMPOSITION_Y1 - y) * 255) / (COMPOSITION_HEIGHT - 1);
        for (x = COMPOSITION_X0; x < COMPOSITION_X0 + COMPOSITION_WIDTH; x++)
        {
            int slot   = (x - COMPOSITION_X0) / COMPOSITION_COLUMN_WIDTH;
            int slot_x = (x - COMPOSITION_X0) % COMPOSITION_COLUMN_WIDTH;
            if (slot_x == COMPOSITION_COLUMN_WIDTH - 1) { VGA_PIXEL(x, y, black); continue; }
            if (slot >= n)                               { VGA_PIXEL(x, y, black); continue; }
            int history_index =
                (composition_head - n + slot + COMPOSITION_MAXIMUM_COLUMNS) % COMPOSITION_MAXIMUM_COLUMNS;
            int   cumulative  = 0;
            short pixel_color = black;
            int   t;
            for (t = 0; t < NUMBER_TRADER_TYPES; t++)
            {
                cumulative += composition_history[history_index][t];
                if (y_fraction <= cumulative) { pixel_color = trader_colors[t]; break; }
            }
            VGA_PIXEL(x, y, pixel_color);
        }
    }
}

// Renders the depth of market histogram (top-right panel).
// Bid (green) bars grow rightward from the centre spine; ask (red) bars grow leftward.
// The visible price window tracks OB_EXEC with 1/8-speed smoothing to prevent flickering.
// Each side is scaled independently so thin bid depth is still visible alongside deep asks.
void render_depth(void)
{
    int b, p, y, x;
    int half = DEPTH_WIDTH / 2;
    static uint32_t bin_bid[DEPTH_BINS];
    static uint32_t bin_ask[DEPTH_BINS];

    // Tracks OB_EXEC at 1/8 speed via a smoothed centre to prevent flickering.
    static int smooth_center = 200;
    if (OB_EXEC > 0)
    {
        int target = (int)OB_EXEC;
        int diff   = target - smooth_center;
        if      (diff > 8)  smooth_center += diff / 8;
        else if (diff < -8) smooth_center += diff / 8;
        else if (diff != 0) smooth_center += (diff > 0) ? 1 : -1;
    }

    // Defines a dynamic window of +/-100 ticks around the smoothed centre.
    int depth_view_minimum = smooth_center - 80;
    int depth_view_maximum = smooth_center + 80;
    if (depth_view_minimum < 0)   depth_view_minimum = 0;
    if (depth_view_maximum > 399) depth_view_maximum = 399;
    int depth_view_range = depth_view_maximum - depth_view_minimum;
    if (depth_view_range < 10) depth_view_range = 10;

    // Bins within the visible window rather than the full 0-399 range.
    int visible_ticks = depth_view_range;
    int bin_size      = (visible_ticks + DEPTH_BINS - 1) / DEPTH_BINS;
    if (bin_size < 1) bin_size = 1;

    uint32_t maximum_bid_quantity = 1;
    uint32_t maximum_ask_quantity = 1;

    for (b = 0; b < DEPTH_BINS; b++)
    {
        uint32_t bid_quantity = 0;
        uint32_t ask_quantity = 0;
        for (p = 0; p < bin_size; p++)
        {
            int level = depth_view_minimum + b * bin_size + p;
            if (level < 0 || level >= 400) continue;
            bid_quantity += OB_BUY(level);
            ask_quantity += OB_SELL(level);
        }
        bin_bid[b] = bid_quantity;
        bin_ask[b] = ask_quantity;
        if (bid_quantity > maximum_bid_quantity) maximum_bid_quantity = bid_quantity;
        if (ask_quantity > maximum_ask_quantity) maximum_ask_quantity = ask_quantity;
    }

    for (y = DEPTH_Y0; y <= DEPTH_Y1 - 1; y++)
    {
        int bin_row = ((y - DEPTH_Y0) * DEPTH_BINS) / DEPTH_HEIGHT;
        if (bin_row < 0 || bin_row >= DEPTH_BINS)
        {
            VGA_hline(DEPTH_X0, DEPTH_X0 + DEPTH_WIDTH - 1, y, black);
            continue;
        }
        // Flips so top of panel maps to the highest price in window
        int      price_bin    = (DEPTH_BINS - 1) - bin_row;
        uint32_t bid_quantity = bin_bid[price_bin];
        uint32_t ask_quantity = bin_ask[price_bin];

        // Bid side — scaled independently so thin bids remain visible
        if (bid_quantity > 0)
        {
            int bar_width   = (int)((double)bid_quantity / maximum_bid_quantity * half);
            if (bar_width < 1) bar_width = 1;
            if (bar_width > half) bar_width = half;
            int   green_value = 15 + (int)(((uint64_t)bid_quantity * 48) / maximum_bid_quantity);
            short bid_color   = RGB(0, green_value, 0);
            for (x = DEPTH_X0; x < DEPTH_X0 + half; x++)
                VGA_PIXEL(x, y, (x >= DEPTH_X0 + half - bar_width) ? bid_color : black);
        }
        else
        {
            VGA_hline(DEPTH_X0, DEPTH_X0 + half - 1, y, black);
        }

        // Ask side — scaled independently so thin asks remain visible
        if (ask_quantity > 0)
        {
            int bar_width = (int)((double)ask_quantity / maximum_ask_quantity * half);
            if (bar_width < 1) bar_width = 1;
            if (bar_width > half) bar_width = half;
            int   red_value = 8 + (ask_quantity * 23) / maximum_ask_quantity;
            short ask_color = RGB(red_value, 0, 0);
            for (x = DEPTH_X0 + half; x < DEPTH_X0 + DEPTH_WIDTH; x++)
                VGA_PIXEL(x, y, (x < DEPTH_X0 + half + bar_width) ? ask_color : black);
        }
        else
        {
            VGA_hline(DEPTH_X0 + half, DEPTH_X0 + DEPTH_WIDTH - 1, y, black);
        }
    }

    // Updates axis labels for the dynamic range; clears old labels first
    int i;
    for (i = 74; i < 80; i++)
    {
        int row;
        for (row = DEPTH_Y0 >> 3; row <= DEPTH_Y1 >> 3; row++) VGA_text(i, row, " ");
    }

    // Draws 4 price labels at 25% intervals of the visible window
    char buffer[8];
    int  label_prices[4];
    label_prices[0] = depth_view_minimum + (depth_view_range * 1) / 4;
    label_prices[1] = depth_view_minimum + (depth_view_range * 2) / 4;
    label_prices[2] = depth_view_minimum + (depth_view_range * 3) / 4;
    label_prices[3] = depth_view_maximum;

    for (i = 0; i < 4; i++)
    {
        // Computes the y position of this price within the dynamic window.
        int grid_y = DEPTH_Y0 + DEPTH_HEIGHT - 1 -
                     ((label_prices[i] - depth_view_minimum) * (DEPTH_HEIGHT - 1)) / depth_view_range;
        if (grid_y < DEPTH_Y0) grid_y = DEPTH_Y0;
        if (grid_y > DEPTH_Y1) grid_y = DEPTH_Y1;
        sprintf(buffer, "%-3d", label_prices[i]);
        VGA_text(76, grid_y >> 3, buffer);
    }

    VGA_text(40, 6, "Depth of Market");
}

// Renders the frame counter, exec price, bid/ask ticks, spread, volume, and system status.
void render_debug_overlay(void)
{
    char buffer[48];
    // Row 0: frame counter and exec price — unique info
    sprintf(buffer, "FRM:%-8u EXEC:%-4u    ", OB_FRAME, OB_EXEC);
    VGA_text(40, 0, buffer);
    // Rows 1 and 2 removed — BID/ASK/SPR/VOL already shown in render_topbar
    sprintf(buffer, "RAW800:0x%08X       ", fpga_orderbook[800]);
    VGA_text(40, 1, buffer);  // shift up to row 1
    if (OB_EXEC == 0 && OB_FRAME == 0)
        VGA_text(40, 2, "STATUS: NO FRAME - CHK RESET");
    else if (OB_EXEC == 0)
        VGA_text(40, 2, "STATUS: WAITING FOR TRADE...");
    else
        VGA_text(40, 2, "STATUS: TRADING OK          ");
}

static struct termios term_original;
void term_restore(void)
{
    tcsetattr(STDIN_FILENO, TCSANOW, &term_original);
}
void handle_sigint(int sig)
{
    (void)sig;
    term_restore();
    printf("\nExited cleanly via Ctrl+C. Terminal restored.\n");
    exit(0);
}
void term_raw(void)
{
    struct termios raw;
    tcgetattr(STDIN_FILENO, &term_original);
    raw = term_original;
    raw.c_lflag    &= ~(ICANON | ECHO);
    raw.c_cc[VMIN]  = 0;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}
char poll_key(void)
{
    char c = 0;
    if (read(STDIN_FILENO, &c, 1) == 1) return c;
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc > 1)
    {
        unsigned int seed = (unsigned int)atoi(argv[1]);
        srand(seed);
        printf("Using seed: %u\n", seed);
    }
    else
    {
        unsigned int seed = (unsigned int)time(NULL);
        srand(seed);
        printf("Using random seed: %u\n", seed);
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    void *lw_base = mmap(NULL, LW_BRIDGE_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LW_BRIDGE_BASE);
    if (lw_base == MAP_FAILED) { perror("mmap lw"); close(fd); return 1; }

    vga_pixel_virtual_base =
        mmap(NULL, SDRAM_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SDRAM_BASE);
    if (vga_pixel_virtual_base == MAP_FAILED) { perror("mmap sdram"); return 1; }
    vga_pixel_pointer = (unsigned int *)vga_pixel_virtual_base;

    vga_character_virtual_base =
        mmap(NULL, FPGA_CHAR_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, FPGA_CHAR_BASE);
    if (vga_character_virtual_base == MAP_FAILED) { perror("mmap char"); return 1; }
    vga_character_pointer = (unsigned int *)vga_character_virtual_base;

    fpga_orderbook = (volatile uint32_t *)((uint8_t *)lw_base + ORDERBOOK_MEMORY_BASE);

    // Map PIO ports
    volatile uint32_t *key0_pio =
        (volatile uint32_t *)((uint8_t *)lw_base + KEY0_PIO_BASE);
    volatile uint32_t *gbm_enable_pio =
        (volatile uint32_t *)((uint8_t *)lw_base + GBM_ENABLE_PIO_BASE);
    volatile uint32_t *gbm_price_pio =
        (volatile uint32_t *)((uint8_t *)lw_base + GBM_PRICE_OUT_PIO_BASE);
    gbm_price_pio_global = gbm_price_pio;
    volatile uint32_t *gbm_step_pio =
        (volatile uint32_t *)((uint8_t *)lw_base + GBM_STEP_PERIOD_PIO_BASE);
    volatile uint32_t *analog_speed_pio =
        (volatile uint32_t *)((uint8_t *)lw_base + ANALOG_CLOCK_SPEED_PIO_BASE);
    volatile uint32_t *agent_step_pio =
        (volatile uint32_t *)((uint8_t *)lw_base + AGENT_STEP_PERIOD_PIO_BASE);
        
    inject_packet_pio  = (volatile uint32_t *)((uint8_t *)lw_base + INJECT_PACKET_PIO_BASE);
    inject_trigger_pio = (volatile uint32_t *)((uint8_t *)lw_base + INJECT_TRIGGER_PIO_BASE);
    inject_count_pio   = (volatile uint32_t *)((uint8_t *)lw_base + INJECT_COUNT_PIO_BASE);
    inject_active_pio  = (volatile uint32_t *)((uint8_t *)lw_base + INJECT_ACTIVE_PIO_BASE);


    gbm_price_pio_global = gbm_price_pio;

    // Freeze GBM immediately — keep frozen until agents are written
    *gbm_enable_pio = 0;
    *gbm_step_pio    = 500000;
    *analog_speed_pio = 10000000;
    *agent_step_pio = 5000;
    printf("GBM step period: %u cycles (~%u Hz)\n", 500000, 50000000 / 500000);
    printf("Analog clock period: %u cycles (~%u fps)\n", 5000000, 50000000 / 5000000);
    printf("agent_step_pio readback: %u\n", *agent_step_pio);

    // VGA init — draw static chrome before waiting for KEY[0] so screen looks ready
    VGA_box(0, 0, 639, 479, black);
    VGA_text_clear();
    VGA_hline(0, 639, BAR_HEIGHT - 1, gray);
    VGA_hline(0, 639, COMPOSITION_Y0 - 1, gray);
    VGA_vline(CANDLE_X0 + CANDLE_WIDTH - 1, CHART_Y0, COMPOSITION_Y0 - 1, gray);
    VGA_vline(DEPTH_X0 + DEPTH_WIDTH / 2, DEPTH_Y0, DEPTH_Y1, gray);
    {
        static const char *names[4] = {"VAL", "MOM", "MM ", "NSE"};
        int label_character_column  = ((COMPOSITION_X0 + COMPOSITION_WIDTH - COMPOSITION_LABEL_WIDTH) >> 3) + 1;
        int label_rows[4]           = {47, 50, 53, 56};
        int t;
        for (t = 0; t < 4; t++) VGA_text(label_character_column, label_rows[t], (char *)names[t]);
    }
    VGA_text(1, 1, "Press and release KEY[0] to start...");

    // Waits for KEY[0] press-release — resets FPGA and GBM to tick 200
    printf("Waiting for KEY[0] press and release...\n");
    printf("  (GBM is frozen at tick 200 until agents are written)\n");
    while (*key0_pio & 0x1) usleep(10000);
    printf("KEY[0] pressed, waiting for release...\n");
    while (!(*key0_pio & 0x1)) usleep(10000);
    printf("KEY[0] released. FPGA reset complete.\n\n");

    // Agent init — GBM still frozen so no drift occurs during initialization
    printf("=== Initializing 16,384 Hardware Agents ===\n");
    int      counts[4] = {0, 0, 0, 0};
    uint32_t local_agents[NUMBER_UNITS][SLOTS_PER_UNIT];

    for (int unit = 0; unit < NUMBER_UNITS; unit++)
    {
        for (int slot = 0; slot < SLOTS_PER_UNIT; slot++)
        {
            uint32_t type, p1, p2, p3;
            int roll = rand() % 100;
            if (roll < 10) {
                // NOISE — fires frequently, random side, small market orders near mid
                type = TYPE_NOISE;
                p1   = rand_range(25, 80);  // fire rate threshold (out of 1024)
                p2   = rand_range(23, 80);      // max price offset ticks
                p3   = rand_range(5, 50);     // volume cap
            } else if (roll < 85) {
                // MARKET MAKER — posts both sides at fixed spread around last exec
                type = TYPE_MM;
                p1   = rand_range(25, 80);  // fire rate threshold
                p2   = rand_range(23, 80);      // half-spread in ticks
                p3   = rand_range(5, 50);   // fixed volume
            } else if (roll < 95) {
                // MOMENTUM — fires when recent price move exceeds threshold, follows trend
                // p1 is checked against abs(last_exec - oldest_of_4) in tick units (Q8.24 >> 23)
                // p2 scales volume with momentum magnitude, p3 caps it
                type = TYPE_MOMENTUM;
                p1   = rand_range(25, 80);      // trend threshold in ticks (low = fires often)
                p2   = rand_range(23, 60);  // aggression scale (multiplied by abs_mom in DSP)
                p3   = rand_range(2, 50);    // volume cap
            } else {
                // VALUE INVESTOR — buys when exec is below GBM, sells when above
                type = TYPE_VALUE;
                p1   = rand_range(25, 100);      // divergence threshold in ticks
                p2   = rand_range(22, 80);   // aggression scale
                p3   = rand_range(5, 50);    // volume cap
            }

            counts[type]++;
            local_agents[unit][slot] = PACK_AGENT(type, p1, p2, p3);
        }
    }

    for (int unit = 0; unit < NUMBER_UNITS; unit++)
    {
        volatile uint32_t *agent_memory = (volatile uint32_t *)
            ((uint8_t *)lw_base + AGENT_MEMORY_BASE + unit * AGENT_MEMORY_STRIDE);
        for (int slot = 0; slot < SLOTS_PER_UNIT; slot++)
            agent_memory[slot] = local_agents[unit][slot];
    }
    printf("  Noise:%d MM:%d Momentum:%d Value:%d\n",
           counts[0], counts[1], counts[2], counts[3]);

    // Add this right after the agent write loop, before *gbm_enable_pio = 1
    printf("=== Agent memory readback check ===\n");
    for (int unit = 0; unit < 4; unit++) {
        volatile uint32_t *agent_memory = (volatile uint32_t *)
            ((uint8_t *)lw_base + AGENT_MEMORY_BASE + unit * AGENT_MEMORY_STRIDE);
        uint32_t s0 = agent_memory[0];
        uint32_t s1 = agent_memory[1];
        printf("  Unit %d slot0=0x%08X (type=%d p1=%d p2=%d p3=%d)\n",
               unit, s0, s0>>30, (s0>>20)&0x3FF, (s0>>10)&0x3FF, s0&0x3FF);
        printf("  Unit %d slot1=0x%08X (type=%d)\n", unit, s1, s1>>30);
    }
    
    // DIAGNOSTIC: read raw LFSR-based order packets from the book to check side bias
    printf("=== Checking bid/ask depth asymmetry ===\n");
    read_fpga_snapshot();
    int bid_count = 0, ask_count = 0;
    for (int i = 0; i < 400; i++) {
        if (OB_BUY(i)  > 0) bid_count++;
        if (OB_SELL(i) > 0) ask_count++;
    }
    printf("  After settle: bid_levels=%d  ask_levels=%d\n", bid_count, ask_count);
    // Print first 10 non-zero bid and ask levels to see where they cluster
    printf("  First 10 bid levels: ");
    int shown = 0;
    for (int i = 0; i < 400 && shown < 10; i++)
        if (OB_BUY(i) > 0) { printf("%d(%u) ", i, OB_BUY(i)); shown++; }
    printf("\n  First 10 ask levels: ");
    shown = 0;
    for (int i = 0; i < 400 && shown < 10; i++)
        if (OB_SELL(i) > 0) { printf("%d(%u) ", i, OB_SELL(i)); shown++; }
    printf("\n");

    // Enables the GBM now that agents are written — GBM starts stepping from tick 200
    printf("\nEnabling GBM (agents ready, GBM starts from tick 200)...\n");
    *gbm_enable_pio = 1;

    printf("Waiting 500ms for first orders to settle...\n");
    usleep(500000);
    read_fpga_snapshot();
    printf("Initial exec price after settle: %u\n", OB_EXEC);

    // Initial snapshot
    printf("\n=== Initial FPGA snapshot ===\n");
    read_fpga_snapshot();
    printf("  RAW[800]=0x%08X -> tick %u\n",
           fpga_orderbook[800], Q824_TO_TICK(fpga_orderbook[800]));
    printf("  OB_FRAME=%u  OB_VOLUME=%u\n\n", OB_FRAME, OB_VOLUME);

    // Clears the KEY[0] prompt now that we are running
    VGA_text(1, 1, "                                     ");

    open_price = (OB_EXEC > 0) ? OB_EXEC : 200;
    last_frame = OB_FRAME;
    printf("Running. Debug prints every 1s. Ctrl+C to exit.\n\n");
    printf("Flash injection controls:\n");
    printf("  s = flash CRASH (burst of sell market orders)\n");
    printf("  b = flash RALLY (burst of buy market orders)\n");
    printf("  q = quit\n\n");
    
    term_raw();
    atexit(term_restore);
    signal(SIGINT, handle_sigint);

    // Main loop
    while (1)
    {
        char key = poll_key();
        if (key == 's' || key == 'S') {
            uint32_t exec = OB_EXEC > 0 ? OB_EXEC : 200;
            printf("\n>>> FLASH CRASH triggered at tick %u — injecting 300 sell orders\n\n", exec);
            flash_inject(1, 0, 2000, 25000);
        } else if (key == 'b' || key == 'B') {
            uint32_t exec = OB_EXEC > 0 ? OB_EXEC : 200;
            printf("\n>>> FLASH RALLY triggered at tick %u — injecting 300 buy orders\n\n", exec);
            flash_inject(0, 399, 100, 150);
        } else if (key == 'q' || key == 'Q') {
            printf("\nQuitting...\n");
            break;
        }
            
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
        render_composition();
        render_debug_overlay();
    }

    term_restore();
    munmap(lw_base, LW_BRIDGE_SPAN);
    munmap(vga_pixel_virtual_base, SDRAM_SPAN);
    munmap(vga_character_virtual_base, FPGA_CHAR_SPAN);
    close(fd);
    return 0;
}
