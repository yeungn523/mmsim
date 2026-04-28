# run_order_generation.tcl
#
# Usage: vsim -do run_order_generation.tcl    (from this directory)
#        do run_order_generation.tcl          (from an open ModelSim session)

# Recreates the work library to drop stale compilations.
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# Compiles the arbiter RTL and its testbench.
vlog -reportprogress 300 -vlog01compat -work work ../rtl/order_arbiter.v
vlog -reportprogress 300 -vlog01compat -work work ../tb/tb_order_arbiter.v

# Loads the testbench with the Altera model libraries.
vsim -voptargs="+acc" \
     -L altera_mf_ver \
     -L 220model_ver \
     work.tb_order_arbiter

# Adds debug waves; the catch lets this block fail silently in batch/headless mode where the
# wave window is unavailable.
catch {
    add wave -divider "System"
    add wave -color Yellow /tb_order_arbiter/clk
    add wave -color Yellow /tb_order_arbiter/rst_n

    add wave -divider "Inputs"
    add wave -hex /tb_order_arbiter/order_valid_in
    add wave -hex /tb_order_arbiter/order_packet_in

    add wave -divider "Backpressure"
    add wave -color Red /tb_order_arbiter/order_ready

    add wave -divider "Arbiter Outputs"
    add wave -hex  /tb_order_arbiter/order_granted
    add wave -color Cyan /tb_order_arbiter/order_valid
    add wave -hex  /tb_order_arbiter/order_packet

    add wave -divider "Internal State"
    add wave -unsigned /tb_order_arbiter/dut/grant_pointer
    add wave -hex      /tb_order_arbiter/dut/next_grant
    add wave           /tb_order_arbiter/dut/found
}

# Runs the simulation; the testbench writes arbiter_log.csv and then calls $finish.
run -all

# Hands the captured CSV off to the Python golden model for verification.
if {[file exists arbiter_log.csv]} {
    puts "--- Starting Python Verification ---"
    catch {exec python3 ../python_verification/order_arbiter_verify.py arbiter_log.csv} result
    puts $result
} else {
    puts "ERROR: arbiter_log.csv not found — simulation may have failed before $fclose"
}