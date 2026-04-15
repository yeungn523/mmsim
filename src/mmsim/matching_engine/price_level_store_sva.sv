/**
 * @file
 *
 * @brief Provides SystemVerilog assertions for the price_level_store module.
 *
 * Attaches via `bind` so the DUT source is unchanged. Verifies structural invariants
 * (sort order, bounds, conservation of order slots) and protocol invariants (handshake
 * behavior, response pulse semantics) continuously during simulation.
 *
 * Compile with ModelSim using `vlog -sv price_level_store_sva.sv` and bind to the DUT
 * from the testbench top (see tb_price_level_store.v / run_price_level_store.tcl).
 */

`timescale 1ns/1ps

module price_level_store_sva #(
    parameter kDepth         = 16,
    parameter kMaxOrders     = 64,
    parameter kPriceWidth    = 32,
    parameter kQuantityWidth = 16,
    parameter kOrderIdWidth  = 16,
    parameter kIsBid         = 1
)(
    input wire                        clk,
    input wire                        rst_n,

    input wire [2:0]                  command,
    input wire                        command_valid,
    input wire                        command_ready,
    input wire                        response_valid,
    input wire                        response_found,

    input wire [kPriceWidth-1:0]      best_price,
    input wire [kQuantityWidth-1:0]   best_quantity,
    input wire                        best_valid,
    input wire                        full,

    // Hierarchical probes into the DUT (wired through the bind)
    input wire [$clog2(kDepth):0]     level_count,
    input wire [$clog2(kMaxOrders):0] free_pointer,
    input wire [kPriceWidth-1:0]      level_price_0,
    input wire [kPriceWidth-1:0]      level_price_1,
    input wire [kQuantityWidth-1:0]   level_quantity_0,

    // Full sort-chain probe: unpacked array of all level prices for generate-loop checking.
    input wire [kPriceWidth-1:0]      level_price_array [0:kDepth-1]
);

    // Local SVA helper: checks sort-order between two adjacent levels for the side under test.
    function automatic bit is_better_price_sva(
        input [kPriceWidth-1:0] price_a,
        input [kPriceWidth-1:0] price_b
    );
        if (kIsBid) return price_a > price_b;
        else        return price_a < price_b;
    endfunction

    // Structural invariants.

    /// level_count must never exceed the configured depth.
    property p_level_count_in_range;
        @(posedge clk) disable iff (!rst_n)
            level_count <= kDepth;
    endproperty
    a_level_count_in_range: assert property (p_level_count_in_range)
        else $error("SVA: level_count=%0d exceeds kDepth=%0d", level_count, kDepth);

    /// free_pointer must never exceed kMaxOrders (free-list stack depth).
    property p_free_pointer_in_range;
        @(posedge clk) disable iff (!rst_n)
            free_pointer <= kMaxOrders;
    endproperty
    a_free_pointer_in_range: assert property (p_free_pointer_in_range)
        else $error("SVA: free_pointer=%0d exceeds kMaxOrders=%0d", free_pointer, kMaxOrders);

    /// best_valid must be exactly (level_count != 0).
    property p_best_valid_consistent;
        @(posedge clk) disable iff (!rst_n)
            best_valid == (level_count != 0);
    endproperty
    a_best_valid_consistent: assert property (p_best_valid_consistent)
        else $error("SVA: best_valid=%b but level_count=%0d", best_valid, level_count);

    /// full flag is asserted iff no free order slots remain.
    property p_full_flag_consistent;
        @(posedge clk) disable iff (!rst_n)
            full == (free_pointer == 0);
    endproperty
    a_full_flag_consistent: assert property (p_full_flag_consistent)
        else $error("SVA: full=%b but free_pointer=%0d", full, free_pointer);

    /// When the book has two or more levels, index 0 must hold a strictly more competitive
    /// price than index 1 (sort invariant between top two levels — most critical).
    property p_sort_top_two;
        @(posedge clk) disable iff (!rst_n)
            (level_count >= 2) |-> is_better_price_sva(level_price_0, level_price_1);
    endproperty
    a_sort_top_two: assert property (p_sort_top_two)
        else $error("SVA: sort violation level_price[0]=%0d level_price[1]=%0d (kIsBid=%0d)",
                    level_price_0, level_price_1, kIsBid);

    // Full sort-chain: for every adjacent pair of *active* levels, price[i] must be strictly
    // more competitive than price[i+1]. One assertion per pair via a generate loop.
    genvar gi;
    generate
        for (gi = 0; gi < kDepth - 1; gi = gi + 1) begin : g_sort_chain
            property p_sort_pair;
                @(posedge clk) disable iff (!rst_n)
                    (level_count > gi + 1) |-> is_better_price_sva(level_price_array[gi],
                                                                   level_price_array[gi + 1]);
            endproperty
            a_sort_pair: assert property (p_sort_pair)
                else $error("SVA: sort violation at level %0d/%0d (prices %0d/%0d, kIsBid=%0d)",
                            gi, gi + 1, level_price_array[gi], level_price_array[gi + 1], kIsBid);
        end
    endgenerate

    /// When the book is non-empty, the best level must have non-zero aggregate quantity.
    property p_best_quantity_nonzero;
        @(posedge clk) disable iff (!rst_n)
            best_valid |-> (best_quantity != 0);
    endproperty
    a_best_quantity_nonzero: assert property (p_best_quantity_nonzero)
        else $error("SVA: best_valid but best_quantity=0");

    // Protocol invariants.

    /// command_ready must be low while a command is in-flight — once a handshake completes,
    /// command_ready deasserts on the next cycle and stays low until the FSM returns to idle.
    property p_ready_deasserts_after_accept;
        @(posedge clk) disable iff (!rst_n)
            (command_valid && command_ready && (command != 3'd0)) |=> !command_ready;
    endproperty
    a_ready_deasserts_after_accept: assert property (p_ready_deasserts_after_accept)
        else $error("SVA: command_ready did not deassert after accepted command");

    /// response_valid must only pulse while a command is being processed (i.e., not in idle
    /// with command_ready high and no incoming command).
    property p_response_valid_only_when_busy;
        @(posedge clk) disable iff (!rst_n)
            response_valid |-> (!command_ready || command_valid);
    endproperty
    a_response_valid_only_when_busy: assert property (p_response_valid_only_when_busy)
        else $error("SVA: response_valid pulsed while idle");

    /// After reset, the book must be empty and all slots free.
    property p_reset_clears_state;
        @(posedge clk)
            $rose(rst_n) |-> (level_count == 0 && free_pointer == kMaxOrders
                              && !best_valid && !full);
    endproperty
    a_reset_clears_state: assert property (p_reset_clears_state)
        else $error("SVA: reset did not clear state (level_count=%0d free_pointer=%0d)",
                    level_count, free_pointer);

    // Coverage points.

    cp_insert_accepted: cover property (@(posedge clk) disable iff (!rst_n)
        command_valid && command_ready && command == 3'd1);
    cp_consume_accepted: cover property (@(posedge clk) disable iff (!rst_n)
        command_valid && command_ready && command == 3'd2);
    cp_cancel_accepted: cover property (@(posedge clk) disable iff (!rst_n)
        command_valid && command_ready && command == 3'd3);
    cp_full_asserted: cover property (@(posedge clk) disable iff (!rst_n) full);
    cp_cancel_not_found: cover property (@(posedge clk) disable iff (!rst_n)
        response_valid && !response_found);
    cp_deep_book: cover property (@(posedge clk) disable iff (!rst_n)
        level_count >= (kDepth - 1));

endmodule


/**
 * @brief Bind wrapper that attaches the SVA checker to every price_level_store instance.
 *
 * Place this bind in a testbench top or in its own compilation unit; ModelSim will attach
 * the checker hierarchically without modifying the DUT.
 */
bind price_level_store price_level_store_sva #(
    .kDepth         (kDepth),
    .kMaxOrders     (kMaxOrders),
    .kPriceWidth    (kPriceWidth),
    .kQuantityWidth (kQuantityWidth),
    .kOrderIdWidth  (kOrderIdWidth),
    .kIsBid         (kIsBid)
) sva_inst (
    .clk              (clk),
    .rst_n            (rst_n),
    .command          (command),
    .command_valid    (command_valid),
    .command_ready    (command_ready),
    .response_valid   (response_valid),
    .response_found   (response_found),
    .best_price       (best_price),
    .best_quantity    (best_quantity),
    .best_valid       (best_valid),
    .full             (full),
    .level_count      (level_count),
    .free_pointer     (free_pointer),
    .level_price_0     (level_price[0]),
    .level_price_1     (level_price[1]),
    .level_quantity_0  (level_quantity[0]),
    .level_price_array (level_price)
);
