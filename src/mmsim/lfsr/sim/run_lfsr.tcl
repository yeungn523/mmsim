# run_lfsr.tcl
#
# Usage: vsim -do run_lfsr.tcl    (from this directory)
#        do run_lfsr.tcl          (from an open ModelSim session)

# Recreates the work library to drop stale compilations.
vlib work

# Compiles the LFSR RTL and its testbench.
vlog -work work galois_lfsr.v
vlog -sv -work work tb_galois_lfsr.v

# Loads the testbench into the simulator with 1 ns timestep.
vsim -t 1ns -novopt work.tb_galois_lfsr

# Adds debug waves for the control signals and the LFSR output.
add wave -divider "Control"
add wave /tb_galois_lfsr/clk
add wave /tb_galois_lfsr/rst_n
add wave /tb_galois_lfsr/en
add wave /tb_galois_lfsr/seed_valid
add wave -radix hex /tb_galois_lfsr/seed_load

add wave -divider "LFSR Output"
add wave -radix hex /tb_galois_lfsr/out
add wave -radix unsigned /tb_galois_lfsr/dut/out

# Runs the simulation to completion.
run -all