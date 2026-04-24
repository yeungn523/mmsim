# run_sim.tcl
# ModelSim automation script for agent_execution_unit verification

# =====================================================================
# 0. Quit any existing simulation cleanly
# =====================================================================
if {[catch {simstats}] == 0} {
    quit -sim
}

# =====================================================================
# 1. Create/recreate work library
# =====================================================================
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# =====================================================================
# 2. Compile source files
#    Order: dependencies first, TB last
# =====================================================================
puts "========================================="
puts "Compiling source files..."
puts "========================================="

vlog galois_lfsr.v
vlog agent_execution_unit.v
vlog agent_execution_unit_tb.v

puts "All files compiled successfully."

# =====================================================================
# 3. Load simulation
# =====================================================================
puts "========================================="
puts "Loading simulation..."
puts "========================================="

vsim -t 1ps \
     -lib work \
     agent_execution_unit_tb

# =====================================================================
# 4. Optional: add waves for debugging
#    Comment this section out if you just want the CSV and no wave window
# =====================================================================
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
add wave -radix hex        /agent_execution_unit_tb/dut/exec_price_shift_reg_0
add wave -radix hex        /agent_execution_unit_tb/dut/exec_price_shift_reg_1
add wave -radix hex        /agent_execution_unit_tb/dut/exec_price_shift_reg_2
add wave -radix hex        /agent_execution_unit_tb/dut/exec_price_shift_reg_3

# =====================================================================
# 5. Configure wave window
# =====================================================================
configure wave -namecolwidth  250
configure wave -valuecolwidth 120
configure wave -signalnamewidth 1
configure wave -timelineunits ns

# =====================================================================
# 6. Run simulation to completion
# =====================================================================
puts "========================================="
puts "Running simulation..."
puts "========================================="

run -all

# =====================================================================
# 7. Zoom wave window to fit and print result location
# =====================================================================
wave zoom full

puts "========================================="
puts "Simulation complete."
puts "CSV output: sim_output.csv"
puts "Next step : python agent_golden_model.py"
puts "========================================="