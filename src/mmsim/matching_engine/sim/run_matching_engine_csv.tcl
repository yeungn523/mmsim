# run_matching_engine_csv.tcl
#
# Usage: vsim -do run_matching_engine_csv.tcl    (from this directory)
#        do run_matching_engine_csv.tcl          (from an open ModelSim session)

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
puts "  Input:  matching_engine_packets.csv"
puts "  Output: matching_engine_actual.csv"
puts "  Output: matching_engine_trades_actual.csv"
