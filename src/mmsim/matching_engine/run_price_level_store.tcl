# run_price_level_store.tcl
# ModelSim simulation script for the price_level_store unit testbench.
#
# Run from ModelSim transcript:
#   cd <path_to_matching_engine>
#   do run_price_level_store.tcl

if {[file exists work]} {
    vdel -lib work -all
}

vlib work

vlog -work work price_level_store.v
vlog -work work -sv price_level_store_sva.sv
vlog -work work -sv tb_price_level_store.v

if {[catch {vsim -t 1ns -novopt work.tb_price_level_store} err]} {
    puts "Error: vsim failed: $err"
    return
}

add wave -divider "Clock / Reset"
add wave /tb_price_level_store/clock
add wave /tb_price_level_store/reset_n

add wave -divider "Command"
add wave -radix unsigned /tb_price_level_store/command
add wave -radix unsigned /tb_price_level_store/command_price
add wave -radix unsigned /tb_price_level_store/command_quantity
add wave -radix unsigned /tb_price_level_store/command_order_id
add wave /tb_price_level_store/command_valid
add wave /tb_price_level_store/command_ready

add wave -divider "Response"
add wave -radix unsigned /tb_price_level_store/response_order_id
add wave -radix unsigned /tb_price_level_store/response_quantity
add wave /tb_price_level_store/response_valid
add wave /tb_price_level_store/response_found

add wave -divider "Top of Book"
add wave -radix unsigned /tb_price_level_store/best_price
add wave -radix unsigned /tb_price_level_store/best_quantity
add wave /tb_price_level_store/best_valid
add wave /tb_price_level_store/full

add wave -divider "FSM"
add wave -radix unsigned /tb_price_level_store/dut_bid/state
add wave -radix unsigned /tb_price_level_store/dut_bid/level_count
add wave -radix unsigned /tb_price_level_store/dut_bid/free_pointer

run -all

puts ""
puts "Simulation complete. Results printed above."
puts "  price_level_store_tb.vcd -> waveform viewer"
