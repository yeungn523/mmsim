# run_price_level_store_csv.tcl
# ModelSim simulation script for the CSV-driven price_level_store testbench.
#
# Reads lob_commands.csv from the sim/ working directory and writes lob_actual.csv.
# Expects the golden model to have produced lob_commands.csv first.
#
# Run from ModelSim transcript:
#   cd <path_to_matching_engine>/sim
#   do run_price_level_store_csv.tcl

if {[file exists work]} {
    vdel -lib work -all
}

vlib work

vlog -sv -work work ../rtl/price_level_store.v
vlog -sv -work work ../tb/tb_price_level_store_csv.v

if {[catch {vsim -t 1ns -novopt work.tb_price_level_store_csv} err]} {
    puts "Error: vsim failed: $err"
    return
}

run -all

puts ""
puts "CSV replay complete."
puts "  Input:  lob_commands.csv"
puts "  Output: lob_actual.csv"
