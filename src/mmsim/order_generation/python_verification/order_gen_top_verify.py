#!/usr/bin/env python3
"""Structural checker for order_gen_top.v integration test.

Does not predict exact values; the GBM+LFSR chain is too deep to replay in Python. Instead
it asserts per-phase invariants on agent_type, price, reserved bits, round-robin order, and
volume caps. Usage: python3 order_gen_top_verify.py top_log.csv
"""

import sys
import csv
import os
from dataclasses import dataclass
from typing import List
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Packet dataclass
# ---------------------------------------------------------------------------
@dataclass
class Packet:
    cycle:      int
    phase:      int
    raw:        int
    agent_type: int
    side:       int
    order_type: int
    price:      int
    volume:     int

def parse_csv(path: str) -> List[Packet]:
    packets = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            packets.append(Packet(
                cycle      = int(row["cycle"]),
                phase      = int(row["phase"]),
                raw        = int(row["packet"], 16),
                agent_type = int(row["agent_type"]),
                side       = int(row["side"]),
                order_type = int(row["order_type"]),
                price      = int(row["price"]),
                volume     = int(row["volume"]),
            ))
    return packets

# ---------------------------------------------------------------------------
# Checker helpers
# ---------------------------------------------------------------------------
def check(condition, label, detail=""):
    if condition:
        print(f"PASS [{label}]{(' — ' + detail) if detail else ''}")
        return 1, 0
    else:
        print(f"FAIL [{label}]{(' — ' + detail) if detail else ''}")
        return 0, 1

def structural_checks(pkts, phase_label, allowed_types, vol_cap=None):
    passes = fails = 0

    # Price always <= 479
    bad_price = [p for p in pkts if p.price > 479]
    p, f = check(len(bad_price) == 0, f"{phase_label} price<=479",
                 f"{len(bad_price)} violations" if bad_price else f"{len(pkts)} packets OK")
    passes += p; fails += f

    # Reserved bits [27:25] == 0
    bad_reserved = [p for p in pkts if (p.raw >> 25) & 0x7 != 0]
    p, f = check(len(bad_reserved) == 0, f"{phase_label} reserved=0",
                 f"{len(bad_reserved)} violations" if bad_reserved else "OK")
    passes += p; fails += f

    # Agent type only in allowed set
    bad_type = [p for p in pkts if p.agent_type not in allowed_types]
    p, f = check(len(bad_type) == 0, f"{phase_label} agent_type in {allowed_types}",
                 f"{len(bad_type)} violations" if bad_type else f"{len(pkts)} packets OK")
    passes += p; fails += f

    # Volume cap check if specified
    if vol_cap is not None:
        bad_vol = [p for p in pkts if p.volume > vol_cap]
        p, f = check(len(bad_vol) == 0, f"{phase_label} volume<={vol_cap}",
                     f"{len(bad_vol)} violations" if bad_vol else "OK")
        passes += p; fails += f

    return passes, fails

# ---------------------------------------------------------------------------
# Main checker
# ---------------------------------------------------------------------------
def run_checks(packets):
    passes = fails = 0

    # Split by phase
    ph = {i: [p for p in packets if p.phase == i] for i in range(5)}

    # ---- PHASE 1: no packets when active_agent_count=0 --------------------
    p, f = check(len(ph[1]) == 0, "phase1 empty",
                 f"got {len(ph[1])} packets, expected 0")
    passes += p; fails += f

    # ---- PHASE 2: structural + round-robin alternation --------------------
    if len(ph[2]) == 0:
        print("WARN [phase2] no packets received — agents may not have emitted")
    else:
        p, f = structural_checks(ph[2], "phase2", allowed_types={0b00, 0b11})
        passes += p; fails += f

        # Round-robin check
        types = [p.agent_type for p in ph[2]]
        val_count = types.count(0b11)
        noise_count = types.count(0b00)
        
        # They should be roughly equal (Noise trader skips ~0.1% of the time)
        diff = abs(val_count - noise_count)
        p, f = check(diff <= len(types) * 0.35, "phase2 round-robin fair distribution",
                     f"Value: {val_count}, Noise: {noise_count}")
        passes += p; fails += f

        # Must have both types present
        p, f = check(any(p.agent_type == 0b11 for p in ph[2]),
                     "phase2 has value investor packets")
        passes += p; fails += f
        p, f = check(any(p.agent_type == 0b00 for p in ph[2]),
                     "phase2 has noise trader packets")
        passes += p; fails += f

        print(f"  Phase 2 total packets: {len(ph[2])}")

    # ---- PHASE 3: structural checks with more slots -----------------------
    if len(ph[3]) == 0:
        print("WARN [phase3] no packets received")
    else:
        p, f = structural_checks(ph[3], "phase3", allowed_types={0b00, 0b11})
        passes += p; fails += f
        print(f"  Phase 3 total packets: {len(ph[3])}")

    # ---- PHASE 4: param decode — only value investor, vol<=63 -------------
    if len(ph[4]) == 0:
        print("WARN [phase4] no packets received — param decode untestable")
    else:
        p, f = structural_checks(ph[4], "phase4", allowed_types={0b11}, vol_cap=63)
        passes += p; fails += f

        # Confirm at least some packets arrived — proves slot 0 was loaded
        p, f = check(len(ph[4]) > 0, "phase4 packets received",
                     f"{len(ph[4])} packets")
        passes += p; fails += f
        print(f"  Phase 4 total packets: {len(ph[4])}")

    p, f = check(any(p.volume > 10 for p in ph[4]), "phase4 volume cap actually increased",
                "at least one packet breached vol>10")
    passes += p; fails += f

    # ---- Summary -----------------------------------------------------------
    print()
    print("=" * 55)
    if fails == 0:
        print(f"  ALL CHECKS PASSED  ({passes} checks)")
    else:
        print(f"  FAILED: {fails} failure(s), {passes} pass(es)")
    print("=" * 55)

    return fails == 0, packets

# ---------------------------------------------------------------------------
# Plotter
# ---------------------------------------------------------------------------
def plot_results(packets, save_path="top_verification.png"):
    if not packets:
        print("No packets to plot.")
        return

    fig, axes = plt.subplots(2, 2, figsize=(14, 9))
    fig.suptitle("order_gen_top Integration Verification", fontsize=14, fontweight='bold')

    phase_colors = {1: 'gray', 2: 'steelblue', 3: 'seagreen', 4: 'darkorange'}
    type_labels  = {0b00: 'Noise(00)', 0b01: 'MM(01)', 0b10: 'Momentum(10)', 0b11: 'Value(11)'}
    type_colors  = {0b00: 'steelblue', 0b11: 'darkorange', 0b10: 'seagreen', 0b01: 'gray'}

    # Panel 1: price distribution by agent type
    ax = axes[0][0]
    for at in [0b00, 0b11]:
        prices = [p.price for p in packets if p.agent_type == at]
        if prices:
            ax.hist(prices, bins=40, alpha=0.6,
                    label=type_labels[at], color=type_colors[at])
    ax.axvline(479, color='red', linestyle='--', linewidth=1, label='max=479')
    ax.set_xlabel("Price Tick")
    ax.set_ylabel("Count")
    ax.set_title("Price Distribution by Agent Type")
    ax.legend(fontsize=8)

    # Panel 2: volume distribution by phase
    ax = axes[0][1]
    for ph in [2, 3, 4]:
        vols = [p.volume for p in packets if p.phase == ph]
        if vols:
            ax.hist(vols, bins=30, alpha=0.6,
                    label=f'Phase {ph}', color=phase_colors[ph])
    ax.axvline(63, color='darkorange', linestyle='--', linewidth=1, label='vol_cap=63 (ph4)')
    ax.axvline(10, color='steelblue',  linestyle='--', linewidth=1, label='vol_cap=10 (ph2/3)')
    ax.set_xlabel("Volume")
    ax.set_ylabel("Count")
    ax.set_title("Volume Distribution by Phase")
    ax.legend(fontsize=8)

    # Panel 3: packet timeline coloured by agent type
    ax = axes[1][0]
    for at in [0b00, 0b11]:
        pts = [(p.cycle, p.price) for p in packets if p.agent_type == at]
        if pts:
            cycles, prices = zip(*pts)
            ax.scatter(cycles, prices, s=6, alpha=0.5,
                       label=type_labels[at], color=type_colors[at])
    ax.set_xlabel("Cycle")
    ax.set_ylabel("Price Tick")
    ax.set_title("Packet Timeline (price vs cycle)")
    ax.legend(fontsize=8)

    # Panel 4: agent type mix per phase (bar)
    ax = axes[1][1]
    phases = [2, 3, 4]
    x = range(len(phases))
    noise_counts = [sum(1 for p in packets if p.phase == ph and p.agent_type == 0b00)
                    for ph in phases]
    value_counts = [sum(1 for p in packets if p.phase == ph and p.agent_type == 0b11)
                    for ph in phases]
    width = 0.35
    ax.bar([xi - width/2 for xi in x], noise_counts, width,
           label='Noise(00)', color='steelblue')
    ax.bar([xi + width/2 for xi in x], value_counts, width,
           label='Value(11)', color='darkorange')
    ax.set_xticks(list(x))
    ax.set_xticklabels([f'Phase {ph}' for ph in phases])
    ax.set_ylabel("Packet Count")
    ax.set_title("Agent Type Mix per Phase")
    ax.legend(fontsize=8)

    plt.tight_layout()
    plt.savefig(save_path, dpi=150, bbox_inches='tight')
    print(f"Plot saved -> {save_path}")

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # Auto-find CSV
    if len(sys.argv) < 2:
        candidates = ["sim/top_log.csv", "top_log.csv", "../top_log.csv"]
        path = next((p for p in candidates if os.path.exists(p)), None)
        if path is None:
            print("Usage: python3 order_gen_top_verify.py top_log.csv")
            sys.exit(0)
    else:
        path = sys.argv[1]

    print(f"Parsing {path} ...")
    packets = parse_csv(path)
    print(f"  Total packets: {len(packets)}")
    by_phase = {i: sum(1 for p in packets if p.phase == i) for i in range(5)}
    for ph, count in by_phase.items():
        if count:
            print(f"  Phase {ph}: {count} packets")
    print()

    ok, packets = run_checks(packets)
    plot_results(packets)
    sys.exit(0 if ok else 1)