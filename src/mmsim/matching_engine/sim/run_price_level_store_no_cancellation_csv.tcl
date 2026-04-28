# run_price_level_store_no_cancellation_csv.tcl
#
# Usage: vsim -do run_price_level_store_no_cancellation_csv.tcl    (from this directory)
#        do run_price_level_store_no_cancellation_csv.tcl          (from an open ModelSim session)

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
