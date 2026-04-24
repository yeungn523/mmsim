# run_market_maker.tcl
# ModelSim simulation script for the closed-loop market_maker testbench.
#
# Reads noise_events.csv from the sim/ working directory and writes run_log.csv and
# actual_orders.csv. Expects the Python orchestrator to have produced noise_events.csv first.
#
# The caller selects the market maker policy via the SKEW_ENABLE environment variable
# (0 = v1 fixed spread, 1 = v2 inventory-skewed). The default is v1 when unset.
#
# Run from ModelSim transcript (interactive with waveform):
#   cd <path_to_agents>/sim
#   do run_market_maker.tcl
#   do wave_market_maker.do
# or from the Python orchestrator (headless):
#   vsim -c -gkSkewEnable=<0|1> -do "do run_market_maker.tcl; quit -f"

if {[file exists work]} {
    vdel -lib work -all
}

vlib work

vlog -sv -work work ../../matching_engine/rtl/price_level_store.v
vlog -sv -work work ../../matching_engine/rtl/matching_engine.v
vlog -sv -work work ../rtl/market_maker.v
vlog -sv -work work ../tb/tb_market_maker.v

# Allows the caller to override kSkewEnable via environment variable when the -g<param> flag is
# not already supplied on the vsim command line.
set skew_enable 0
if {[info exists ::env(SKEW_ENABLE)]} {
    set skew_enable $::env(SKEW_ENABLE)
}

if {[catch {vsim -t 1ns -novopt -gkSkewEnable=$skew_enable work.tb_market_maker} err]} {
    puts "Error: vsim failed: $err"
    return
}

run -all

puts ""
puts "Closed-loop market maker simulation complete."
puts "  Input:  noise_events.csv"
puts "  Output: run_log.csv"
puts "  Output: actual_orders.csv"
