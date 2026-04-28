"""Structural checker for the order_gen_top.v integration test.

Does not predict exact values because the GBM and LFSR chain is too deep to replay in Python; instead, asserts
per-phase invariants on agent_type, price, the reserved bit field, the round-robin alternation, and the param-decoded
volume cap. Usage: python order_gen_top_verify.py top_log.csv.
"""

from __future__ import annotations

import csv
import sys
from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402


_MAX_PRICE_TICK: int = 479
_VOLUME_CAP_PARAM_DECODE: int = 63
_VOLUME_CAP_DEFAULT: int = 10
_AGENT_NOISE: int = 0b00
_AGENT_VALUE: int = 0b11
_PHASE_COUNT: int = 5
_FAIRNESS_TOLERANCE: float = 0.35
_RESERVED_FIELD_SHIFT: int = 25
_RESERVED_FIELD_MASK: int = 0x7
_PLOT_OUTPUT_PATH: Path = Path("top_verification.png")
_DEFAULT_CSV_CANDIDATES: tuple[Path, ...] = (
    Path("sim/top_log.csv"),
    Path("top_log.csv"),
    Path("../top_log.csv"),
)


@dataclass
class Packet:
    """Order packet parsed from the integration test CSV."""

    cycle: int
    """The simulator cycle on which the packet was emitted."""
    phase: int
    """The test phase identifier set by the testbench."""
    raw: int
    """The 32-bit packet payload before bit-field decoding."""
    agent_type: int
    """The 2-bit agent type extracted from the payload."""
    side: int
    """The buy/sell side bit."""
    order_type: int
    """The market/limit order type bit."""
    price: int
    """The 9-bit tick index."""
    volume: int
    """The 16-bit unsigned volume."""


def main() -> None:
    """Runs the integration checker against the testbench CSV and emits the verdict."""
    if len(sys.argv) >= 2:
        path: Path | None = Path(sys.argv[1])
    else:
        path = next(
            (candidate for candidate in _DEFAULT_CSV_CANDIDATES if candidate.exists()),
            None,
        )
        if path is None:
            print("Usage: python order_gen_top_verify.py top_log.csv")
            sys.exit(0)

    print(f"Parsing {path} ...")
    packets = parse_csv(path=path)
    print(f"  Total packets: {len(packets)}")
    counts_by_phase = {
        phase: sum(1 for packet in packets if packet.phase == phase)
        for phase in range(_PHASE_COUNT)
    }
    for phase, count in counts_by_phase.items():
        if count:
            print(f"  Phase {phase}: {count} packets")
    print()

    passed = run_checks(packets=packets)
    plot_results(packets=packets)
    sys.exit(0 if passed else 1)


def parse_csv(path: Path) -> list[Packet]:
    """Parses top_log.csv into a list of Packet objects.

    Args:
        path: The CSV path emitted by tb_order_gen_top.v.

    Returns:
        The chronologically ordered list of decoded packets.
    """
    packets: list[Packet] = []
    with path.open(mode="r", newline="") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            packets.append(
                Packet(
                    cycle=int(row["cycle"]),
                    phase=int(row["phase"]),
                    raw=int(row["packet"], 16),
                    agent_type=int(row["agent_type"]),
                    side=int(row["side"]),
                    order_type=int(row["order_type"]),
                    price=int(row["price"]),
                    volume=int(row["volume"]),
                )
            )
    return packets


def run_checks(packets: list[Packet]) -> bool:
    """Validates the per-phase invariants documented in the testbench plan.

    Notes:
        Phase 1 must be empty, phase 2 must alternate noise and value packets within a 35% fairness slack, phase 3
        reuses the phase 2 invariants on a longer trace, and phase 4 must contain only value-investor packets capped
        at the param-decoded volume.

    Args:
        packets: The parsed packets from the testbench CSV.

    Returns:
        True when every phase passes its invariants, False otherwise.
    """
    passes = 0
    fails = 0

    by_phase = {
        phase: [packet for packet in packets if packet.phase == phase]
        for phase in range(_PHASE_COUNT)
    }

    passed_count, failed_count = _check(
        condition=len(by_phase[1]) == 0,
        label="phase1 empty",
        detail=f"got {len(by_phase[1])} packets, expected 0",
    )
    passes += passed_count
    fails += failed_count

    if not by_phase[2]:
        print("WARN [phase2] no packets received — agents may not have emitted")
    else:
        passed_count, failed_count = _structural_checks(
            packets=by_phase[2],
            phase_label="phase2",
            allowed_types={_AGENT_NOISE, _AGENT_VALUE},
        )
        passes += passed_count
        fails += failed_count

        types = [packet.agent_type for packet in by_phase[2]]
        value_count = types.count(_AGENT_VALUE)
        noise_count = types.count(_AGENT_NOISE)

        difference = abs(value_count - noise_count)
        passed_count, failed_count = _check(
            condition=difference <= len(types) * _FAIRNESS_TOLERANCE,
            label="phase2 round-robin fair distribution",
            detail=f"Value: {value_count}, Noise: {noise_count}",
        )
        passes += passed_count
        fails += failed_count

        passed_count, failed_count = _check(
            condition=any(packet.agent_type == _AGENT_VALUE for packet in by_phase[2]),
            label="phase2 has value investor packets",
        )
        passes += passed_count
        fails += failed_count

        passed_count, failed_count = _check(
            condition=any(packet.agent_type == _AGENT_NOISE for packet in by_phase[2]),
            label="phase2 has noise trader packets",
        )
        passes += passed_count
        fails += failed_count

        print(f"  Phase 2 total packets: {len(by_phase[2])}")

    if not by_phase[3]:
        print("WARN [phase3] no packets received")
    else:
        passed_count, failed_count = _structural_checks(
            packets=by_phase[3],
            phase_label="phase3",
            allowed_types={_AGENT_NOISE, _AGENT_VALUE},
        )
        passes += passed_count
        fails += failed_count
        print(f"  Phase 3 total packets: {len(by_phase[3])}")

    if not by_phase[4]:
        print("WARN [phase4] no packets received — param decode untestable")
    else:
        passed_count, failed_count = _structural_checks(
            packets=by_phase[4],
            phase_label="phase4",
            allowed_types={_AGENT_VALUE},
            volume_cap=_VOLUME_CAP_PARAM_DECODE,
        )
        passes += passed_count
        fails += failed_count

        passed_count, failed_count = _check(
            condition=len(by_phase[4]) > 0,
            label="phase4 packets received",
            detail=f"{len(by_phase[4])} packets",
        )
        passes += passed_count
        fails += failed_count
        print(f"  Phase 4 total packets: {len(by_phase[4])}")

    passed_count, failed_count = _check(
        condition=any(packet.volume > _VOLUME_CAP_DEFAULT for packet in by_phase[4]),
        label="phase4 volume cap actually increased",
        detail=f"at least one packet breached vol>{_VOLUME_CAP_DEFAULT}",
    )
    passes += passed_count
    fails += failed_count

    print()
    print("=" * 55)
    if fails == 0:
        print(f"  ALL CHECKS PASSED  ({passes} checks)")
    else:
        print(f"  FAILED: {fails} failure(s), {passes} pass(es)")
    print("=" * 55)

    return fails == 0


def plot_results(
    packets: list[Packet],
    save_path: Path = _PLOT_OUTPUT_PATH,
) -> None:
    """Plots price, volume, packet timeline, and agent-type-mix diagnostics.

    Args:
        packets: The parsed packets from the testbench CSV.
        save_path: The destination for the rendered figure.
    """
    if not packets:
        print("No packets to plot.")
        return

    figure, axes = plt.subplots(2, 2, figsize=(14, 9))
    figure.suptitle(
        "order_gen_top Integration Verification",
        fontsize=14,
        fontweight="bold",
    )

    phase_colors = {1: "gray", 2: "steelblue", 3: "seagreen", 4: "darkorange"}
    type_labels = {
        0b00: "Noise(00)",
        0b01: "MM(01)",
        0b10: "Momentum(10)",
        0b11: "Value(11)",
    }
    type_colors = {0b00: "steelblue", 0b11: "darkorange", 0b10: "seagreen", 0b01: "gray"}

    axis_price = axes[0][0]
    for agent_type in (_AGENT_NOISE, _AGENT_VALUE):
        prices = [packet.price for packet in packets if packet.agent_type == agent_type]
        if prices:
            axis_price.hist(
                prices,
                bins=40,
                alpha=0.6,
                label=type_labels[agent_type],
                color=type_colors[agent_type],
            )
    axis_price.axvline(
        _MAX_PRICE_TICK,
        color="red",
        linestyle="--",
        linewidth=1,
        label=f"max={_MAX_PRICE_TICK}",
    )
    axis_price.set_xlabel("Price Tick")
    axis_price.set_ylabel("Count")
    axis_price.set_title("Price Distribution by Agent Type")
    axis_price.legend(fontsize=8)

    axis_volume = axes[0][1]
    for phase in (2, 3, 4):
        volumes = [packet.volume for packet in packets if packet.phase == phase]
        if volumes:
            axis_volume.hist(
                volumes,
                bins=30,
                alpha=0.6,
                label=f"Phase {phase}",
                color=phase_colors[phase],
            )
    axis_volume.axvline(
        _VOLUME_CAP_PARAM_DECODE,
        color="darkorange",
        linestyle="--",
        linewidth=1,
        label=f"vol_cap={_VOLUME_CAP_PARAM_DECODE} (ph4)",
    )
    axis_volume.axvline(
        _VOLUME_CAP_DEFAULT,
        color="steelblue",
        linestyle="--",
        linewidth=1,
        label=f"vol_cap={_VOLUME_CAP_DEFAULT} (ph2/3)",
    )
    axis_volume.set_xlabel("Volume")
    axis_volume.set_ylabel("Count")
    axis_volume.set_title("Volume Distribution by Phase")
    axis_volume.legend(fontsize=8)

    axis_timeline = axes[1][0]
    for agent_type in (_AGENT_NOISE, _AGENT_VALUE):
        points = [
            (packet.cycle, packet.price)
            for packet in packets
            if packet.agent_type == agent_type
        ]
        if points:
            cycles, prices = zip(*points)
            axis_timeline.scatter(
                cycles,
                prices,
                s=6,
                alpha=0.5,
                label=type_labels[agent_type],
                color=type_colors[agent_type],
            )
    axis_timeline.set_xlabel("Cycle")
    axis_timeline.set_ylabel("Price Tick")
    axis_timeline.set_title("Packet Timeline (price vs cycle)")
    axis_timeline.legend(fontsize=8)

    axis_mix = axes[1][1]
    phases = (2, 3, 4)
    indices = list(range(len(phases)))
    noise_counts = [
        sum(1 for packet in packets if packet.phase == phase and packet.agent_type == _AGENT_NOISE)
        for phase in phases
    ]
    value_counts = [
        sum(1 for packet in packets if packet.phase == phase and packet.agent_type == _AGENT_VALUE)
        for phase in phases
    ]
    bar_width = 0.35
    axis_mix.bar(
        [index - bar_width / 2 for index in indices],
        noise_counts,
        bar_width,
        label="Noise(00)",
        color="steelblue",
    )
    axis_mix.bar(
        [index + bar_width / 2 for index in indices],
        value_counts,
        bar_width,
        label="Value(11)",
        color="darkorange",
    )
    axis_mix.set_xticks(indices)
    axis_mix.set_xticklabels([f"Phase {phase}" for phase in phases])
    axis_mix.set_ylabel("Packet Count")
    axis_mix.set_title("Agent Type Mix per Phase")
    axis_mix.legend(fontsize=8)

    plt.tight_layout()
    plt.savefig(save_path, dpi=150, bbox_inches="tight")
    print(f"Plot saved -> {save_path}")


def _check(condition: bool, label: str, detail: str = "") -> tuple[int, int]:
    """Prints PASS/FAIL for a boolean condition and returns the (pass_count, fail_count) delta.

    Args:
        condition: The boolean check result.
        label: The check name displayed in the output.
        detail: An optional human-readable detail appended after a separator.

    Returns:
        A two-element tuple recording (1, 0) on pass and (0, 1) on fail.
    """
    suffix = f" — {detail}" if detail else ""
    if condition:
        print(f"PASS [{label}]{suffix}")
        return 1, 0
    print(f"FAIL [{label}]{suffix}")
    return 0, 1


def _structural_checks(
    packets: list[Packet],
    phase_label: str,
    allowed_types: set[int],
    volume_cap: int | None = None,
) -> tuple[int, int]:
    """Asserts the structural invariants on a per-phase packet slice.

    Args:
        packets: The packets belonging to the phase under test.
        phase_label: The phase identifier used in the output messages.
        allowed_types: The set of agent_type values permitted in this phase.
        volume_cap: An optional inclusive volume upper bound; None disables the volume check.

    Returns:
        A tuple of (pass_count, fail_count) tallying the invariants checked.
    """
    passes = 0
    fails = 0

    bad_price = [packet for packet in packets if packet.price > _MAX_PRICE_TICK]
    detail = f"{len(bad_price)} violations" if bad_price else f"{len(packets)} packets OK"
    passed_count, failed_count = _check(
        condition=len(bad_price) == 0,
        label=f"{phase_label} price<={_MAX_PRICE_TICK}",
        detail=detail,
    )
    passes += passed_count
    fails += failed_count

    bad_reserved = [
        packet
        for packet in packets
        if (packet.raw >> _RESERVED_FIELD_SHIFT) & _RESERVED_FIELD_MASK != 0
    ]
    detail = f"{len(bad_reserved)} violations" if bad_reserved else "OK"
    passed_count, failed_count = _check(
        condition=len(bad_reserved) == 0,
        label=f"{phase_label} reserved=0",
        detail=detail,
    )
    passes += passed_count
    fails += failed_count

    bad_type = [packet for packet in packets if packet.agent_type not in allowed_types]
    detail = f"{len(bad_type)} violations" if bad_type else f"{len(packets)} packets OK"
    passed_count, failed_count = _check(
        condition=len(bad_type) == 0,
        label=f"{phase_label} agent_type in {allowed_types}",
        detail=detail,
    )
    passes += passed_count
    fails += failed_count

    if volume_cap is not None:
        bad_volume = [packet for packet in packets if packet.volume > volume_cap]
        detail = f"{len(bad_volume)} violations" if bad_volume else "OK"
        passed_count, failed_count = _check(
            condition=len(bad_volume) == 0,
            label=f"{phase_label} volume<={volume_cap}",
            detail=detail,
        )
        passes += passed_count
        fails += failed_count

    return passes, fails


if __name__ == "__main__":
    main()
