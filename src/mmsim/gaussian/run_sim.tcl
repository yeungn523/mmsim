# run_sim.tcl
# ModelSim simulation script for Gaussian generator comparison
# Real Ziggurat (ROM-based) vs CLT-12
#
# Prerequisites:
#   1. Run gen_ziggurat_tables.py to generate ziggurat_tables.vh and ziggurat_tables.mif
#   2. Ensure ziggurat_tables.vh is in the same directory as ziggurat_gaussian.v
#
# Run from ModelSim transcript:
#   do run_sim.tcl

# Clean up previous runs
if {[file exists work]} {
    vdel -lib work -all
}

# Create work library
vlib work

# Compile in dependency order
# ziggurat_tables.vh is `included by ziggurat_gaussian.v - no separate compile needed
vlog -work work galois_lfsr.v
vlog -work work -sv clt12_gaussian.v
vlog -work work -sv ziggurat_gaussian.v
vlog -work work -sv tb_gaussian_comparison.v

# Check for compile errors
if {[catch {vsim -t 1ns -novopt work.tb_gaussian_comparison} err]} {
    puts "ERROR: vsim failed: $err"
    return
}

# Waveforms
add wave -divider "=== Clock / Reset ==="
add wave /tb_gaussian_comparison/clk
add wave /tb_gaussian_comparison/rst_n

add wave -divider "=== CLT-12 ==="
add wave /tb_gaussian_comparison/en_clt
add wave -radix decimal /tb_gaussian_comparison/clt_out
add wave /tb_gaussian_comparison/clt_valid
add wave -radix decimal /tb_gaussian_comparison/clt_count

add wave -divider "=== Ziggurat ==="
add wave /tb_gaussian_comparison/en_zig
add wave /tb_gaussian_comparison/dut_zig/state
add wave -radix decimal /tb_gaussian_comparison/dut_zig/layer
add wave -radix hex     /tb_gaussian_comparison/dut_zig/rom_addr
add wave -radix hex     /tb_gaussian_comparison/dut_zig/rom_data_out
add wave -radix decimal /tb_gaussian_comparison/dut_zig/x_candidate
add wave /tb_gaussian_comparison/dut_zig/sign_bit
add wave -radix decimal /tb_gaussian_comparison/zig_out
add wave /tb_gaussian_comparison/zig_valid
add wave -radix decimal /tb_gaussian_comparison/zig_count

add wave -divider "=== Ziggurat Internals ==="
add wave -radix hex /tb_gaussian_comparison/dut_zig/x_layer
add wave -radix hex /tb_gaussian_comparison/dut_zig/x_layer_m1
add wave -radix hex /tb_gaussian_comparison/dut_zig/y_layer
add wave -radix hex /tb_gaussian_comparison/dut_zig/y_layer_m1

run -all

puts ""
puts "================================================"
puts "Simulation complete."
puts "  clt12_samples.csv     -> Python cross-checker"
puts "  ziggurat_samples.csv  -> Python cross-checker"
puts "  gaussian_comparison.vcd -> waveform viewer"
puts "================================================"