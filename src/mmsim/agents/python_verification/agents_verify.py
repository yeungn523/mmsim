"""Verifies the ModelSim CSV output of agent_execution_unit against a Python golden model.

Cross-checks per-phase emissions for the noise, value, and momentum strategies and emits
per-strategy diagnostic plots. The active strategy is selected by _TARGET_TEST.
"""

from pathlib import Path
from typing import Literal

import matplotlib.gridspec as gridspec
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

_TARGET_TEST: Literal["NOISE", "VALUE", "MOMENTUM"] = "MOMENTUM"

_LFSR_POLY: int = 0xB4BCD35C
_LFSR_SEED: int = 0xCAFEBABE
_NEAR_NOISE_THRESHOLD: int = 16
_CLOCK_MASK: int = 0xFFFFFFFF

_INPUT_CSV: Path = Path("sim_output.csv")
_NOISE_PLOT_PATH: Path = Path("noise_agent_verification.png")
_VALUE_PLOT_PATH: Path = Path("value_agent_verification.png")
_MOMENTUM_PLOT_PATH: Path = Path("momentum_agent_verification.png")

_AGENT_NOISE: int = 0b00
_AGENT_MOMENTUM: int = 0b10
_AGENT_VALUE: int = 0b11

_PHASES: list[dict[str, int | str]] = [
    {
        "id": 1,
        "name": "Always Emit (param1=1023)",
        "param_data": (0b00 << 30) | (0x3FF << 20) | (50 << 10) | 100,
        "gbm_price": 0x64000000,
        "last_executed_price": 0x64000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 400,
    },
    {
        "id": 2,
        "name": "Never Emit (param1=0)",
        "param_data": (0b00 << 30) | (0x000 << 20) | (50 << 10) | 100,
        "gbm_price": 0x64000000,
        "last_executed_price": 0x64000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 200,
    },
    {
        "id": 3,
        "name": "50pct Emit (param1=512)",
        "param_data": (0b00 << 30) | (512 << 20) | (50 << 10) | 100,
        "gbm_price": 0x64000000,
        "last_executed_price": 0x64000000,
        "oldest_executed_price": 0x64000000,
        # 4000 cycles plus 4 setup cycles from the testbench transition equals 4004.
        "cycles": 4004,
    },
    {
        "id": 4,
        "name": "Value: Undervalued (Buy)",
        "param_data": (0b11 << 30) | (10 << 20) | (256 << 10) | 100,
        "gbm_price": 0x78000000,
        "last_executed_price": 0x64000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 200,
    },
    {
        "id": 5,
        "name": "Value: Overvalued (Sell)",
        "param_data": (0b11 << 30) | (10 << 20) | (256 << 10) | 100,
        "gbm_price": 0x50000000,
        "last_executed_price": 0x64000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 200,
    },
    {
        "id": 6,
        "name": "Value: Within Threshold (Silent)",
        "param_data": (0b11 << 30) | (10 << 20) | (256 << 10) | 100,
        "gbm_price": 0x66000000,
        "last_executed_price": 0x64000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 200,
    },
    {
        "id": 7,
        "name": "Momentum: Uptrend (Buy)",
        "param_data": (0b10 << 30) | (10 << 20) | (256 << 10) | 100,
        # The momentum strategy ignores the GBM price; the field is retained for struct parity.
        "gbm_price": 0x64000000,
        "last_executed_price": 0x78000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 200,
    },
    {
        "id": 8,
        "name": "Momentum: Downtrend (Sell)",
        "param_data": (0b10 << 30) | (10 << 20) | (256 << 10) | 100,
        "gbm_price": 0x64000000,
        "last_executed_price": 0x50000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 200,
    },
    {
        "id": 9,
        "name": "Momentum: Sideways (Silent)",
        "param_data": (0b10 << 30) | (10 << 20) | (256 << 10) | 100,
        "gbm_price": 0x64000000,
        "last_executed_price": 0x66000000,
        "oldest_executed_price": 0x64000000,
        "cycles": 200,
    },
]


def lfsr_next(state: int, polynomial: int = _LFSR_POLY) -> int:
    """Advances the 32-bit Galois LFSR by one step.

    Args:
        state: The current 32-bit LFSR state interpreted as an unsigned integer.
        polynomial: The Galois feedback polynomial applied when the least significant bit of the
            current state is set.

    Returns:
        The next 32-bit LFSR state, masked to 32 bits.
    """
    least_significant_bit = state & 1
    state = (state >> 1) & _CLOCK_MASK
    if least_significant_bit:
        state ^= polynomial
    return state


def gbm_price_to_tick(gbm_price_q824: int) -> int:
    """Converts a Q8.24 GBM price into the bounded tick index used by the matching engine.

    Args:
        gbm_price_q824: The fixed-point price emitted by the GBM module.

    Returns:
        The tick index clamped to the legal range [0, 479].
    """
    tick = (gbm_price_q824 >> 23) & 0x1FF
    return min(tick, 479)


def decode_param_data(param_data: int) -> tuple[int, int, int, int]:
    """Decodes the packed agent parameter word produced by the testbench.

    Args:
        param_data: The 32-bit parameter word loaded into the agent execution unit, encoding the
            agent type in the top two bits and three 10-bit parameter fields in the lower bits.

    Returns:
        A tuple of agent_type, param1, param2, and param3 in the order they appear in the
        parameter word.
    """
    agent_type = (param_data >> 30) & 0x3
    param1 = (param_data >> 20) & 0x3FF
    param2 = (param_data >> 10) & 0x3FF
    param3 = (param_data >> 0) & 0x3FF
    return agent_type, param1, param2, param3


def run_golden_model(
    phase: dict[str, int | str],
    lfsr_init: int,
) -> tuple[list[dict[str, int]], int]:
    """Replays one phase of the agent execution unit using the Python golden model.

    Notes:
        The model consumes four LFSR states per slot evaluation to mirror the four-cycle slot
        cadence of the RTL pipeline. The third state in each slot drives the noise trader's
        random fields. Momentum and value strategies are deterministic and do not sample the
        LFSR; they only advance it.

    Args:
        phase: The phase configuration entry from _PHASES.
        lfsr_init: The LFSR state at the start of the phase, threaded across phases by the
            caller to mirror the testbench's continuous LFSR.

    Returns:
        A tuple of the list of predicted emissions for the phase and the LFSR state at the end
        of the phase.
    """
    param_data = int(phase["param_data"])
    gbm_price = int(phase["gbm_price"])
    last_executed_price = int(phase["last_executed_price"])
    oldest_executed_price = int(phase.get("oldest_executed_price", 0x64000000))
    num_cycles = int(phase["cycles"])

    agent_type, param1, param2, param3 = decode_param_data(param_data=param_data)
    gbm_tick = gbm_price_to_tick(gbm_price_q824=gbm_price)
    last_executed_tick = gbm_price_to_tick(gbm_price_q824=last_executed_price)
    oldest_executed_tick = gbm_price_to_tick(gbm_price_q824=oldest_executed_price)

    predictions: list[dict[str, int]] = []
    lfsr = lfsr_init
    num_evaluations = num_cycles // 4

    for slot_evaluation in range(num_evaluations):
        lfsr = lfsr_next(state=lfsr)
        lfsr = lfsr_next(state=lfsr)
        lfsr_sample = lfsr
        lfsr = lfsr_next(state=lfsr)
        lfsr = lfsr_next(state=lfsr)

        if agent_type == _AGENT_NOISE:
            emission_random = lfsr_sample & 0x3FF
            side_bit = (lfsr_sample >> 10) & 0x1
            offset_random = (lfsr_sample >> 11) & 0x3FF
            volume_random = (lfsr_sample >> 21) & 0x3FF

            if emission_random >= param1:
                continue

            offset_raw = (offset_random * param2) >> 10
            offset_ticks = min(offset_raw, 479) & 0x1FF

            volume_raw = (volume_random * param3) >> 10
            volume = (volume_raw & 0xFFFF) + 1

            if side_bit == 0:
                final_price = max(gbm_tick - offset_ticks, 0)
            else:
                final_price = min(gbm_tick + offset_ticks, 479)

            order_type = 1 if offset_ticks < _NEAR_NOISE_THRESHOLD else 0

            predictions.append({
                "slot_eval": slot_evaluation,
                "cycle": slot_evaluation * 4 + 3,
                "side": side_bit,
                "order_type": order_type,
                "agent_type": agent_type,
                "price": final_price,
                "volume": volume,
            })

        elif agent_type == _AGENT_MOMENTUM:
            momentum_delta = last_executed_tick - oldest_executed_tick
            absolute_momentum = abs(momentum_delta)

            if absolute_momentum <= param1:
                continue

            side_bit = 0 if momentum_delta > 0 else 1
            dsp_product = absolute_momentum * param2
            volume_raw = (dsp_product >> 10) + 1
            volume = min(volume_raw, param3)

            # Momentum trades are market orders that fire at the front of the book.
            final_price = last_executed_tick
            order_type = 1

            predictions.append({
                "slot_eval": slot_evaluation,
                "cycle": slot_evaluation * 4 + 3,
                "side": side_bit,
                "order_type": order_type,
                "agent_type": agent_type,
                "price": final_price,
                "volume": volume,
            })

        elif agent_type == _AGENT_VALUE:
            divergence = gbm_tick - last_executed_tick
            absolute_divergence = abs(divergence)

            if absolute_divergence <= param1:
                continue

            side_bit = 0 if divergence > 0 else 1
            dsp_product = absolute_divergence * param2
            volume_raw = (dsp_product >> 10) + 1
            volume = min(volume_raw, param3)

            # Value trades are limit orders pegged to the GBM fair value tick.
            final_price = gbm_tick
            order_type = 0

            predictions.append({
                "slot_eval": slot_evaluation,
                "cycle": slot_evaluation * 4 + 3,
                "side": side_bit,
                "order_type": order_type,
                "agent_type": agent_type,
                "price": final_price,
                "volume": volume,
            })

    return predictions, lfsr


def compare_phase(
    phase_id: int,
    predictions: list[dict[str, int]],
    actual_df: pd.DataFrame,
) -> tuple[int, int, int]:
    """Compares the golden model predictions against the testbench CSV for a single phase.

    Args:
        phase_id: The phase identifier shared between the testbench output and _PHASES.
        predictions: The golden model emissions produced by run_golden_model.
        actual_df: The full testbench output DataFrame containing rows for every phase.

    Returns:
        A tuple of the number of exact field matches, the number of mismatched emissions, and
        the number of emissions present on one side but not the other.
    """
    actual = actual_df[actual_df["phase"] == phase_id].reset_index(drop=True)

    print(f"\n--- Phase {phase_id} comparison ---")
    print(f"  Predicted emissions : {len(predictions)}")
    print(f"  Actual emissions    : {len(actual)}")

    if not predictions and actual.empty:
        print("  PASS: Both predict zero emissions")
        return 0, 0, 0

    if len(predictions) != len(actual):
        print(f"  WARN: Emission count mismatch -- predicted {len(predictions)}, got {len(actual)}")

    matches = 0
    mismatches = 0
    check_count = min(len(predictions), len(actual))

    for index in range(check_count):
        predicted = predictions[index]
        actual_row = actual.iloc[index]

        fields_match = (
            predicted["side"] == int(actual_row["side"])
            and predicted["order_type"] == int(actual_row["order_type"])
            and predicted["agent_type"] == int(actual_row["agent_type"])
            and predicted["price"] == int(actual_row["price"])
            and predicted["volume"] == int(actual_row["volume"])
        )

        if fields_match:
            matches += 1
            continue

        mismatches += 1
        if mismatches <= 5:
            print(f"  MISMATCH at emission {index}:")
            print(
                f"    Predicted: side={predicted['side']} type={predicted['order_type']} "
                f"price={predicted['price']} vol={predicted['volume']}"
            )
            print(
                f"    Actual:    side={int(actual_row['side'])} type={int(actual_row['order_type'])} "
                f"price={int(actual_row['price'])} vol={int(actual_row['volume'])}"
            )

    missing = abs(len(predictions) - len(actual))
    print(f"  Matches: {matches}, Mismatches: {mismatches}, Missing: {missing}")
    if mismatches == 0 and missing == 0:
        print(f"  PASS: All {matches} emissions match exactly")

    return matches, mismatches, missing


def plot_noise_results(
    actual_df: pd.DataFrame,
    predictions_by_phase: dict[int, list[dict[str, int]]],
) -> None:
    """Plots noise trader diagnostics across phases 1 and 3.

    Args:
        actual_df: The full testbench output DataFrame for all phases.
        predictions_by_phase: The golden model emissions keyed by phase identifier.
    """
    figure = plt.figure(figsize=(18, 10))
    figure.suptitle("Agent Execution Unit -- Noise Trader Verification", fontsize=14, fontweight="bold")
    grid = gridspec.GridSpec(2, 3, figure=figure, hspace=0.4, wspace=0.35)

    phase_one_actual = actual_df[actual_df["phase"] == 1]
    phase_one_predicted = pd.DataFrame(predictions_by_phase.get(1, []))

    gbm_tick_phase_one = gbm_price_to_tick(gbm_price_q824=int(_PHASES[0]["gbm_price"]))
    _, _, param2_phase_one, param3_phase_one = decode_param_data(param_data=int(_PHASES[0]["param_data"]))

    axis_price = figure.add_subplot(grid[0, 0])
    if not phase_one_actual.empty:
        axis_price.hist(
            phase_one_actual["price"].astype(int),
            bins=30,
            alpha=0.6,
            color="steelblue",
            label="RTL output",
            density=True,
        )
    if not phase_one_predicted.empty:
        axis_price.hist(
            phase_one_predicted["price"].astype(int),
            bins=30,
            alpha=0.6,
            color="orange",
            label="Golden model",
            density=True,
        )
    axis_price.axvline(
        gbm_tick_phase_one,
        color="red",
        linestyle="--",
        linewidth=1.5,
        label=f"GBM tick={gbm_tick_phase_one}",
    )
    axis_price.set_title("Phase 1: Price Distribution")
    axis_price.set_xlabel("Tick index (0-479)")
    axis_price.set_ylabel("Density")
    axis_price.legend(fontsize=8)
    axis_price.set_xlim(0, 479)

    axis_volume = figure.add_subplot(grid[0, 1])
    if not phase_one_actual.empty:
        axis_volume.hist(
            phase_one_actual["volume"].astype(int),
            bins=20,
            alpha=0.6,
            color="steelblue",
            label="RTL output",
            density=True,
        )
    if not phase_one_predicted.empty:
        axis_volume.hist(
            phase_one_predicted["volume"].astype(int),
            bins=20,
            alpha=0.6,
            color="orange",
            label="Golden model",
            density=True,
        )
    axis_volume.set_title(f"Phase 1: Volume Distribution (max={param3_phase_one})")
    axis_volume.set_xlabel("Volume (shares)")
    axis_volume.set_ylabel("Density")
    axis_volume.legend(fontsize=8)

    axis_side = figure.add_subplot(grid[0, 2])
    if not phase_one_actual.empty:
        buy_count = int((phase_one_actual["side"] == 0).sum())
        sell_count = int((phase_one_actual["side"] == 1).sum())
        market_count = int((phase_one_actual["order_type"] == 1).sum())
        limit_count = int((phase_one_actual["order_type"] == 0).sum())

        categories = ["Buy", "Sell", "Market\nOrder", "Limit\nOrder"]
        counts = [buy_count, sell_count, market_count, limit_count]
        colors = ["green", "red", "purple", "teal"]
        bars = axis_side.bar(categories, counts, color=colors, alpha=0.7)
        axis_side.set_title("Phase 1: Side & Order Type")
        axis_side.set_ylabel("Count")
        for bar, count in zip(bars, counts):
            axis_side.text(
                bar.get_x() + bar.get_width() / 2,
                bar.get_height() + 0.5,
                str(count),
                ha="center",
                va="bottom",
                fontsize=9,
            )

    phase_three_actual = actual_df[actual_df["phase"] == 3]
    phase_three_predicted = pd.DataFrame(predictions_by_phase.get(3, []))

    axis_emission_rate = figure.add_subplot(grid[1, 0])
    if not phase_three_actual.empty:
        emission_cycles = phase_three_actual["cycle"].astype(int).values
        evaluation_numbers = emission_cycles // 4
        running_rate = np.arange(1, len(evaluation_numbers) + 1) / (evaluation_numbers + 1)

        axis_emission_rate.plot(
            evaluation_numbers,
            running_rate,
            color="steelblue",
            linewidth=1,
            label="RTL running rate",
        )
        axis_emission_rate.axhline(0.5, color="red", linestyle="--", linewidth=1.5, label="Target 50%")
        axis_emission_rate.axhline(
            512 / 1024,
            color="orange",
            linestyle=":",
            linewidth=1.5,
            label=f"Exact threshold {512 / 1024:.3f}",
        )
        axis_emission_rate.set_title("Phase 3: Emission Rate Convergence")
        axis_emission_rate.set_xlabel("Slot evaluation number")
        axis_emission_rate.set_ylabel("Running emission rate")
        axis_emission_rate.set_ylim(0, 1)
        axis_emission_rate.legend(fontsize=8)

    axis_phase_three_price = figure.add_subplot(grid[1, 1])
    gbm_tick_phase_three = gbm_price_to_tick(gbm_price_q824=int(_PHASES[2]["gbm_price"]))
    if not phase_three_actual.empty:
        axis_phase_three_price.hist(
            phase_three_actual["price"].astype(int),
            bins=40,
            alpha=0.6,
            color="steelblue",
            label="RTL output",
            density=True,
        )
    if not phase_three_predicted.empty:
        axis_phase_three_price.hist(
            phase_three_predicted["price"].astype(int),
            bins=40,
            alpha=0.6,
            color="orange",
            label="Golden model",
            density=True,
        )
    axis_phase_three_price.axvline(
        gbm_tick_phase_three,
        color="red",
        linestyle="--",
        linewidth=1.5,
        label=f"GBM tick={gbm_tick_phase_three}",
    )
    axis_phase_three_price.set_title("Phase 3: Price Distribution")
    axis_phase_three_price.set_xlabel("Tick index (0-479)")
    axis_phase_three_price.set_ylabel("Density")
    axis_phase_three_price.legend(fontsize=8)
    axis_phase_three_price.set_xlim(0, 479)

    axis_split = figure.add_subplot(grid[1, 2])
    phase_labels: list[str] = []
    market_percentages: list[float] = []
    limit_percentages: list[float] = []

    for phase_id, phase_label in [(1, "Phase 1\n(always emit)"), (3, "Phase 3\n(50% emit)")]:
        phase_data = actual_df[actual_df["phase"] == phase_id]
        if phase_data.empty:
            continue
        market_percentage = float((phase_data["order_type"] == 1).mean()) * 100
        limit_percentage = float((phase_data["order_type"] == 0).mean()) * 100
        phase_labels.append(phase_label)
        market_percentages.append(market_percentage)
        limit_percentages.append(limit_percentage)

    if phase_labels:
        positions = np.arange(len(phase_labels))
        bar_width = 0.35
        axis_split.bar(
            positions - bar_width / 2,
            market_percentages,
            bar_width,
            label="Market orders",
            color="purple",
            alpha=0.7,
        )
        axis_split.bar(
            positions + bar_width / 2,
            limit_percentages,
            bar_width,
            label="Limit orders",
            color="teal",
            alpha=0.7,
        )
        axis_split.set_title(f"Market vs Limit Split\n(threshold={_NEAR_NOISE_THRESHOLD} ticks)")
        axis_split.set_ylabel("Percentage (%)")
        axis_split.set_xticks(positions)
        axis_split.set_xticklabels(phase_labels)
        axis_split.legend(fontsize=8)
        axis_split.set_ylim(0, 100)

    plt.savefig(_NOISE_PLOT_PATH, dpi=150, bbox_inches="tight")
    print(f"\nPlot saved to {_NOISE_PLOT_PATH}")
    plt.show()


def plot_value_results(
    actual_df: pd.DataFrame,
    predictions_by_phase: dict[int, list[dict[str, int]]],
) -> None:
    """Plots value investor diagnostics across phases 4, 5, and 6.

    Args:
        actual_df: The full testbench output DataFrame for all phases.
        predictions_by_phase: The golden model emissions keyed by phase identifier. Retained
            for interface symmetry with the noise plotter even though the value plot only
            consumes the actual testbench output.
    """
    del predictions_by_phase

    figure, (axis_volume, axis_divergence) = plt.subplots(1, 2, figsize=(14, 6))
    figure.suptitle(
        "Agent Execution Unit -- Value Investor Deterministic Verification",
        fontsize=14,
        fontweight="bold",
    )

    phases_to_plot = [4, 5, 6]
    phase_labels = ["Phase 4 (Buy)", "Phase 5 (Sell)", "Phase 6 (Silent)"]

    prices: list[int] = []
    volumes: list[int] = []
    sides: list[str] = []

    for phase_id in phases_to_plot:
        phase_data = actual_df[actual_df["phase"] == phase_id]
        if not phase_data.empty:
            prices.append(int(phase_data["price"].iloc[0]))
            volumes.append(int(phase_data["volume"].iloc[0]))
            sides.append("Buy" if phase_data["side"].iloc[0] == 0 else "Sell")
        else:
            prices.append(0)
            volumes.append(0)
            sides.append("Silent")

    positions = np.arange(len(phase_labels))
    bar_colors = ["green" if side == "Buy" else "red" if side == "Sell" else "gray" for side in sides]
    axis_volume.bar(positions, volumes, color=bar_colors, alpha=0.7)

    for index, (volume, price, side) in enumerate(zip(volumes, prices, sides)):
        if volume > 0:
            axis_volume.text(
                index,
                volume + 0.5,
                f"Limit {side}\n@ Tick {price}",
                ha="center",
                va="bottom",
                fontsize=10,
                fontweight="bold",
            )
        else:
            axis_volume.text(index, 0.5, "No Action", ha="center", va="bottom", fontsize=10, fontweight="bold")

    axis_volume.set_xticks(positions)
    axis_volume.set_xticklabels(phase_labels)
    axis_volume.set_ylabel("Generated Volume")
    axis_volume.set_title("Calculated Volume and Order Intent")
    axis_volume.set_ylim(0, max(max(volumes) + 3, 10))

    gbm_ticks = [
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[3]["gbm_price"])),
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[4]["gbm_price"])),
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[5]["gbm_price"])),
    ]
    executed_tick = gbm_price_to_tick(gbm_price_q824=int(_PHASES[3]["last_executed_price"]))

    axis_divergence.plot(
        positions,
        gbm_ticks,
        marker="o",
        linestyle="-",
        color="blue",
        label="GBM Fair Value Tick",
        markersize=8,
    )
    axis_divergence.axhline(
        executed_tick,
        color="purple",
        linestyle="--",
        label=f"Last Exec Tick ({executed_tick})",
    )
    axis_divergence.fill_between(
        positions,
        gbm_ticks,
        executed_tick,
        where=(np.array(gbm_ticks) > executed_tick),
        interpolate=True,
        color="green",
        alpha=0.2,
        label="Undervalued (Buy Zone)",
    )
    axis_divergence.fill_between(
        positions,
        gbm_ticks,
        executed_tick,
        where=(np.array(gbm_ticks) < executed_tick),
        interpolate=True,
        color="red",
        alpha=0.2,
        label="Overvalued (Sell Zone)",
    )

    axis_divergence.set_xticks(positions)
    axis_divergence.set_xticklabels(phase_labels)
    axis_divergence.set_ylabel("Tick Price")
    axis_divergence.set_title("Market Divergence State")
    axis_divergence.legend()

    plt.tight_layout()
    plt.savefig(_VALUE_PLOT_PATH, dpi=150, bbox_inches="tight")
    print(f"\nPlot saved to {_VALUE_PLOT_PATH}")
    plt.show()


def plot_momentum_results(
    actual_df: pd.DataFrame,
    predictions_by_phase: dict[int, list[dict[str, int]]],
) -> None:
    """Plots momentum trader diagnostics across phases 7, 8, and 9.

    Args:
        actual_df: The full testbench output DataFrame for all phases.
        predictions_by_phase: The golden model emissions keyed by phase identifier. Retained
            for interface symmetry with the noise plotter even though the momentum plot only
            consumes the actual testbench output.
    """
    del predictions_by_phase

    figure, (axis_volume, axis_trend) = plt.subplots(1, 2, figsize=(14, 6))
    figure.suptitle(
        "Agent Execution Unit -- Momentum Trader Verification",
        fontsize=14,
        fontweight="bold",
    )

    phases_to_plot = [7, 8, 9]
    phase_labels = ["Phase 7 (Buy)", "Phase 8 (Sell)", "Phase 9 (Silent)"]

    prices: list[int] = []
    volumes: list[int] = []
    sides: list[str] = []

    for phase_id in phases_to_plot:
        phase_data = actual_df[actual_df["phase"] == phase_id]
        if not phase_data.empty:
            prices.append(int(phase_data["price"].iloc[0]))
            volumes.append(int(phase_data["volume"].iloc[0]))
            sides.append("Buy" if phase_data["side"].iloc[0] == 0 else "Sell")
        else:
            prices.append(0)
            volumes.append(0)
            sides.append("Silent")

    positions = np.arange(len(phase_labels))
    bar_colors = ["green" if side == "Buy" else "red" if side == "Sell" else "gray" for side in sides]
    axis_volume.bar(positions, volumes, color=bar_colors, alpha=0.7)

    for index, (volume, price, side) in enumerate(zip(volumes, prices, sides)):
        if volume > 0:
            axis_volume.text(
                index,
                volume + 0.5,
                f"Market {side}\n@ Tick {price}",
                ha="center",
                va="bottom",
                fontsize=10,
                fontweight="bold",
            )
        else:
            axis_volume.text(index, 0.5, "No Action", ha="center", va="bottom", fontsize=10, fontweight="bold")

    axis_volume.set_xticks(positions)
    axis_volume.set_xticklabels(phase_labels)
    axis_volume.set_ylabel("Generated Volume")
    axis_volume.set_title("Calculated Volume and Order Intent")
    axis_volume.set_ylim(0, max(max(volumes) + 3, 10))

    newest_ticks = [
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[6]["last_executed_price"])),
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[7]["last_executed_price"])),
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[8]["last_executed_price"])),
    ]
    oldest_ticks = [
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[6]["oldest_executed_price"])),
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[7]["oldest_executed_price"])),
        gbm_price_to_tick(gbm_price_q824=int(_PHASES[8]["oldest_executed_price"])),
    ]

    axis_trend.plot(
        positions,
        newest_ticks,
        marker="o",
        linestyle="-",
        color="blue",
        label="Newest Trade (reg_0)",
        markersize=8,
    )
    axis_trend.plot(
        positions,
        oldest_ticks,
        marker="s",
        linestyle="--",
        color="purple",
        label="Oldest Trade (reg_3)",
        markersize=8,
    )
    axis_trend.fill_between(
        positions,
        newest_ticks,
        oldest_ticks,
        where=(np.array(newest_ticks) > oldest_ticks),
        interpolate=True,
        color="green",
        alpha=0.2,
        label="Uptrend",
    )
    axis_trend.fill_between(
        positions,
        newest_ticks,
        oldest_ticks,
        where=(np.array(newest_ticks) < oldest_ticks),
        interpolate=True,
        color="red",
        alpha=0.2,
        label="Downtrend",
    )

    axis_trend.set_xticks(positions)
    axis_trend.set_xticklabels(phase_labels)
    axis_trend.set_ylabel("Tick Price")
    axis_trend.set_title("Shift Register Trend State")
    axis_trend.legend()

    plt.tight_layout()
    plt.savefig(_MOMENTUM_PLOT_PATH, dpi=150, bbox_inches="tight")
    print(f"\nPlot saved to {_MOMENTUM_PLOT_PATH}")
    plt.show()


def main() -> None:
    """Runs the agent execution unit verification pipeline.

    Loads the testbench output CSV, replays the golden model across every configured phase,
    compares emissions for the phases targeted by _TARGET_TEST, prints a summary table, and
    dispatches to the strategy-specific plotting function.
    """
    if not _INPUT_CSV.exists():
        print(f"ERROR: {_INPUT_CSV} not found.")
        return

    actual_df = pd.read_csv(_INPUT_CSV)
    actual_df.columns = actual_df.columns.str.strip()

    lfsr_state = _LFSR_SEED
    predictions_by_phase: dict[int, list[dict[str, int]]] = {}
    summary_rows: list[dict[str, int | str]] = []

    if _TARGET_TEST == "NOISE":
        target_phase_ids = {1, 2, 3}
    elif _TARGET_TEST == "VALUE":
        target_phase_ids = {4, 5, 6}
    elif _TARGET_TEST == "MOMENTUM":
        target_phase_ids = {7, 8, 9}
    else:
        target_phase_ids = {int(phase["id"]) for phase in _PHASES}

    for phase in _PHASES:
        predictions, lfsr_state = run_golden_model(phase=phase, lfsr_init=lfsr_state)

        phase_id = int(phase["id"])
        if phase_id not in target_phase_ids:
            continue

        print(f"\nEvaluating Phase {phase_id}: {phase['name']}")
        predictions_by_phase[phase_id] = predictions
        matches, mismatches, missing = compare_phase(
            phase_id=phase_id,
            predictions=predictions,
            actual_df=actual_df,
        )

        summary_rows.append({
            "phase": phase_id,
            "name": str(phase["name"]),
            "predicted": len(predictions),
            "actual": int(len(actual_df[actual_df["phase"] == phase_id])),
            "matches": matches,
            "mismatches": mismatches,
            "missing": missing,
        })

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"{'Phase':<8} {'Name':<30} {'Pred':>6} {'Actual':>6} {'Match':>6} {'Fail':>6}")
    print("-" * 60)
    for row in summary_rows:
        status = "PASS" if row["mismatches"] == 0 and row["missing"] == 0 else "FAIL"
        print(
            f"{row['phase']:<8} {row['name']:<30} {row['predicted']:>6} "
            f"{row['actual']:>6} {row['matches']:>6} {row['mismatches']:>6}  {status}"
        )

    if _TARGET_TEST == "NOISE":
        plot_noise_results(actual_df=actual_df, predictions_by_phase=predictions_by_phase)
    elif _TARGET_TEST == "VALUE":
        plot_value_results(actual_df=actual_df, predictions_by_phase=predictions_by_phase)
    elif _TARGET_TEST == "MOMENTUM":
        plot_momentum_results(actual_df=actual_df, predictions_by_phase=predictions_by_phase)


if __name__ == "__main__":
    main()
