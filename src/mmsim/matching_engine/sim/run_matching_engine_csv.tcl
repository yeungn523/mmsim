# run_matching_engine_csv.tcl
# ModelSim simulation script for the CSV-driven matching_engine testbench.
#
# Reads matching_engine_orders.csv from the sim/ working directory and writes
# matching_engine_trades_actual.csv and matching_engine_book_state_actual.csv.
# Expects the golden model to have produced matching_engine_orders.csv first.
#
# Run from ModelSim transcript:
#   cd <path_to_matching_engine>/sim
#   do run_matching_engine_csv.tcl

if {[file exists work]} {
    vdel -lib work -all
}

vlib work

vlog -sv -work work ../rtl/price_level_store.v
vlog -sv -work work ../rtl/matching_engine.v
vlog -sv -work work ../tb/tb_matching_engine_csv.v

if {[catch {vsim -t 1ns -novopt work.tb_matching_engine_csv} err]} {
    puts "Error: vsim failed: $err"
    return
}

run -all

puts ""
puts "CSV replay complete."
puts "  Input:  matching_engine_orders.csv"
puts "  Output: matching_engine_trades_actual.csv"
puts "  Output: matching_engine_book_state_actual.csv"
