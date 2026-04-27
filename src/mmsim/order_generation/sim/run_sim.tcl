# ---------------------------------------------------------------------------
# run_sim.tcl
# Run from: order_generation/sim/   (TCL lives here, sources are in ../)
# Usage:    vsim -c -do run_sim.tcl
# ---------------------------------------------------------------------------

# 1. Setup library
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# 2. Compile
vlog -reportprogress 300 -vlog01compat -work work ../rtl/order_arbiter.v
vlog -reportprogress 300 -vlog01compat -work work ../tb/tb_order_arbiter.v

# 3. Load simulation
vsim -voptargs="+acc" \
     -L altera_mf_ver \
     -L 220model_ver \
     work.tb_order_arbiter

# 4. Add waves — only when running in GUI (ModelSim interactive, not -c mode)
#    catch lets this block fail silently in batch/headless mode
catch {
    add wave -divider "System"
    add wave -color Yellow /tb_order_arbiter/clk
    add wave -color Yellow /tb_order_arbiter/rst_n

    add wave -divider "Inputs"
    add wave -hex /tb_order_arbiter/order_valid_in
    add wave -hex /tb_order_arbiter/order_packet_in

    add wave -divider "Stall Rails"
    add wave -color Red /tb_order_arbiter/fifo_almost_full
    add wave -color Red /tb_order_arbiter/fifo_full

    add wave -divider "Arbiter Outputs"
    add wave -hex  /tb_order_arbiter/order_granted
    add wave -color Cyan /tb_order_arbiter/fifo_wr_en
    add wave -hex  /tb_order_arbiter/fifo_din

    add wave -divider "Internal State"
    add wave -unsigned /tb_order_arbiter/dut/grant_pointer
    add wave -hex      /tb_order_arbiter/dut/next_grant
    add wave           /tb_order_arbiter/dut/found
}

# 5. Run simulation — TB writes arbiter_log.csv then calls $finish
run -all

# 6. Python verification — arbiter_log.csv written to sim/ (cwd)
if {[file exists arbiter_log.csv]} {
    puts "--- Starting Python Verification ---"
    catch {exec python3 ../python_verification/golden_order_arbiter.py arbiter_log.csv} result
    puts $result
} else {
    puts "ERROR: arbiter_log.csv not found — simulation may have failed before $fclose"
}