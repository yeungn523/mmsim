# run_matching_engine.tcl
# ModelSim simulation script for the matching_engine unit testbench.
#
# Run from ModelSim transcript:
#   cd <path_to_matching_engine>
#   do run_matching_engine.tcl

if {[file exists work]} {
    vdel -lib work -all
}

vlib work

vlog -sv -work work price_level_store.v
# vlog -work work -sv price_level_store_sva.sv
vlog -sv -work work matching_engine.v
vlog -work work -sv tb_matching_engine.v

if {[catch {vsim -t 1ns -novopt work.tb_matching_engine} err]} {
    puts "Error: vsim failed: $err"
    return
}

add wave -divider "Clock / Reset"
add wave /tb_matching_engine/clock
add wave /tb_matching_engine/reset_n

add wave -divider "Order Input"
add wave -radix unsigned /tb_matching_engine/order_type
add wave -radix unsigned /tb_matching_engine/order_id
add wave -radix unsigned /tb_matching_engine/order_price
add wave -radix unsigned /tb_matching_engine/order_quantity
add wave /tb_matching_engine/order_valid
add wave /tb_matching_engine/order_ready

add wave -divider "Trade Output"
add wave -radix unsigned /tb_matching_engine/trade_aggressor_id
add wave -radix unsigned /tb_matching_engine/trade_resting_id
add wave -radix unsigned /tb_matching_engine/trade_price
add wave -radix unsigned /tb_matching_engine/trade_quantity
add wave /tb_matching_engine/trade_valid

add wave -divider "Top of Book"
add wave -radix unsigned /tb_matching_engine/best_bid_price
add wave -radix unsigned /tb_matching_engine/best_bid_quantity
add wave /tb_matching_engine/best_bid_valid
add wave -radix unsigned /tb_matching_engine/best_ask_price
add wave -radix unsigned /tb_matching_engine/best_ask_quantity
add wave /tb_matching_engine/best_ask_valid

add wave -divider "Engine FSM"
add wave -radix unsigned /tb_matching_engine/dut/state
add wave /tb_matching_engine/dut/working_is_buy
add wave /tb_matching_engine/dut/working_is_market
add wave -radix unsigned /tb_matching_engine/dut/working_remaining

add wave -divider "Statistics"
add wave -radix unsigned /tb_matching_engine/total_trades
add wave -radix unsigned /tb_matching_engine/total_volume

run -all

puts ""
puts "Simulation complete. Results printed above."
puts "  matching_engine_tb.vcd -> waveform viewer"
