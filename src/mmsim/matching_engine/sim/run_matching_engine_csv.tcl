# run_matching_engine_csv.tcl
#
# Usage: vsim -do run_matching_engine_csv.tcl    (from this directory)
#        do run_matching_engine_csv.tcl          (from an open ModelSim session)

# Recreates the work library to drop stale compilations.
if {[file exists work]} {
    vdel -lib work -all
}
vlib work

# Compiles the price level store, matching engine RTL, and the CSV-driven testbench.
vlog -sv -work work ../rtl/price_level_store.v
vlog -sv -work work ../rtl/matching_engine.v
vlog -sv -work work ../tb/tb_matching_engine_csv.v

# Loads the testbench into the simulator and aborts on failure.
if {[catch {vsim -t 1ns -novopt work.tb_matching_engine_csv} err]} {
    puts "Error: vsim failed: $err"
    return
}

# Runs the simulation; the testbench replays the packet CSV and writes the actual-output CSVs.
run -all

puts ""
puts "CSV replay complete."
puts "  Input:  matching_engine_packets.csv"
puts "  Output: matching_engine_actual.csv"
puts "  Output: matching_engine_trades_actual.csv"
