# =============================================================================
# run_gbm.tcl
# ModelSim/Questa simulation script for GBM comparison
# =============================================================================

set LIB_NAME work
set TB_TOP   tb_gbm_comparison

# Create work library
if { [file exists $LIB_NAME] } {
    vdel -lib $LIB_NAME -all
}
vlib $LIB_NAME
vmap work $LIB_NAME

# Compile source files
set compile_ok 1

if { [catch {vlog -sv -work work +incdir+. gbm_euler.v}]          } { set compile_ok 0 }
if { [catch {vlog -sv -work work +incdir+. gbm_logspace.v}]       } { set compile_ok 0 }
if { [catch {vlog -sv -work work +incdir+. tb_gbm_comparison.v}]  } { set compile_ok 0 }

if { !$compile_ok } {
    puts "ERROR: Compilation failed"
    return
}

# Load simulation
vsim -t 1ps -lib work -voptargs="+acc" $TB_TOP

# Waveform setup
add wave -divider "Clock / Reset"
add wave -radix binary      /tb_gbm_comparison/clk
add wave -radix binary      /tb_gbm_comparison/rst_n

add wave -divider "Z Stimulus"
add wave -radix binary      /tb_gbm_comparison/z_valid_euler
add wave -radix decimal     /tb_gbm_comparison/z_in_euler

add wave -divider "Euler DUT"
add wave -radix binary      /tb_gbm_comparison/price_valid_euler
add wave -radix hexadecimal /tb_gbm_comparison/price_out_euler
add wave -radix hexadecimal /tb_gbm_comparison/sigma_out_euler
add wave -radix unsigned    /tb_gbm_comparison/dut_euler/state

add wave -divider "Log-Space DUT"
add wave -radix binary      /tb_gbm_comparison/price_valid_log
add wave -radix hexadecimal /tb_gbm_comparison/price_out_log
add wave -radix hexadecimal /tb_gbm_comparison/sigma_out_log
add wave -radix unsigned    /tb_gbm_comparison/dut_log/state

add wave -divider "TB Counters"
add wave -radix unsigned    /tb_gbm_comparison/euler_count
add wave -radix unsigned    /tb_gbm_comparison/log_count
add wave -radix unsigned    /tb_gbm_comparison/error_count
add wave -radix unsigned    /tb_gbm_comparison/cycle_count

run -all