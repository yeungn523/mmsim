# run_sweep.tcl
#
# Usage: vsim -do run_sweep.tcl    (from this directory)
#        do run_sweep.tcl          (from an open ModelSim session)

set ROOT [file normalize [file join [pwd] .. ..]]
set DESIGN  [file join [pwd] sweep design_remaining.csv]
set RESULTS [file join [pwd] sweep results.csv]

if {![file exists $DESIGN]} {
    puts "ERROR: design file not found: $DESIGN"
    return
}

# Recreates the work library to drop stale compilations.
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

# Compiles the testbench last.
vlog -work work $ROOT/top_level/tb/tb_sim_top.v

# Reads the header so column lookup is robust to ordering.
set fp [open $DESIGN r]
gets $fp header_line
set header [split $header_line ","]

array set col {}
set idx 0
foreach name $header {
    set col($name) $idx
    incr idx
}

# Walks each row, launches a fresh sim, and runs to $finish.
set row_num 0
while {[gets $fp line] >= 0} {
    if {[string trim $line] eq ""} continue
    set fields [split $line ","]
    set tag    [lindex $fields $col(tag)]

    set plusargs [list \
        +OUT_TAG=$tag \
        +SUMMARY_PATH=$RESULTS \
        +P1_NOISE=[lindex $fields $col(p1_noise)] \
        +P2_NOISE=[lindex $fields $col(p2_noise)] \
        +P3_NOISE=[lindex $fields $col(p3_noise)] \
        +P1_MM=[lindex $fields $col(p1_mm)] \
        +P2_MM=[lindex $fields $col(p2_mm)] \
        +P3_MM=[lindex $fields $col(p3_mm)] \
        +P1_MOM=[lindex $fields $col(p1_mom)] \
        +P2_MOM=[lindex $fields $col(p2_mom)] \
        +P3_MOM=[lindex $fields $col(p3_mom)] \
        +P1_VAL=[lindex $fields $col(p1_val)] \
        +P2_VAL=[lindex $fields $col(p2_val)] \
        +P3_VAL=[lindex $fields $col(p3_val)] \
        +RUN_CYCLES=[lindex $fields $col(run_cycles)] \
    ]

    puts "=== sweep row $row_num : $tag ==="

    # Loads the testbench with the Altera model libraries.
    eval vsim -t 1ns -lib work -L altera_mf_ver tb_sim_top $plusargs

    run -all
    incr row_num
}

close $fp
puts "=== sweep complete ($row_num rows) ==="
