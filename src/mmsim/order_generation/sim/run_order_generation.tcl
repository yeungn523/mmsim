# run_order_generation.tcl
#
# Usage: vsim -do run_order_generation.tcl    (from this directory)
#        do run_order_generation.tcl          (from an open ModelSim session)

if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# Compiles RTL dependencies leaves-first, then the testbench.
vlog -reportprogress 300 -vlog01compat -work work ../../lfsr/galois_lfsr.v
vlog -reportprogress 300 -vlog01compat -work work +incdir+../../gaussian/rtl ../../gaussian/rtl/ziggurat_gaussian.v
vlog -reportprogress 300 -vlog01compat -work work +incdir+../../gbm/rtl ../../gbm/rtl/gbm_logspace.v
vlog -reportprogress 300 -vlog01compat -work work ../../agents/rtl/agent_execution_unit.v
vlog -reportprogress 300 -vlog01compat -work work ../rtl/order_arbiter.v
vlog -reportprogress 300 -vlog01compat -work work ../rtl/order_gen_top.v
vlog -reportprogress 300 -vlog01compat -work work ../tb/tb_order_gen_top.v

# Loads the testbench with the Altera model libraries.
vsim -voptargs="+acc" \
     -L altera_mf_ver \
     -L 220model_ver \
     work.tb_order_gen_top

# Adds debug waves; the catch lets this block fail silently in batch/headless mode.
catch {
    add wave -divider "System"
    add wave /tb_order_gen_top/clk
    add wave /tb_order_gen_top/rst_n
    add wave -divider "GBM Output"
    add wave -hex /tb_order_gen_top/dut/gbm_price_out
    add wave -hex /tb_order_gen_top/dut/gbm_sigma_out
    add wave      /tb_order_gen_top/dut/gbm_price_valid
    add wave -divider "Agent Buses"
    add wave -hex /tb_order_gen_top/dut/unit_order_valid
    add wave -hex /tb_order_gen_top/dut/unit_order_packet
    add wave -hex /tb_order_gen_top/dut/unit_order_granted
    add wave -divider "Order Bus"
    add wave      /tb_order_gen_top/order_valid
    add wave      /tb_order_gen_top/order_ready
    add wave -hex /tb_order_gen_top/order_packet
    add wave -divider "Controls"
    add wave -unsigned /tb_order_gen_top/active_agent_count
    add wave           /tb_order_gen_top/phase
}

run -all

if {[file exists top_log.csv]} {
    puts "--- Starting Python Verification ---"
    catch {exec python ../python_verification/order_gen_top_verify.py top_log.csv} result
    puts $result
} else {
    puts "ERROR: top_log.csv not found"
}