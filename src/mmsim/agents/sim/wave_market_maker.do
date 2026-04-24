# wave_market_maker.do
# ModelSim waveform configuration for the closed-loop market_maker testbench. Groups signals by
# logical region with appropriate per-signal radix: prices and IDs in hex for easy cross-bus
# comparison, quantities and inventory in decimal or unsigned, single-bit flags in binary, FSM
# state in unsigned so it maps directly to the kState* localparams in market_maker.v.
#
# Run after `do run_market_maker.tcl` in the ModelSim GUI:
#   do wave_market_maker.do

add wave -divider "Clock/Reset"
add wave -radix binary   /tb_market_maker/clock
add wave -radix binary   /tb_market_maker/reset_n

add wave -divider "Engine book state (MM inputs)"
add wave -radix hex      /tb_market_maker/best_bid_price
add wave -radix unsigned /tb_market_maker/best_bid_quantity
add wave -radix binary   /tb_market_maker/best_bid_valid
add wave -radix hex      /tb_market_maker/best_ask_price
add wave -radix unsigned /tb_market_maker/best_ask_quantity
add wave -radix binary   /tb_market_maker/best_ask_valid

add wave -divider "Engine trade bus (MM snoop)"
add wave -radix binary   /tb_market_maker/trade_valid
add wave -radix hex      /tb_market_maker/trade_aggressor_id
add wave -radix hex      /tb_market_maker/trade_resting_id
add wave -radix hex      /tb_market_maker/trade_price
add wave -radix unsigned /tb_market_maker/trade_quantity

add wave -divider "Mux handshake"
add wave -radix binary   /tb_market_maker/mm_order_request
add wave -radix binary   /tb_market_maker/mm_order_grant
add wave -radix binary   /tb_market_maker/noise_fire
add wave -radix binary   /tb_market_maker/noise_is_buy
add wave -radix unsigned /tb_market_maker/noise_qty
add wave -radix hex      /tb_market_maker/noise_next_id

add wave -divider "Engine order port (muxed)"
add wave -radix binary   /tb_market_maker/engine_order_valid
add wave -radix binary   /tb_market_maker/engine_order_ready
add wave -radix unsigned /tb_market_maker/engine_order_type
add wave -radix hex      /tb_market_maker/engine_order_id
add wave -radix hex      /tb_market_maker/engine_order_price
add wave -radix unsigned /tb_market_maker/engine_order_quantity

add wave -divider "MM FSM state"
add wave -radix unsigned /tb_market_maker/dut_mm/state

add wave -divider "MM order output (pre-mux)"
add wave -radix unsigned /tb_market_maker/dut_mm/order_type
add wave -radix hex      /tb_market_maker/dut_mm/order_id
add wave -radix hex      /tb_market_maker/dut_mm/order_price
add wave -radix unsigned /tb_market_maker/dut_mm/order_quantity

add wave -divider "MM derived fair/quote prices"
add wave -radix hex      /tb_market_maker/dut_mm/fair_price
add wave -radix hex      /tb_market_maker/dut_mm/last_trade_price
add wave -radix hex      /tb_market_maker/dut_mm/last_quoted_fair
add wave -radix hex      /tb_market_maker/dut_mm/new_bid_price
add wave -radix hex      /tb_market_maker/dut_mm/new_ask_price
add wave -radix decimal  /tb_market_maker/dut_mm/skew

add wave -divider "MM bookkeeping registers"
add wave -radix decimal  /tb_market_maker/dut_mm/net_inventory
add wave -radix hex      /tb_market_maker/dut_mm/active_bid_id
add wave -radix binary   /tb_market_maker/dut_mm/active_bid_valid
add wave -radix unsigned /tb_market_maker/dut_mm/active_bid_remaining
add wave -radix hex      /tb_market_maker/dut_mm/active_bid_price
add wave -radix hex      /tb_market_maker/dut_mm/active_ask_id
add wave -radix binary   /tb_market_maker/dut_mm/active_ask_valid
add wave -radix unsigned /tb_market_maker/dut_mm/active_ask_remaining
add wave -radix hex      /tb_market_maker/dut_mm/active_ask_price

add wave -divider "MM debug events"
add wave -radix binary   /tb_market_maker/dut_mm/bid_fill_event
add wave -radix binary   /tb_market_maker/dut_mm/ask_fill_event
add wave -radix binary   /tb_market_maker/dut_mm/drift_triggers_requote

configure wave -namecolwidth 280 -valuecolwidth 120 -timeline 0
update
wave zoom full
