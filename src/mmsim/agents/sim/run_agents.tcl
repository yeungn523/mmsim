# run_agents.tcl
#
# Usage: vsim -do run_agents.tcl    (from this directory)
#        do run_agents.tcl          (from an open ModelSim session)

# Quits any existing simulation so re-runs start from a clean slate.
if {[catch {simstats}] == 0} {
    quit -sim
}

# Recreates the work library to drop stale compilations.
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# Compiles dependencies first, then the testbench last.
puts "========================================="
puts "Compiling source files..."
puts "========================================="

vlog galois_lfsr.v
vlog agent_execution_unit.v
vlog agent_execution_unit_tb.v

puts "All files compiled successfully."

# Loads the testbench into the simulator with 1 ps timestep.
puts "========================================="
puts "Loading simulation..."
puts "========================================="

vsim -t 1ps \
     -lib work \
     agent_execution_unit_tb

# Adds debug waves. Comment this section out to skip the wave window and emit only the CSV.
add wave -divider "Clock / Reset"
add wave -radix binary     /agent_execution_unit_tb/clk
add wave -radix binary     /agent_execution_unit_tb/rst_n

add wave -divider "FSM State"
add wave -radix symbolic   /agent_execution_unit_tb/dut/state

add wave -divider "Inputs"
add wave -radix hex        /agent_execution_unit_tb/gbm_price
add wave -radix hex        /agent_execution_unit_tb/param_data
add wave -radix unsigned   /agent_execution_unit_tb/active_agent_count
add wave -radix unsigned   /agent_execution_unit_tb/phase

add wave -divider "LFSR"
add wave -radix hex        /agent_execution_unit_tb/dut/lfsr_out

add wave -divider "DSP Pipeline"
add wave -radix unsigned   /agent_execution_unit_tb/dut/dsp_a
add wave -radix unsigned   /agent_execution_unit_tb/dut/dsp_b
add wave -radix unsigned   /agent_execution_unit_tb/dut/dsp_product

add wave -divider "Execute Stage Registers"
add wave -radix binary     /agent_execution_unit_tb/dut/emit_flag
add wave -radix binary     /agent_execution_unit_tb/dut/calc_side
add wave -radix unsigned   /agent_execution_unit_tb/dut/calc_volume
add wave -radix unsigned   /agent_execution_unit_tb/dut/calc_agent_type

add wave -divider "Combinational Assembly"
add wave -radix unsigned   /agent_execution_unit_tb/dut/offset_raw
add wave -radix unsigned   /agent_execution_unit_tb/dut/offset_ticks
add wave -radix unsigned   /agent_execution_unit_tb/dut/final_price
add wave -radix binary     /agent_execution_unit_tb/dut/calc_order_type
add wave -radix unsigned   /agent_execution_unit_tb/dut/gbm_tick

add wave -divider "Output"
add wave -radix binary     /agent_execution_unit_tb/order_valid
add wave -radix hex        /agent_execution_unit_tb/order_packet

add wave -divider "Slot Counter"
add wave -radix unsigned   /agent_execution_unit_tb/dut/slot_counter

add wave -divider "Exec Price Shift Reg"
add wave -radix hex        /agent_execution_unit_tb/dut/executed_price_shift_reg_0
add wave -radix hex        /agent_execution_unit_tb/dut/executed_price_shift_reg_1
add wave -radix hex        /agent_execution_unit_tb/dut/executed_price_shift_reg_2
add wave -radix hex        /agent_execution_unit_tb/dut/executed_price_shift_reg_3

# Configures the wave window column widths and units.
configure wave -namecolwidth  250
configure wave -valuecolwidth 120
configure wave -signalnamewidth 1
configure wave -timelineunits ns

# Runs the simulation to completion.
puts "========================================="
puts "Running simulation..."
puts "========================================="

run -all

# Zooms the wave window to fit and prints the result location.
wave zoom full

puts "========================================="
puts "Simulation complete."
puts "CSV output: sim_output.csv"
puts "Next step : python agents_verify.py"
puts "========================================="
