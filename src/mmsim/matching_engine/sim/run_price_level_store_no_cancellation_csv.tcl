# run_price_level_store_no_cancellation_csv.tcl
# ModelSim simulation script for the CSV-driven price_level_store_no_cancellation testbench.
#
# Reads lob_no_cancellation_commands.csv from the sim/ working directory and writes
# lob_no_cancellation_actual.csv. Expects the golden model to have produced the commands
# CSV first.
#
# Run from ModelSim transcript:
#   cd <path_to_matching_engine>/sim
#   do run_price_level_store_no_cancellation_csv.tcl
# Or headless via the orchestrator:
#   vsim -c -do "do run_price_level_store_no_cancellation_csv.tcl; quit -f"

if {[file exists work]} {
    vdel -lib work -all
}

vlib work

vlog -sv -work work ../rtl/price_level_store.v
vlog -sv -work work ../tb/tb_price_level_store_no_cancellation_csv.v

if {[catch {vsim -t 1ns -novopt work.tb_price_level_store_no_cancellation_csv} err]} {
    puts "Error: vsim failed: $err"
    return
}

run -all

puts ""
puts "CSV replay complete."
puts "  Input:  lob_no_cancellation_commands.csv"
puts "  Output: lob_no_cancellation_actual.csv"
