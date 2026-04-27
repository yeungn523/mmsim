# ---------------------------------------------------------------------------
# run_sim_top.tcl
# Run from: order_gen/sim/
# Usage:    vsim -c -do run_sim_top.tcl
# ---------------------------------------------------------------------------

if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# Compile all source files — order matters (leaves before top)
vlog -reportprogress 300 -vlog01compat -work work ../galois_lfsr.v
vlog -reportprogress 300 -vlog01compat -work work ../ziggurat_gaussian.v
vlog -reportprogress 300 -vlog01compat -work work ../gbm_logspace.v
vlog -reportprogress 300 -vlog01compat -work work ../agent_execution_unit.v
vlog -reportprogress 300 -vlog01compat -work work ../order_arbiter.v
vlog -reportprogress 300 -vlog01compat -work work ../order_fifo.v
vlog -reportprogress 300 -vlog01compat -work work ../order_gen_top.v
vlog -reportprogress 300 -vlog01compat -work work ../tb_order_gen_top.v

# Load simulation with Altera libraries
vsim -voptargs="+acc" \
     -L altera_mf_ver \
     -L 220model_ver \
     work.tb_order_gen_top

# Waves — GUI only, silent in batch
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
    add wave -divider "FIFO"
    add wave      /tb_order_gen_top/dut/arb_fifo_wr_en
    add wave -hex /tb_order_gen_top/dut/arb_fifo_din
    add wave      /tb_order_gen_top/fifo_empty
    add wave      /tb_order_gen_top/fifo_rd_en
    add wave -hex /tb_order_gen_top/fifo_dout
    add wave -divider "Controls"
    add wave -unsigned /tb_order_gen_top/active_agent_count
    add wave           /tb_order_gen_top/phase
}

run -all

if {[file exists top_log.csv]} {
    puts "--- Starting Python Verification ---"
    catch {exec python ../golden_order_gen_top.py top_log.csv} result
    puts $result
} else {
    puts "ERROR: top_log.csv not found"
}