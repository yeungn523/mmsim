# run_gaussian.tcl

if {[file exists work]} {
    vdel -lib work -all
}

vlib work

vlog -work work ../../lfsr/galois_lfsr.v
vlog -work work -sv ../rtl/clt12_gaussian.v
vlog -work work -sv ../rtl/ziggurat_gaussian.v
vlog -work work -sv ../tb/tb_gaussian_comparison.v

if {[catch {vsim -t 1ns -novopt work.tb_gaussian_comparison} err]} {
    puts "ERROR: vsim failed: $err"
    return
}

add wave -divider "Clock / Reset"
add wave /tb_gaussian_comparison/clk
add wave /tb_gaussian_comparison/rst_n

add wave -divider "CLT-12"
add wave /tb_gaussian_comparison/en_clt
add wave -radix decimal /tb_gaussian_comparison/clt_out
add wave /tb_gaussian_comparison/clt_valid
add wave -radix decimal /tb_gaussian_comparison/clt_count

add wave -divider "Ziggurat"
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

add wave -divider "Ziggurat Internals"
add wave -radix hex /tb_gaussian_comparison/dut_zig/x_layer
add wave -radix hex /tb_gaussian_comparison/dut_zig/x_layer_m1
add wave -radix hex /tb_gaussian_comparison/dut_zig/y_layer
add wave -radix hex /tb_gaussian_comparison/dut_zig/y_layer_m1

run -all

puts ""
puts "Simulation complete."
puts "  clt12_samples.csv:       Python cross-checker"
puts "  ziggurat_samples.csv:    Python cross-checker"
puts "  gaussian_comparison.vcd: waveform viewer"
