# run_sim_top.tcl

set ROOT "C:/Users/gaa59/Desktop/mmsim/src/mmsim"

# Recreates and maps the work library.
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

# Compiles RTL dependencies in bottom-up order so each module sees its leaves.
vlog -work work $ROOT/lfsr/rtl/galois_lfsr.v
vlog -work work $ROOT/gaussian/rtl/ziggurat_gaussian.v
vlog -work work $ROOT/gbm/rtl/gbm_logspace.v
vlog -work work $ROOT/matching_engine/rtl/price_level_store.v
vlog -work work $ROOT/matching_engine/rtl/matching_engine.v
vlog -work work $ROOT/order_generation/rtl/order_arbiter.v
vlog -work work $ROOT/order_generation/rtl/order_fifo.v
vlog -work work $ROOT/order_generation/rtl/order_gen_top.v
vlog -work work $ROOT/agents/rtl/agent_execution_unit.v
vlog -work work $ROOT/top_level/rtl/top_level.v

# Compiles the testbench last.
vlog -work work $ROOT/top_level/tb/tb_sim_top.v

# Loads the testbench into the simulator with 1 ns timestep.
vsim -t 1ns -lib work -L altera_mf_ver tb_sim_top

# Logs all signals for post-run analysis.
log -r /*

# Configures the wave window.
add wave -divider "Clock / Reset"
add wave -hex clk
add wave -hex rst_n
add wave -divider "HPS Controls"
add wave -hex active_agent_count
add wave -hex param_wr_en
add wave -hex param_wr_addr
add wave -hex param_wr_data
add wave -divider "FIFO Interface"
add wave -hex u_order_gen/u_fifo/full
add wave -divider "Matching Engine State"
add wave -hex u_matching_engine/b_state
add wave -hex u_matching_engine/c_state
add wave -hex u_matching_engine/b_to_c_valid
add wave -hex /tb_sim_top/in_flight_count
add wave -divider "Top of Book"
add wave -hex best_bid_price
add wave -hex best_bid_quantity
add wave -hex best_bid_valid
add wave -hex best_ask_price
add wave -hex best_ask_quantity
add wave -hex best_ask_valid
add wave -divider "Trade Bus"
add wave -hex trade_valid
add wave -hex trade_price
add wave -hex trade_quantity
add wave -hex trade_side
add wave -hex last_executed_price
add wave -hex last_executed_price_valid
add wave -divider "Retire Bus"
add wave -hex order_retire_valid
add wave -hex order_retire_trade_count
add wave -hex order_retire_fill_quantity
add wave -divider "Invariant State"
add wave -hex invariants_active
add wave -hex in_flight_count
add wave -hex accumulated_fill
add wave -hex total_crosses_missed
add wave -hex total_phantom_valid
add wave -hex total_fifo_full_events
add wave -hex total_conservation_errors
add wave -hex total_invalid_trade_price

# Runs the simulation to completion.
run -all

# Prints the invariant summary to the transcript.
echo ""
echo "========================================"
echo "Invariant Summary"
echo "========================================"
echo "Crossed book events    : [examine -radix decimal sim:/tb_sim_top/total_crosses_missed]"
echo "Phantom valid events   : [examine -radix decimal sim:/tb_sim_top/total_phantom_valid]"
echo "FIFO full events       : [examine -radix decimal sim:/tb_sim_top/total_fifo_full_events]"
echo "Conservation errors    : [examine -radix decimal sim:/tb_sim_top/total_conservation_errors]"
echo "Invalid trade price    : [examine -radix decimal sim:/tb_sim_top/total_invalid_trade_price]"
echo "Max in-flight          : [examine -radix decimal sim:/tb_sim_top/max_in_flight]"
echo "Hostile HPS writes     : [examine -radix decimal sim:/tb_sim_top/hostile_writes]"
echo "========================================"
