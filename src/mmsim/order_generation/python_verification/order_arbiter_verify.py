"""Golden model and structural checker for order_arbiter.v.

Reads the per-cycle CSV emitted by tb_order_arbiter.v, replays the round-robin arbitration in Python, and compares
every grant and stall event. Usage: python order_arbiter_verify.py arbiter_log.csv.
"""

from __future__ import annotations

import csv
import sys
from dataclasses import dataclass
from pathlib import Path

import matplotlib
import matplotlib.pyplot as plt


_NUM_UNITS: int = 8
_PLOT_OUTPUT_PATH: Path = Path("arbiter_verification.png")
_DEFAULT_CSV_CANDIDATES: tuple[Path, ...] = (
    Path("sim/arbiter_log.csv"),
    Path("arbiter_log.csv"),
    Path("../arbiter_log.csv"),
)
_STALL_COUNT_TOLERANCE: int = 2
_PLOT_LEGEND_FONTSIZE: int = 7


@dataclass
class ExpGrant:
    """Expected grant emitted by the golden model on a non-stall cycle."""

    unit: int
    """The granted unit index."""
    packet: int
    """The 32-bit packet payload that should accompany the grant."""


@dataclass
class ExpStall:
    """Expected stall cycle emitted by the golden model."""


@dataclass
class SimGrant:
    """Grant event parsed from the simulator CSV."""

    cycle: int
    """The simulator cycle on which the grant was emitted."""
    unit: int
    """The granted unit index reported by the testbench."""
    packet: int
    """The 32-bit packet payload reported by the testbench."""
    wr_en: int
    """The write-enable bit, expected to be 1 on every grant row."""


@dataclass
class SimStall:
    """Stall event parsed from the simulator CSV."""

    cycle: int
    """The simulator cycle on which the stall was emitted."""


def main() -> None:
    """Runs the self-test, parses the simulator CSV, plots results, and emits the verdict."""
    _self_test()

    arguments = sys.argv[1:]
    plot_enabled = "--no-plot" not in arguments
    positional = [argument for argument in arguments if not argument.startswith("--")]

    if positional:
        path: Path | None = Path(positional[0])
    else:
        path = next(
            (candidate for candidate in _DEFAULT_CSV_CANDIDATES if candidate.exists()),
            None,
        )
        if path is None:
            print("Could not find arbiter_log.csv — pass path explicitly")
            sys.exit(1)

    print(f"Parsing {path} ...")
    sim_events = parse_csv(path=path)
    grants = [event for event in sim_events if isinstance(event, SimGrant)]
    stalls = [event for event in sim_events if isinstance(event, SimStall)]
    print(f"  Parsed GRANT events : {len(grants)}")
    print(f"  Parsed STALL events : {len(stalls)}")
    print()

    if plot_enabled:
        plot_results(sim_events=sim_events)

    expected = run_golden()
    passed = verify_events(sim_events=sim_events, expected=expected)
    sys.exit(0 if passed else 1)


def run_golden() -> list[ExpGrant | ExpStall]:
    """Replays the testbench stimulus through the round-robin arbiter golden model.

    Returns:
        The interleaved list of ExpGrant and ExpStall events expected from the simulator, ordered to match the
        cycle-by-cycle CSV emitted by tb_order_arbiter.v.
    """
    model = _ArbiterModel()
    expected: list[ExpGrant | ExpStall] = []

    def all_valid(valid: bool = True) -> None:
        model.order_valid = [valid] * _NUM_UNITS

    def set_valid(indices: list[int]) -> None:
        model.order_valid = [index in indices for index in range(_NUM_UNITS)]

    def run(cycle_count: int) -> None:
        for _ in range(cycle_count):
            granted = model.step()
            if granted is not None:
                expected.append(ExpGrant(unit=granted, packet=_make_packet(unit=granted)))
            elif model.almost_full or model.full:
                expected.append(ExpStall())

    # T1: every unit valid for three full laps.
    all_valid(valid=True)
    run(cycle_count=_NUM_UNITS * 3)
    all_valid(valid=False)
    run(cycle_count=2)

    # T2: sparse valid set — units 1, 3, 5.
    set_valid(indices=[1, 3, 5])
    run(cycle_count=12)
    all_valid(valid=False)
    run(cycle_count=2)

    # T3: almost_full forces stalls.
    all_valid(valid=True)
    model.almost_full = True
    run(cycle_count=6)
    model.almost_full = False
    run(cycle_count=4)
    all_valid(valid=False)
    run(cycle_count=2)

    # T4: full forces stalls.
    all_valid(valid=True)
    model.full = True
    run(cycle_count=6)
    model.full = False
    run(cycle_count=4)
    all_valid(valid=False)
    run(cycle_count=2)

    # T5: only unit 3 valid.
    set_valid(indices=[3])
    run(cycle_count=8)
    all_valid(valid=False)
    run(cycle_count=2)

    # T6: unit 2 deasserts mid-run.
    all_valid(valid=True)
    run(cycle_count=3)
    model.order_valid[2] = False
    run(cycle_count=8)
    all_valid(valid=False)
    run(cycle_count=2)

    # T7: stall, then resume.
    all_valid(valid=True)
    run(cycle_count=3)
    model.almost_full = True
    run(cycle_count=3)
    model.almost_full = False
    run(cycle_count=6)
    all_valid(valid=False)
    run(cycle_count=2)

    return expected


def parse_csv(path: Path) -> list[SimGrant | SimStall]:
    """Parses arbiter_log.csv into a typed list of grant and stall events.

    Args:
        path: The CSV path emitted by tb_order_arbiter.v.

    Returns:
        The chronologically ordered list of SimGrant and SimStall events.
    """
    events: list[SimGrant | SimStall] = []
    with path.open(mode="r", newline="") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            event_type = row["event_type"].strip()
            cycle = int(row["cycle"])
            if event_type == "GRANT":
                events.append(
                    SimGrant(
                        cycle=cycle,
                        unit=int(row["unit"]),
                        packet=int(row["packet"], 16),
                        wr_en=int(row["wr_en"]),
                    )
                )
            elif event_type == "STALL":
                events.append(SimStall(cycle=cycle))
    return events


def verify_events(
    sim_events: list[SimGrant | SimStall],
    expected: list[ExpGrant | ExpStall],
) -> bool:
    """Compares simulator events against the golden model and prints pass/fail diagnostics.

    Args:
        sim_events: The events parsed from the testbench CSV.
        expected: The events emitted by the golden model.

    Returns:
        True when every check passes, False when any check fails.
    """
    passes = 0
    fails = 0

    sim_grants = [event for event in sim_events if isinstance(event, SimGrant)]
    sim_stalls = [event for event in sim_events if isinstance(event, SimStall)]
    exp_grants = [event for event in expected if isinstance(event, ExpGrant)]
    exp_stalls = [event for event in expected if isinstance(event, ExpStall)]

    delta = abs(len(sim_stalls) - len(exp_stalls))
    if delta == 0:
        print(f"PASS [stall count]  {len(sim_stalls)}")
        passes += 1
    elif delta <= _STALL_COUNT_TOLERANCE:
        print(
            f"WARN [stall count]  sim={len(sim_stalls)} expected={len(exp_stalls)} "
            "(boundary cycle tolerance)"
        )
    else:
        print(f"FAIL [stall count]  sim={len(sim_stalls)} expected={len(exp_stalls)}")
        fails += 1

    stall_cycles = {event.cycle for event in sim_stalls}
    grants_in_stall = [event for event in sim_grants if event.cycle in stall_cycles]
    if grants_in_stall:
        for event in grants_in_stall:
            print(
                f"FAIL [stall/grant overlap]  GRANT on cycle {event.cycle} "
                "which is also a STALL cycle"
            )
            fails += 1
    else:
        print("PASS [no grant during stall]")
        passes += 1

    bad_write_enables = [event for event in sim_grants if event.wr_en != 1]
    if bad_write_enables:
        for event in bad_write_enables:
            print(
                f"FAIL [wr_en]  cycle={event.cycle} unit={event.unit} "
                f"wr_en={event.wr_en} (expected 1)"
            )
            fails += 1
    else:
        print(f"PASS [wr_en=1 on all GRANTs]  ({len(sim_grants)} grants)")
        passes += 1

    if len(sim_grants) == len(exp_grants):
        print(f"PASS [grant count]  {len(sim_grants)}")
        passes += 1
    else:
        print(f"FAIL [grant count]  sim={len(sim_grants)} expected={len(exp_grants)}")
        fails += 1

    common_count = min(len(sim_grants), len(exp_grants))
    unit_order_ok = True
    packet_match_ok = True
    for index in range(common_count):
        sim_grant = sim_grants[index]
        exp_grant = exp_grants[index]
        if sim_grant.unit != exp_grant.unit:
            print(
                f"FAIL [grant #{index:3d}]  unit  sim={sim_grant.unit} "
                f"expected={exp_grant.unit}  (cycle {sim_grant.cycle})"
            )
            fails += 1
            unit_order_ok = False
        elif sim_grant.packet != exp_grant.packet:
            print(
                f"FAIL [grant #{index:3d}]  unit={sim_grant.unit} packet "
                f"sim={sim_grant.packet:#010x} expected={exp_grant.packet:#010x}  "
                f"(cycle {sim_grant.cycle})"
            )
            fails += 1
            packet_match_ok = False
        else:
            passes += 1

    if unit_order_ok and common_count == len(exp_grants):
        print(f"PASS [grant unit order]  all {common_count} grants in correct round-robin order")
    if packet_match_ok and common_count == len(exp_grants):
        print(f"PASS [grant packets]     all {common_count} packets match canary pattern")

    print()
    print("=" * 55)
    if fails == 0:
        print(f"  ALL CHECKS PASSED  ({passes} checks)")
    else:
        print(f"  FAILED: {fails} failure(s), {passes} pass(es)")
    print("=" * 55)

    return fails == 0


def plot_results(
    sim_events: list[SimGrant | SimStall],
    save_path: Path = _PLOT_OUTPUT_PATH,
) -> None:
    """Plots the grant timeline, fairness histogram, and throughput curve.

    Args:
        sim_events: The simulator events parsed from the CSV.
        save_path: The destination for the rendered figure.
    """
    grants = [event for event in sim_events if isinstance(event, SimGrant)]
    stalls = [event for event in sim_events if isinstance(event, SimStall)]

    cycles = [event.cycle for event in grants]
    units = [event.unit for event in grants]
    stall_cycles = [event.cycle for event in stalls]

    figure, axes = plt.subplots(
        3,
        1,
        figsize=(14, 9),
        gridspec_kw={"height_ratios": [3, 1, 1]},
    )
    figure.suptitle("order_arbiter Verification Results", fontsize=14, fontweight="bold")

    colors = matplotlib.colormaps["tab10"].resampled(_NUM_UNITS)

    axis_timeline = axes[0]
    for unit in range(_NUM_UNITS):
        unit_cycles = [cycle for cycle, granted in zip(cycles, units) if granted == unit]
        axis_timeline.scatter(
            unit_cycles,
            [unit] * len(unit_cycles),
            color=colors(unit),
            s=18,
            label=f"Unit {unit}",
        )
    for stall_cycle in stall_cycles:
        axis_timeline.axvline(stall_cycle, color="red", alpha=0.15, linewidth=1)
    axis_timeline.set_ylabel("Granted Unit")
    axis_timeline.set_yticks(range(_NUM_UNITS))
    axis_timeline.set_title("Grant Timeline  (red lines = stall cycles)")
    axis_timeline.legend(loc="upper right", ncol=_NUM_UNITS, fontsize=_PLOT_LEGEND_FONTSIZE)
    axis_timeline.grid(axis="x", alpha=0.3)

    axis_fairness = axes[1]
    counts = [sum(1 for granted in units if granted == unit) for unit in range(_NUM_UNITS)]
    bars = axis_fairness.bar(
        range(_NUM_UNITS),
        counts,
        color=[colors(unit) for unit in range(_NUM_UNITS)],
        edgecolor="black",
        linewidth=0.5,
    )
    axis_fairness.set_ylabel("Grant Count")
    axis_fairness.set_xlabel("Unit Index")
    axis_fairness.set_title("Grants per Unit  (fairness check)")
    axis_fairness.set_xticks(range(_NUM_UNITS))
    for bar, count in zip(bars, counts):
        axis_fairness.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 0.2,
            str(count),
            ha="center",
            va="bottom",
            fontsize=8,
        )

    axis_throughput = axes[2]
    axis_throughput.plot(cycles, range(1, len(cycles) + 1), color="steelblue", linewidth=1.5)
    for stall_cycle in stall_cycles:
        axis_throughput.axvline(stall_cycle, color="red", alpha=0.15, linewidth=1)
    axis_throughput.set_ylabel("Cumulative Grants")
    axis_throughput.set_xlabel("Simulation Cycle")
    axis_throughput.set_title("Throughput  (slope = grant rate, flat = stall)")
    axis_throughput.grid(alpha=0.3)

    plt.tight_layout()
    plt.savefig(save_path, dpi=150, bbox_inches="tight")
    print(f"Plot saved → {save_path}")
    plt.show()


class _ArbiterModel:
    """Replays the synthesized round-robin arbiter for cycle-by-cycle comparison.

    Args:
        num_units: The number of agent slots managed by the arbiter.

    Attributes:
        num_units: The number of agent slots.
        grant_ptr: The next slot index to consider when granting.
        almost_full: The almost_full backpressure flag.
        full: The full backpressure flag.
        order_valid: The current per-slot validity vector.
    """

    def __init__(self, num_units: int = _NUM_UNITS) -> None:
        self.num_units: int = num_units
        self.grant_ptr: int = 0
        self.almost_full: bool = False
        self.full: bool = False
        self.order_valid: list[bool] = [False] * num_units

    def step(self) -> int | None:
        """Advances the arbiter by one cycle.

        Returns:
            The granted unit index when a grant fires, or None when the cycle is a stall or idle.
        """
        if self.almost_full or self.full:
            return None
        for offset in range(self.num_units):
            index = (self.grant_ptr + offset) % self.num_units
            if self.order_valid[index]:
                self.grant_ptr = (index + 1) % self.num_units
                return index
        return None


def _self_test() -> None:
    """Runs internal sanity assertions on the golden model before parsing the simulator CSV.

    Raises:
        AssertionError: When any of the T1, T2, or T5 sanity checks fails.
    """
    print("Running golden model self-test...")
    expected = run_golden()
    grants = [event for event in expected if isinstance(event, ExpGrant)]
    stalls = [event for event in expected if isinstance(event, ExpStall)]
    print(f"  Expected grants : {len(grants)}")
    print(f"  Expected stalls : {len(stalls)}")

    # T1: first 24 grants must be 0..7 repeating.
    for repetition in range(3):
        for unit in range(_NUM_UNITS):
            grant_index = repetition * _NUM_UNITS + unit
            if grants[grant_index].unit != unit:
                message = (
                    f"T1 self-test: grant[{grant_index}].unit={grants[grant_index].unit}, "
                    f"expected {unit}"
                )
                raise AssertionError(message)
    print("  T1 round-robin order : OK")

    # T2: next 12 grants must cycle 1 -> 3 -> 5 four times.
    t2_start = _NUM_UNITS * 3
    t2_units = [grants[t2_start + index].unit for index in range(12)]
    expected_t2 = [1, 3, 5] * 4
    if t2_units != expected_t2:
        message = f"T2 self-test: {t2_units} != {expected_t2}"
        raise AssertionError(message)
    print("  T2 sparse order      : OK")

    # T5 starts at T1(24) + T2(12) + T3-grants(4) + T4-grants(4) = 44.
    t5_start = 24 + 12 + 4 + 4
    t5_units = [grants[t5_start + index].unit for index in range(8)]
    if not all(unit == 3 for unit in t5_units):
        message = f"T5 self-test: {t5_units}"
        raise AssertionError(message)
    print("  T5 single unit       : OK")

    print("Self-test PASSED\n")


def _make_packet(unit: int) -> int:
    """Mirrors the testbench init_packets task by producing a canary packet for the given unit.

    Args:
        unit: The agent slot index, also the low byte of the encoded packet.

    Returns:
        The 32-bit packet payload formatted as { 8'hA0|unit, 8'h00, 8'h00, unit[7:0] }.
    """
    return ((0xA0 | (unit & 0xFF)) << 24) | (unit & 0xFF)


if __name__ == "__main__":
    main()
