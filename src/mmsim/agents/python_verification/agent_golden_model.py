# agent_golden_model.py
#
# Golden model and analysis for agent_execution_unit testbench

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import sys
import os

# =====================================================================
# Test Target Toggle ('NOISE', 'VALUE', or 'MOMENTUM')
# =====================================================================
TARGET_TEST = 'MOMENTUM'

# =====================================================================
# Configuration -- must match RTL parameters exactly
# =====================================================================
LFSR_POLY         = 0xB4BCD35C
LFSR_SEED         = 0xCAFEBABE
NEAR_NOISE_THRESH = 16           # ticks, below = market order
CLK_MASK          = 0xFFFFFFFF   # 32-bit mask

# Phase definitions: (phase_id, param_data, gbm_price_q824, num_cycles)
PHASES = [
    # --- NOISE TRADER PHASES ---
    {
        'id': 1,
        'name': 'Always Emit (param1=1023)',
        'param_data': (0b00 << 30) | (0x3FF << 20) | (50 << 10) | 100,
        'gbm_price':  0x64000000,   
        'last_exec_price': 0x64000000,
        'oldest_exec_price': 0x64000000,
        'cycles':     400,
    },
    {
        'id': 2,
        'name': 'Never Emit (param1=0)',
        'param_data': (0b00 << 30) | (0x000 << 20) | (50 << 10) | 100,
        'gbm_price':  0x64000000,
        'last_exec_price': 0x64000000,
        'oldest_exec_price': 0x64000000,
        'cycles':     200,
    },
    {
        'id': 3,
        'name': '50pct Emit (param1=512)',
        'param_data': (0b00 << 30) | (512 << 20) | (50 << 10) | 100,
        'gbm_price':  0x64000000,
        'last_exec_price': 0x64000000,
        'oldest_exec_price': 0x64000000,
        # 4000 cycles + 4 setup cycles from TB transition = 4004
        'cycles':     4004, 
    },
    # --- VALUE INVESTOR PHASES ---
    {
        'id': 4,
        'name': 'Value: Undervalued (Buy)',
        'param_data': (0b11 << 30) | (10 << 20) | (256 << 10) | 100,
        'gbm_price':  0x78000000,   
        'last_exec_price': 0x64000000, 
        'oldest_exec_price': 0x64000000,
        'cycles':     200,
    },
    {
        'id': 5,
        'name': 'Value: Overvalued (Sell)',
        'param_data': (0b11 << 30) | (10 << 20) | (256 << 10) | 100,
        'gbm_price':  0x50000000,   
        'last_exec_price': 0x64000000, 
        'oldest_exec_price': 0x64000000,
        'cycles':     200,
    },
    {
        'id': 6,
        'name': 'Value: Within Threshold (Silent)',
        'param_data': (0b11 << 30) | (10 << 20) | (256 << 10) | 100,
        'gbm_price':  0x66000000,   
        'last_exec_price': 0x64000000, 
        'oldest_exec_price': 0x64000000,
        'cycles':     200,
    },
    # --- MOMENTUM TRADER PHASES ---
    {
        'id': 7,
        'name': 'Momentum: Uptrend (Buy)',
        'param_data': (0b10 << 30) | (10 << 20) | (256 << 10) | 100,
        'gbm_price':  0x64000000, # Ignored by Momentum, but keeping struct intact
        'last_exec_price':   0x78000000, # Newest (Tick 240)
        'oldest_exec_price': 0x64000000, # Oldest (Tick 200)
        'cycles':     200,
    },
    {
        'id': 8,
        'name': 'Momentum: Downtrend (Sell)',
        'param_data': (0b10 << 30) | (10 << 20) | (256 << 10) | 100,
        'gbm_price':  0x64000000,
        'last_exec_price':   0x50000000, # Newest (Tick 160)
        'oldest_exec_price': 0x64000000, # Oldest (Tick 200)
        'cycles':     200,
    },
    {
        'id': 9,
        'name': 'Momentum: Sideways (Silent)',
        'param_data': (0b10 << 30) | (10 << 20) | (256 << 10) | 100,
        'gbm_price':  0x64000000,
        'last_exec_price':   0x66000000, # Newest (Tick 204)
        'oldest_exec_price': 0x64000000, # Oldest (Tick 200)
        'cycles':     200,
    }
]

# =====================================================================
# Galois LFSR & Helpers
# =====================================================================
def lfsr_next(state, poly=LFSR_POLY):
    lsb = state & 1
    state = (state >> 1) & CLK_MASK
    if lsb:
        state ^= poly
    return state

def gbm_price_to_tick(gbm_price_q824):
    tick = (gbm_price_q824 >> 23) & 0x1FF
    return min(tick, 479)

def decode_param_data(param_data):
    agent_type = (param_data >> 30) & 0x3
    param1     = (param_data >> 20) & 0x3FF
    param2     = (param_data >> 10) & 0x3FF
    param3     = (param_data >>  0) & 0x3FF
    return agent_type, param1, param2, param3

# =====================================================================
# Golden model
# =====================================================================
def run_golden_model(phase, lfsr_init):
    param_data = phase['param_data']
    gbm_price  = phase['gbm_price']
    last_exec_price = phase['last_exec_price']
    oldest_exec_price = phase.get('oldest_exec_price', 0x64000000)
    num_cycles = phase['cycles']
    
    agent_type, param1, param2, param3 = decode_param_data(param_data)
    gbm_tick = gbm_price_to_tick(gbm_price)
    last_exec_tick = gbm_price_to_tick(last_exec_price)
    oldest_exec_tick = gbm_price_to_tick(oldest_exec_price)
    
    predictions = []
    lfsr = lfsr_init
    
    num_evaluations = num_cycles // 4
    
    for slot_eval in range(num_evaluations):
        lfsr = lfsr_next(lfsr) 
        lfsr = lfsr_next(lfsr) 
        lfsr_sample = lfsr     
        lfsr = lfsr_next(lfsr) 
        lfsr = lfsr_next(lfsr) 
        
        # --- NOISE TRADER (00) ---
        if agent_type == 0b00:
            emission_rand = lfsr_sample & 0x3FF
            side_bit      = (lfsr_sample >> 10) & 0x1
            offset_rand   = (lfsr_sample >> 11) & 0x3FF
            volume_rand   = (lfsr_sample >> 21) & 0x3FF
            
            emits = emission_rand < param1
            
            if emits:
                offset_raw   = (offset_rand * param2) >> 10
                offset_ticks = min(offset_raw, 479) & 0x1FF
                
                volume_raw = (volume_rand * param3) >> 10
                volume = (volume_raw & 0xFFFF) + 1
                
                if side_bit == 0: 
                    final_price = max(gbm_tick - offset_ticks, 0)
                else:             
                    final_price = min(gbm_tick + offset_ticks, 479)
                
                order_type = 1 if offset_ticks < NEAR_NOISE_THRESH else 0
                
                predictions.append({
                    'slot_eval':   slot_eval,
                    'cycle':       slot_eval * 4 + 3,
                    'side':        side_bit,
                    'order_type':  order_type,
                    'agent_type':  agent_type,
                    'price':       final_price,
                    'volume':      volume
                })

        # --- MOMENTUM TRADER (10) ---
        elif agent_type == 0b10:
            momentum_delta = last_exec_tick - oldest_exec_tick
            abs_mom = abs(momentum_delta)
            
            emits = abs_mom > param1
            
            if emits:
                side_bit = 0 if momentum_delta > 0 else 1 
                
                dsp_product = abs_mom * param2
                volume_raw = (dsp_product >> 10) + 1
                volume = min(volume_raw, param3)
                
                final_price = last_exec_tick # Market orders fire at the current front of the book
                order_type = 1 # Always market
                
                predictions.append({
                    'slot_eval':   slot_eval,
                    'cycle':       slot_eval * 4 + 3,
                    'side':        side_bit,
                    'order_type':  order_type,
                    'agent_type':  agent_type,
                    'price':       final_price,
                    'volume':      volume
                })

        # --- VALUE INVESTOR (11) ---
        elif agent_type == 0b11:
            divergence = gbm_tick - last_exec_tick
            abs_div = abs(divergence)
            
            emits = abs_div > param1
            
            if emits:
                side_bit = 0 if divergence > 0 else 1 
                
                dsp_product = abs_div * param2
                volume_raw = (dsp_product >> 10) + 1
                volume = min(volume_raw, param3)
                
                final_price = gbm_tick
                order_type = 0 # Always limit
                
                predictions.append({
                    'slot_eval':   slot_eval,
                    'cycle':       slot_eval * 4 + 3,
                    'side':        side_bit,
                    'order_type':  order_type,
                    'agent_type':  agent_type,
                    'price':       final_price,
                    'volume':      volume
                })
                
    return predictions, lfsr

# =====================================================================
# Compare Phase
# =====================================================================
def compare_phase(phase_id, predictions, actual_df):
    actual = actual_df[actual_df['phase'] == phase_id].reset_index(drop=True)
    
    print(f"\n--- Phase {phase_id} comparison ---")
    print(f"  Predicted emissions : {len(predictions)}")
    print(f"  Actual emissions    : {len(actual)}")
    
    if len(predictions) == 0 and len(actual) == 0:
        print("  PASS: Both predict zero emissions")
        return 0, 0, 0
    
    if len(predictions) != len(actual):
        print(f"  WARN: Emission count mismatch -- predicted {len(predictions)}, got {len(actual)}")
    
    matches = 0
    mismatches = 0
    check_count = min(len(predictions), len(actual))
    
    for i in range(check_count):
        p = predictions[i]
        a = actual.iloc[i]
        
        fields_match = (
            p['side']       == int(a['side'])       and
            p['order_type'] == int(a['order_type']) and
            p['agent_type'] == int(a['agent_type']) and
            p['price']      == int(a['price'])      and
            p['volume']     == int(a['volume'])
        )
        
        if fields_match:
            matches += 1
        else:
            mismatches += 1
            if mismatches <= 5:
                print(f"  MISMATCH at emission {i}:")
                print(f"    Predicted: side={p['side']} type={p['order_type']} price={p['price']} vol={p['volume']}")
                print(f"    Actual:    side={int(a['side'])} type={int(a['order_type'])} price={int(a['price'])} vol={int(a['volume'])}")
    
    missing = abs(len(predictions) - len(actual))
    print(f"  Matches: {matches}, Mismatches: {mismatches}, Missing: {missing}")
    if mismatches == 0 and missing == 0:
        print(f"  PASS: All {matches} emissions match exactly")
    
    return matches, mismatches, missing

# =====================================================================
# Noise Trader Plotting
# =====================================================================
def plot_results(actual_df, predictions_by_phase):
    fig = plt.figure(figsize=(18, 10))
    fig.suptitle('Agent Execution Unit -- Noise Trader Verification', fontsize=14, fontweight='bold')
    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.4, wspace=0.35)
    
    # Phase 1 data
    p1_actual = actual_df[actual_df['phase'] == 1]
    p1_pred   = pd.DataFrame(predictions_by_phase.get(1, []))
    
    gbm_tick_p1 = gbm_price_to_tick(PHASES[0]['gbm_price'])
    _, _, param2_p1, param3_p1 = decode_param_data(PHASES[0]['param_data'])
    
    # Plot 1: Price dist
    ax1 = fig.add_subplot(gs[0, 0])
    if len(p1_actual) > 0:
        ax1.hist(p1_actual['price'].astype(int), bins=30, alpha=0.6, color='steelblue', label='RTL output', density=True)
    if len(p1_pred) > 0:
        ax1.hist(p1_pred['price'].astype(int), bins=30, alpha=0.6, color='orange', label='Golden model', density=True)
    ax1.axvline(gbm_tick_p1, color='red', linestyle='--', linewidth=1.5, label=f'GBM tick={gbm_tick_p1}')
    ax1.set_title('Phase 1: Price Distribution')
    ax1.set_xlabel('Tick index (0-479)')
    ax1.set_ylabel('Density')
    ax1.legend(fontsize=8)
    ax1.set_xlim(0, 479)
    
    # Plot 2: Volume dist
    ax2 = fig.add_subplot(gs[0, 1])
    if len(p1_actual) > 0:
        ax2.hist(p1_actual['volume'].astype(int), bins=20, alpha=0.6, color='steelblue', label='RTL output', density=True)
    if len(p1_pred) > 0:
        ax2.hist(p1_pred['volume'].astype(int), bins=20, alpha=0.6, color='orange', label='Golden model', density=True)
    ax2.set_title(f'Phase 1: Volume Distribution (max={param3_p1})')
    ax2.set_xlabel('Volume (shares)')
    ax2.set_ylabel('Density')
    ax2.legend(fontsize=8)
    
    # Plot 3: Side & Order Type
    ax3 = fig.add_subplot(gs[0, 2])
    if len(p1_actual) > 0:
        buy_count    = (p1_actual['side'] == 0).sum()
        sell_count   = (p1_actual['side'] == 1).sum()
        market_count = (p1_actual['order_type'] == 1).sum()
        limit_count  = (p1_actual['order_type'] == 0).sum()
        
        categories = ['Buy', 'Sell', 'Market\nOrder', 'Limit\nOrder']
        counts     = [buy_count, sell_count, market_count, limit_count]
        colors     = ['green', 'red', 'purple', 'teal']
        bars = ax3.bar(categories, counts, color=colors, alpha=0.7)
        ax3.set_title('Phase 1: Side & Order Type')
        ax3.set_ylabel('Count')
        for bar, count in zip(bars, counts):
            ax3.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5, str(count), ha='center', va='bottom', fontsize=9)
    
    # Phase 3 data
    p3_actual = actual_df[actual_df['phase'] == 3]
    p3_pred   = pd.DataFrame(predictions_by_phase.get(3, []))
    
    # Plot 4: Emission rate convergence
    ax4 = fig.add_subplot(gs[1, 0])
    if len(p3_actual) > 0:
        total_evals_p3 = PHASES[2]['cycles'] // 4
        emission_cycles = p3_actual['cycle'].astype(int).values
        eval_numbers = emission_cycles // 4
        running_rate = np.arange(1, len(eval_numbers)+1) / (eval_numbers + 1)
        
        ax4.plot(eval_numbers, running_rate, color='steelblue', linewidth=1, label='RTL running rate')
        ax4.axhline(0.5, color='red', linestyle='--', linewidth=1.5, label='Target 50%')
        ax4.axhline(512/1024, color='orange', linestyle=':', linewidth=1.5, label=f'Exact threshold {512/1024:.3f}')
        ax4.set_title('Phase 3: Emission Rate Convergence')
        ax4.set_xlabel('Slot evaluation number')
        ax4.set_ylabel('Running emission rate')
        ax4.set_ylim(0, 1)
        ax4.legend(fontsize=8)
    
    # Plot 5: Price dist phase 3
    ax5 = fig.add_subplot(gs[1, 1])
    gbm_tick_p3 = gbm_price_to_tick(PHASES[2]['gbm_price'])
    if len(p3_actual) > 0:
        ax5.hist(p3_actual['price'].astype(int), bins=40, alpha=0.6, color='steelblue', label='RTL output', density=True)
    if len(p3_pred) > 0:
        ax5.hist(p3_pred['price'].astype(int), bins=40, alpha=0.6, color='orange', label='Golden model', density=True)
    ax5.axvline(gbm_tick_p3, color='red', linestyle='--', linewidth=1.5, label=f'GBM tick={gbm_tick_p3}')
    ax5.set_title('Phase 3: Price Distribution')
    ax5.set_xlabel('Tick index (0-479)')
    ax5.set_ylabel('Density')
    ax5.legend(fontsize=8)
    ax5.set_xlim(0, 479)
    
    # Plot 6: Market vs Limit breakdown
    ax6 = fig.add_subplot(gs[1, 2])
    phase_labels = []
    market_pcts  = []
    limit_pcts   = []
    
    for ph_id, ph_name in [(1, 'Phase 1\n(always emit)'), (3, 'Phase 3\n(50% emit)')]:
        ph_data = actual_df[actual_df['phase'] == ph_id]
        if len(ph_data) > 0:
            m_pct = (ph_data['order_type'] == 1).mean() * 100
            l_pct = (ph_data['order_type'] == 0).mean() * 100
            phase_labels.append(ph_name)
            market_pcts.append(m_pct)
            limit_pcts.append(l_pct)
    
    if phase_labels:
        x = np.arange(len(phase_labels))
        width = 0.35
        ax6.bar(x - width/2, market_pcts, width, label='Market orders', color='purple', alpha=0.7)
        ax6.bar(x + width/2, limit_pcts,  width, label='Limit orders',  color='teal',  alpha=0.7)
        ax6.set_title(f'Market vs Limit Split\n(threshold={NEAR_NOISE_THRESH} ticks)')
        ax6.set_ylabel('Percentage (%)')
        ax6.set_xticks(x)
        ax6.set_xticklabels(phase_labels)
        ax6.legend(fontsize=8)
        ax6.set_ylim(0, 100)
    
    plt.savefig('noise_agent_verification.png', dpi=150, bbox_inches='tight')
    print("\nPlot saved to noise_agent_verification.png")
    plt.show()

# =====================================================================
# Value Investor Plotting
# =====================================================================
def plot_value_results(actual_df, predictions_by_phase):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle('Agent Execution Unit -- Value Investor Deterministic Verification', fontsize=14, fontweight='bold')
    
    phases_to_plot = [4, 5, 6]
    phase_labels = ['Phase 4 (Buy)', 'Phase 5 (Sell)', 'Phase 6 (Silent)']
    
    prices = []
    volumes = []
    sides = []
    
    for ph_id in phases_to_plot:
        ph_data = actual_df[actual_df['phase'] == ph_id]
        if len(ph_data) > 0:
            prices.append(ph_data['price'].iloc[0])   
            volumes.append(ph_data['volume'].iloc[0])
            sides.append('Buy' if ph_data['side'].iloc[0] == 0 else 'Sell')
        else:
            prices.append(0)
            volumes.append(0)
            sides.append('Silent')

    x = np.arange(len(phase_labels))
    ax1.bar(x, volumes, color=['green' if s == 'Buy' else 'red' if s == 'Sell' else 'gray' for s in sides], alpha=0.7)
    
    for i, (vol, price, side) in enumerate(zip(volumes, prices, sides)):
        if vol > 0:
            ax1.text(i, vol + 0.5, f"Limit {side}\n@ Tick {int(price)}", ha='center', va='bottom', fontsize=10, fontweight='bold')
        else:
            ax1.text(i, 0.5, "No Action", ha='center', va='bottom', fontsize=10, fontweight='bold')

    ax1.set_xticks(x)
    ax1.set_xticklabels(phase_labels)
    ax1.set_ylabel('Generated Volume')
    ax1.set_title('Calculated Volume and Order Intent')
    ax1.set_ylim(0, max(max(volumes) + 3, 10))

    gbm_ticks = [gbm_price_to_tick(PHASES[3]['gbm_price']), gbm_price_to_tick(PHASES[4]['gbm_price']), gbm_price_to_tick(PHASES[5]['gbm_price'])]
    exec_tick = gbm_price_to_tick(PHASES[3]['last_exec_price']) 
    
    ax2.plot(x, gbm_ticks, marker='o', linestyle='-', color='blue', label='GBM Fair Value Tick', markersize=8)
    ax2.axhline(exec_tick, color='purple', linestyle='--', label=f'Last Exec Tick ({exec_tick})')
    
    ax2.fill_between(x, gbm_ticks, exec_tick, where=(np.array(gbm_ticks) > exec_tick), interpolate=True, color='green', alpha=0.2, label='Undervalued (Buy Zone)')
    ax2.fill_between(x, gbm_ticks, exec_tick, where=(np.array(gbm_ticks) < exec_tick), interpolate=True, color='red', alpha=0.2, label='Overvalued (Sell Zone)')

    ax2.set_xticks(x)
    ax2.set_xticklabels(phase_labels)
    ax2.set_ylabel('Tick Price')
    ax2.set_title('Market Divergence State')
    ax2.legend()
    
    plt.tight_layout()
    plt.savefig('value_agent_verification.png', dpi=150, bbox_inches='tight')
    print("\nPlot saved to value_agent_verification.png")
    plt.show()

# =====================================================================
# Momentum Trader Plotting
# =====================================================================
def plot_momentum_results(actual_df, predictions_by_phase):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
    fig.suptitle('Agent Execution Unit -- Momentum Trader Verification', fontsize=14, fontweight='bold')
    
    phases_to_plot = [7, 8, 9]
    phase_labels = ['Phase 7 (Buy)', 'Phase 8 (Sell)', 'Phase 9 (Silent)']
    
    prices = []
    volumes = []
    sides = []
    
    for ph_id in phases_to_plot:
        ph_data = actual_df[actual_df['phase'] == ph_id]
        if len(ph_data) > 0:
            prices.append(ph_data['price'].iloc[0])   
            volumes.append(ph_data['volume'].iloc[0])
            sides.append('Buy' if ph_data['side'].iloc[0] == 0 else 'Sell')
        else:
            prices.append(0)
            volumes.append(0)
            sides.append('Silent')

    x = np.arange(len(phase_labels))
    ax1.bar(x, volumes, color=['green' if s == 'Buy' else 'red' if s == 'Sell' else 'gray' for s in sides], alpha=0.7)
    
    for i, (vol, price, side) in enumerate(zip(volumes, prices, sides)):
        if vol > 0:
            ax1.text(i, vol + 0.5, f"Market {side}\n@ Tick {int(price)}", ha='center', va='bottom', fontsize=10, fontweight='bold')
        else:
            ax1.text(i, 0.5, "No Action", ha='center', va='bottom', fontsize=10, fontweight='bold')

    ax1.set_xticks(x)
    ax1.set_xticklabels(phase_labels)
    ax1.set_ylabel('Generated Volume')
    ax1.set_title('Calculated Volume and Order Intent')
    ax1.set_ylim(0, max(max(volumes) + 3, 10))

    # Retrieve ticks directly from the test configs
    newest_ticks = [gbm_price_to_tick(PHASES[6]['last_exec_price']), gbm_price_to_tick(PHASES[7]['last_exec_price']), gbm_price_to_tick(PHASES[8]['last_exec_price'])]
    oldest_ticks = [gbm_price_to_tick(PHASES[6]['oldest_exec_price']), gbm_price_to_tick(PHASES[7]['oldest_exec_price']), gbm_price_to_tick(PHASES[8]['oldest_exec_price'])]
    
    ax2.plot(x, newest_ticks, marker='o', linestyle='-', color='blue', label='Newest Trade (reg_0)', markersize=8)
    ax2.plot(x, oldest_ticks, marker='s', linestyle='--', color='purple', label='Oldest Trade (reg_3)', markersize=8)
    
    # Highlight the trend
    ax2.fill_between(x, newest_ticks, oldest_ticks, where=(np.array(newest_ticks) > oldest_ticks), interpolate=True, color='green', alpha=0.2, label='Uptrend')
    ax2.fill_between(x, newest_ticks, oldest_ticks, where=(np.array(newest_ticks) < oldest_ticks), interpolate=True, color='red', alpha=0.2, label='Downtrend')

    ax2.set_xticks(x)
    ax2.set_xticklabels(phase_labels)
    ax2.set_ylabel('Tick Price')
    ax2.set_title('Shift Register Trend State')
    ax2.legend()
    
    plt.tight_layout()
    plt.savefig('momentum_agent_verification.png', dpi=150, bbox_inches='tight')
    print("\nPlot saved to momentum_agent_verification.png")
    plt.show()


# =====================================================================
# Main
# =====================================================================
def main():
    csv_path = 'sim_output.csv'
    
    if not os.path.exists(csv_path):
        print(f"ERROR: {csv_path} not found.")
        sys.exit(1)
        
    actual_df = pd.read_csv(csv_path)
    actual_df.columns = actual_df.columns.str.strip()
    
    lfsr_state = LFSR_SEED
    predictions_by_phase = {}
    all_results = []
    
    target_phases = []
    if TARGET_TEST == 'NOISE':
        target_phases = [p for p in PHASES if p['id'] in [1, 2, 3]]
    elif TARGET_TEST == 'VALUE':
        target_phases = [p for p in PHASES if p['id'] in [4, 5, 6]]
    elif TARGET_TEST == 'MOMENTUM':
        target_phases = [p for p in PHASES if p['id'] in [7, 8, 9]]
    else:
        target_phases = PHASES

    for phase in PHASES:
        preds, lfsr_state = run_golden_model(phase, lfsr_state)
        
        if phase in target_phases:
            print(f"\nEvaluating Phase {phase['id']}: {phase['name']}")
            predictions_by_phase[phase['id']] = preds
            matches, mismatches, missing = compare_phase(phase['id'], preds, actual_df)
            
            all_results.append({
                'phase':      phase['id'],
                'name':       phase['name'],
                'predicted':  len(preds),
                'actual':     len(actual_df[actual_df['phase'] == phase['id']]),
                'matches':    matches,
                'mismatches': mismatches,
                'missing':    missing,
            })
            
    print("\n" + "="*60)
    print("SUMMARY")
    print("="*60)
    print(f"{'Phase':<8} {'Name':<30} {'Pred':>6} {'Actual':>6} {'Match':>6} {'Fail':>6}")
    print("-"*60)
    for r in all_results:
        status = 'PASS' if r['mismatches'] == 0 and r['missing'] == 0 else 'FAIL'
        print(f"{r['phase']:<8} {r['name']:<30} {r['predicted']:>6} "
              f"{r['actual']:>6} {r['matches']:>6} {r['mismatches']:>6}  {status}")

    # --- Routing to the correct plotting function ---
    if TARGET_TEST == 'VALUE':
        plot_value_results(actual_df, predictions_by_phase)
    elif TARGET_TEST == 'NOISE':
        plot_results(actual_df, predictions_by_phase)
    elif TARGET_TEST == 'MOMENTUM':
        plot_momentum_results(actual_df, predictions_by_phase)

if __name__ == '__main__':
    main()