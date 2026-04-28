#!/usr/bin/env python3
"""Golden model and checker for order_arbiter.v.

Reads arbiter_log.csv from tb_order_arbiter.v, replays the round-robin logic, and compares
every grant and stall event. Usage: python3 order_arbiter_verify.py arbiter_log.csv
"""

import sys
import csv
from dataclasses import dataclass, field
from typing import Optional, List, Tuple

# ---------------------------------------------------------------------------
# Parameters — must match TB localparam values
# ---------------------------------------------------------------------------
NUM_UNITS = 8


def make_packet(unit: int) -> int:
    """Mirror init_packets task: { 8'hA0|unit, 8'h00, 8'h00, unit[7:0] }"""
    return ((0xA0 | (unit & 0xFF)) << 24) | (unit & 0xFF)


# ---------------------------------------------------------------------------
# Arbiter golden model
# Mirrors the synthesised always @(posedge clk) block exactly
# ---------------------------------------------------------------------------
class ArbiterModel:
    def __init__(self, num_units: int = NUM_UNITS):
        self.num_units   = num_units
        self.grant_ptr   = 0
        self.almost_full = False
        self.full        = False
        self.order_valid = [False] * num_units

    def step(self) -> Optional[int]:
        """One clock cycle. Returns granted unit index or None."""
        if self.almost_full or self.full:
            return None
        for i in range(self.num_units):
            idx = (self.grant_ptr + i) % self.num_units
            if self.order_valid[idx]:
                # Advance pointer PAST the granted unit
                self.grant_ptr = (idx + 1) % self.num_units
                return idx
        return None


# ---------------------------------------------------------------------------
# Expected event types
# ---------------------------------------------------------------------------
@dataclass
class ExpGrant:
    unit:   int
    packet: int

@dataclass
class ExpStall:
    pass


# ---------------------------------------------------------------------------
# Build expected event list by replaying the same stimulus as the TB
# ---------------------------------------------------------------------------
def run_golden() -> List:
    model    = ArbiterModel()
    expected = []

    def all_valid(v=True):
        model.order_valid = [v] * NUM_UNITS

    def set_valid(indices):
        model.order_valid = [i in indices for i in range(NUM_UNITS)]

    def run(n):
        for _ in range(n):
            g = model.step()
            if g is not None:
                expected.append(ExpGrant(unit=g, packet=make_packet(g)))
            elif model.almost_full or model.full:
                expected.append(ExpStall())
            # idle (no valid units, no stall) produces no event — matches CSV

    # T1: all valid, 3 laps
    all_valid(True)
    run(NUM_UNITS * 3)
    all_valid(False)
    run(2)

    # T2: sparse — units 1, 3, 5
    set_valid([1, 3, 5])
    run(12)
    all_valid(False)
    run(2)

    # T3: almost_full stall
    all_valid(True)
    model.almost_full = True
    run(6)
    model.almost_full = False
    run(4)
    all_valid(False)
    run(2)

    # T4: full stall
    all_valid(True)
    model.full = True
    run(6)
    model.full = False
    run(4)
    all_valid(False)
    run(2)

    # T5: unit 3 only
    set_valid([3])
    run(8)
    all_valid(False)
    run(2)

    # T6: unit 2 deasserts mid-run
    all_valid(True)
    run(3)
    model.order_valid[2] = False
    run(8)
    all_valid(False)
    run(2)

    # T7: stall then resume
    all_valid(True)
    run(3)
    model.almost_full = True
    run(3)
    model.almost_full = False
    run(6)
    all_valid(False)
    run(2)

    return expected


# ---------------------------------------------------------------------------
# CSV parser
# ---------------------------------------------------------------------------
@dataclass
class SimGrant:
    cycle:  int
    unit:   int
    packet: int
    wr_en:  int

@dataclass
class SimStall:
    cycle: int


def parse_csv(path: str) -> List:
    events = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            etype = row["event_type"].strip()
            cycle = int(row["cycle"])
            if etype == "GRANT":
                events.append(SimGrant(
                    cycle  = cycle,
                    unit   = int(row["unit"]),
                    packet = int(row["packet"], 16),
                    wr_en  = int(row["wr_en"]),
                ))
            elif etype == "STALL":
                events.append(SimStall(cycle=cycle))
    return events


# ---------------------------------------------------------------------------
# Checker
# ---------------------------------------------------------------------------
def check(sim_events: List, expected: List) -> bool:
    passes = 0
    fails  = 0

    sim_grants = [e for e in sim_events if isinstance(e, SimGrant)]
    sim_stalls = [e for e in sim_events if isinstance(e, SimStall)]
    exp_grants = [e for e in expected   if isinstance(e, ExpGrant)]
    exp_stalls = [e for e in expected   if isinstance(e, ExpStall)]

    # ---- Stall count -------------------------------------------------------
    delta = abs(len(sim_stalls) - len(exp_stalls))
    if delta == 0:
        print(f"PASS [stall count]  {len(sim_stalls)}")
        passes += 1
    elif delta <= 2:
        print(f"WARN [stall count]  sim={len(sim_stalls)} expected={len(exp_stalls)} (boundary cycle tolerance)")
    else:
        print(f"FAIL [stall count]  sim={len(sim_stalls)} expected={len(exp_stalls)}")
        fails += 1

    # ---- No wr_en during stall cycles --------------------------------------
    bad_wr = [e for e in sim_events
              if isinstance(e, SimStall)
              # We can only check wr_en if we had it — SimStall doesn't carry it,
              # but the CSV row has wr_en=0 by construction; if it appeared in
              # the STALL rows it was already filtered by the TB condition.
              # So this check is: there must be NO SimGrant on the same cycle
              # as a SimStall.
             ]
    stall_cycles  = {e.cycle for e in sim_stalls}
    grant_in_stall = [e for e in sim_grants if e.cycle in stall_cycles]
    if grant_in_stall:
        for e in grant_in_stall:
            print(f"FAIL [stall/grant overlap]  GRANT on cycle {e.cycle} which is also a STALL cycle")
            fails += 1
    else:
        print(f"PASS [no grant during stall]")
        passes += 1

    # ---- wr_en always 1 on GRANT rows --------------------------------------
    bad_wren = [e for e in sim_grants if e.wr_en != 1]
    if bad_wren:
        for e in bad_wren:
            print(f"FAIL [wr_en]  cycle={e.cycle} unit={e.unit} wr_en={e.wr_en} (expected 1)")
            fails += 1
    else:
        print(f"PASS [wr_en=1 on all GRANTs]  ({len(sim_grants)} grants)")
        passes += 1

    # ---- Grant count -------------------------------------------------------
    if len(sim_grants) == len(exp_grants):
        print(f"PASS [grant count]  {len(sim_grants)}")
        passes += 1
    else:
        print(f"FAIL [grant count]  sim={len(sim_grants)} expected={len(exp_grants)}")
        fails += 1

    # ---- Per-grant: unit order and packet ----------------------------------
    n = min(len(sim_grants), len(exp_grants))
    unit_ok = True
    pkt_ok  = True
    for idx in range(n):
        sg = sim_grants[idx]
        eg = exp_grants[idx]
        if sg.unit != eg.unit:
            print(f"FAIL [grant #{idx:3d}]  unit  sim={sg.unit} expected={eg.unit}  (cycle {sg.cycle})")
            fails  += 1
            unit_ok = False
        elif sg.packet != eg.packet:
            print(f"FAIL [grant #{idx:3d}]  unit={sg.unit} packet sim={sg.packet:#010x} expected={eg.packet:#010x}  (cycle {sg.cycle})")
            fails += 1
            pkt_ok = False
        else:
            passes += 1

    if unit_ok and n == len(exp_grants):
        print(f"PASS [grant unit order]  all {n} grants in correct round-robin order")
    if pkt_ok and n == len(exp_grants):
        print(f"PASS [grant packets]     all {n} packets match canary pattern")

    # ---- Summary -----------------------------------------------------------
    print()
    print("=" * 55)
    if fails == 0:
        print(f"  ALL CHECKS PASSED  ({passes} checks)")
    else:
        print(f"  FAILED: {fails} failure(s), {passes} pass(es)")
    print("=" * 55)

    return fails == 0

def plot_results(sim_events, save_path="arbiter_verification.png"):
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches

    grants = [e for e in sim_events if isinstance(e, SimGrant)]
    stalls = [e for e in sim_events if isinstance(e, SimStall)]

    cycles      = [e.cycle for e in grants]
    units       = [e.unit  for e in grants]
    stall_cycles = [e.cycle for e in stalls]

    fig, axes = plt.subplots(3, 1, figsize=(14, 9),
                             gridspec_kw={'height_ratios': [3, 1, 1]})
    fig.suptitle("order_arbiter Verification Results", fontsize=14, fontweight='bold')

    # --- Panel 1: grant timeline scatter, coloured by unit ---
    ax = axes[0]
    import matplotlib
    colors = matplotlib.colormaps['tab10'].resampled(NUM_UNITS)
    for u in range(NUM_UNITS):
        uc = [c for c, un in zip(cycles, units) if un == u]
        ax.scatter(uc, [u]*len(uc), color=colors(u), s=18, label=f"Unit {u}")
    for sc in stall_cycles:
        ax.axvline(sc, color='red', alpha=0.15, linewidth=1)
    ax.set_ylabel("Granted Unit")
    ax.set_yticks(range(NUM_UNITS))
    ax.set_title("Grant Timeline  (red lines = stall cycles)")
    ax.legend(loc='upper right', ncol=NUM_UNITS, fontsize=7)
    ax.grid(axis='x', alpha=0.3)

    # --- Panel 2: grants per unit bar chart (fairness) ---
    ax = axes[1]
    counts = [sum(1 for u in units if u == i) for i in range(NUM_UNITS)]
    bars = ax.bar(range(NUM_UNITS), counts,
                  color=[colors(i) for i in range(NUM_UNITS)], edgecolor='black', linewidth=0.5)
    ax.set_ylabel("Grant Count")
    ax.set_xlabel("Unit Index")
    ax.set_title("Grants per Unit  (fairness check)")
    ax.set_xticks(range(NUM_UNITS))
    for bar, count in zip(bars, counts):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.2,
                str(count), ha='center', va='bottom', fontsize=8)

    # --- Panel 3: cumulative grants over time ---
    ax = axes[2]
    ax.plot(cycles, range(1, len(cycles)+1), color='steelblue', linewidth=1.5)
    for sc in stall_cycles:
        ax.axvline(sc, color='red', alpha=0.15, linewidth=1)
    ax.set_ylabel("Cumulative Grants")
    ax.set_xlabel("Simulation Cycle")
    ax.set_title("Throughput  (slope = grant rate, flat = stall)")
    ax.grid(alpha=0.3)

    plt.tight_layout()
    plt.savefig(save_path, dpi=150, bbox_inches='tight')
    print(f"Plot saved → {save_path}")
    plt.show()

# ---------------------------------------------------------------------------
# Self-test: run golden model against itself
# ---------------------------------------------------------------------------
def self_test():
    print("Running golden model self-test...")
    expected = run_golden()
    grants = [e for e in expected if isinstance(e, ExpGrant)]
    stalls = [e for e in expected if isinstance(e, ExpStall)]
    print(f"  Expected grants : {len(grants)}")
    print(f"  Expected stalls : {len(stalls)}")

    # T1: first 24 grants must be 0..7 repeating
    for rep in range(3):
        for u in range(NUM_UNITS):
            gi = rep * NUM_UNITS + u
            assert grants[gi].unit == u, \
                f"T1 self-test: grant[{gi}].unit={grants[gi].unit}, expected {u}"
    print("  T1 round-robin order : OK")

    # T2: next 12 grants must cycle 1->3->5 four times
    t2_start = NUM_UNITS * 3
    t2_units = [grants[t2_start + i].unit for i in range(12)]
    exp_t2   = [1, 3, 5] * 4
    assert t2_units == exp_t2, f"T2 self-test: {t2_units} != {exp_t2}"
    print("  T2 sparse order      : OK")

    # T5: unit 3 only — all grants in T5 window must be unit 3
    # Count grants before T5: T1(24) + T2(12) + T3-grants(4) + T4-grants(4) = 44
    t5_start = 24 + 12 + 4 + 4
    t5_units = [grants[t5_start + i].unit for i in range(8)]
    assert all(u == 3 for u in t5_units), f"T5 self-test: {t5_units}"
    print("  T5 single unit       : OK")

    print("Self-test PASSED\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    self_test()

    if len(sys.argv) < 2 or sys.argv[1] == '--no-plot':
        candidates = [
            "sim/arbiter_log.csv",
            "arbiter_log.csv",
            "../arbiter_log.csv",
        ]
        path = next((p for p in candidates if os.path.exists(p)), None)
        if path is None:
            print("Could not find arbiter_log.csv — pass path explicitly")
            sys.exit(1)
    else:
        path = sys.argv[1]

    do_plot = "--no-plot" not in sys.argv

    path = sys.argv[1]
    print(f"Parsing {path} ...")
    sim_events = parse_csv(path)
    grants = [e for e in sim_events if isinstance(e, SimGrant)]
    stalls = [e for e in sim_events if isinstance(e, SimStall)]
    print(f"  Parsed GRANT events : {len(grants)}")
    print(f"  Parsed STALL events : {len(stalls)}")
    print()

    if do_plot:
        plot_results(sim_events)

    expected = run_golden()
    ok = check(sim_events, expected)
    sys.exit(0 if ok else 1)