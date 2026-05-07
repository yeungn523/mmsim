# run_price_level_store_no_cancellation_csv.tcl
#
# Usage: vsim -do run_price_level_store_no_cancellation_csv.tcl    (from this directory)
#        do run_price_level_store_no_cancellation_csv.tcl          (from an open ModelSim session)

# Recreates the work library to drop stale compilations.
if {[file exists work]} {
    vdel -lib work -all
}
vlib work

# Compiles the price level store RTL and the CSV-driven testbench.
vlog -sv -work work ../rtl/price_level_store.v
vlog -sv -work work ../tb/tb_price_level_store_no_cancellation_csv.v

# Loads the testbench into the simulator and aborts on failure.
if {[catch {vsim -t 1ns -novopt work.tb_price_level_store_no_cancellation_csv} err]} {
    puts "Error: vsim failed: $err"
    return
}

# Runs the simulation; the testbench replays the command CSV and writes the actual-output CSV.
run -all

puts ""
puts "CSV replay complete."
puts "  Input:  lob_no_cancellation_commands.csv"
puts "  Output: lob_no_cancellation_actual.csv"
