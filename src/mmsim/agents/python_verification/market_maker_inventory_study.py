"""Compares the fixed-spread (v1) and inventory-skewed (v2) market maker policies.

Drives the market maker golden model against the matching engine golden model together with a
noise counterparty that fires random market orders to simulate adverse order flow. Runs both
policies on the same random seed for an apples-to-apples comparison, records inventory,
mark-to-market PnL, observed spread, and fills-per-side per cycle, prints a summary table, and
saves four comparison plots.

The script proves the economic superiority of v2 (statistical, not bit-exact) and is intentionally
separate from the CSV-based DUT verification pipeline, which proves the Verilog DUT matches this
golden model exactly.
"""

from __future__ import annotations

import math
import random
import statistics
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

import click
import matplotlib.pyplot as plt

from ...matching_engine.python_verification.matching_engine_golden import (
    MatchingEngine,
    TradeRecord,
)
from ...utilities import console
from .market_maker_golden import (
    TYPE_MARKET_BUY,
    TYPE_MARKET_SELL,
    BookObservation,
    MarketMakerGolden,
    OrderCommand,
)


# Reserved order_id range for the noise counterparty, disjoint from the market maker's block.
_NOISE_ORDER_ID_BASE: int = 50_000

# Window length in cycles used for the rolling mean applied to the observed spread plot.
_SPREAD_ROLLING_WINDOW: int = 200


@dataclass
class NoiseEvent:
    """Captures a single per-cycle decision of the noise counterparty.

    Attributes:
        fire: Determines whether a noise order fires on this cycle.
        is_buy: Determines whether the fired order is a buy rather than a sell.
        size: The share count of the fired order.
    """

    fire: bool
    """Determines whether a noise order fires on this cycle."""
    is_buy: bool
    """Determines whether the fired order is a buy rather than a sell."""
    size: int
    """The share count of the fired order."""


@dataclass
class RunRecord:
    """Captures per-cycle metrics and end-of-run counters from a single simulation run.

    Attributes:
        label: The human-readable policy label for this run (e.g. "v1" or "v2").
        inventory: The per-cycle net inventory in shares.
        cumulative_pnl: The per-cycle mark-to-market profit and loss in tick-shares.
        spread: The per-cycle top-of-book spread in ticks (NaN when one side is empty).
        fills_bid: The total count of fills on the market maker's bid quotes.
        fills_ask: The total count of fills on the market maker's ask quotes.
        total_volume: The total shares traded against the market maker's quotes.
    """

    label: str
    """The human-readable policy label for this run (e.g. "v1" or "v2")."""
    inventory: list[int] = field(default_factory=list)
    """The per-cycle net inventory in shares."""
    cumulative_pnl: list[float] = field(default_factory=list)
    """The per-cycle mark-to-market profit and loss in tick-shares."""
    spread: list[float] = field(default_factory=list)
    """The per-cycle top-of-book spread in ticks (NaN when one side is empty)."""
    fills_bid: int = 0
    """The total count of fills on the market maker's bid quotes."""
    fills_ask: int = 0
    """The total count of fills on the market maker's ask quotes."""
    total_volume: int = 0
    """The total shares traded against the market maker's quotes."""


def precompute_noise_events(
    ticks: int,
    activity_rate: float,
    max_size: int,
    buy_bias: float,
    seed: int,
) -> list[NoiseEvent]:
    """Generates the full per-cycle noise event sequence for deterministic replay.

    Writing the sequence out to disk lets the ModelSim testbench replay the same flow the Python
    study observes, ensuring bit-exact DUT-vs-golden comparisons see identical stimulus.

    Args:
        ticks: The number of cycles to cover.
        activity_rate: The per-cycle probability of firing a market order.
        max_size: The maximum share count per fired order.
        buy_bias: The probability that a fired order is a buy rather than a sell.
        seed: The deterministic seed for the random number generator.

    Returns:
        A list of NoiseEvent with one entry per cycle.
    """
    rng = random.Random(seed)
    events: list[NoiseEvent] = []
    for _ in range(ticks):
        if rng.random() >= activity_rate:
            events.append(NoiseEvent(fire=False, is_buy=False, size=0))
            continue
        is_buy = rng.random() < buy_bias
        size = rng.randint(1, max_size)
        events.append(NoiseEvent(fire=True, is_buy=is_buy, size=size))
    return events


class NoiseCounterparty:
    """Fires random market orders against the book to simulate adverse order flow.

    Supports two modes: live generation from an internal RNG, or replay from a pre-computed
    event list. Replay mode is used when a ModelSim TB must see the identical sequence, since
    the TB reads the same event list from disk. In either mode, orders are skipped when the
    targeted side of the book is empty.

    Args:
        activity_rate: The per-cycle probability of attempting to fire a market order.
        max_size: The maximum share count per market order (drawn uniformly from one to this).
        buy_bias: The probability that a fired order is a buy rather than a sell.
        seed: The deterministic seed for the internal random number generator.
        order_id_base: The lowest order_id this counterparty will issue.
        events: When provided, replays this event list instead of drawing fresh RNG samples.

    Attributes:
        _activity_rate: Cached per-cycle firing probability.
        _max_size: Cached maximum order size.
        _buy_bias: Cached buy-side probability.
        _rng: The internal random number generator (used only in live mode).
        _next_order_id: The identifier to use for the next emitted market order.
        _events: The replay event list, or None when in live generation mode.
        _event_index: The position into the replay list for the next cycle.
    """

    def __init__(
        self,
        activity_rate: float,
        max_size: int,
        buy_bias: float,
        seed: int,
        order_id_base: int = _NOISE_ORDER_ID_BASE,
        events: list[NoiseEvent] | None = None,
    ) -> None:
        self._activity_rate: float = activity_rate
        self._max_size: int = max_size
        self._buy_bias: float = buy_bias
        self._rng: random.Random = random.Random(seed)
        self._next_order_id: int = order_id_base
        self._events: list[NoiseEvent] | None = events
        self._event_index: int = 0

    def maybe_fire(self, engine: MatchingEngine) -> OrderCommand | None:
        """Returns a market order to submit this cycle, or None when the counterparty stays quiet.

        Args:
            engine: The matching engine instance used to inspect the book for side liquidity.

        Returns:
            An OrderCommand describing the market order to submit, or None.
        """
        if self._events is not None:
            if self._event_index >= len(self._events):
                return None
            event = self._events[self._event_index]
            self._event_index += 1
            if not event.fire:
                return None
            is_buy = event.is_buy
            size = event.size
        else:
            if self._rng.random() >= self._activity_rate:
                return None
            is_buy = self._rng.random() < self._buy_bias
            size = self._rng.randint(1, self._max_size)

        if is_buy and not engine._ask_book.best_valid:
            return None
        if not is_buy and not engine._bid_book.best_valid:
            return None

        order_type = TYPE_MARKET_BUY if is_buy else TYPE_MARKET_SELL
        order = OrderCommand(
            order_type=order_type,
            order_id=self._next_order_id,
            order_price=0,
            order_quantity=size,
        )
        self._next_order_id += 1
        return order


def run_single(
    skew_enable: bool,
    ticks: int,
    seed: int,
    buy_bias: float,
    activity_rate: float,
    anchor_price: int = 1024,
    noise_max_size: int = 3,
    events: list[NoiseEvent] | None = None,
) -> RunRecord:
    """Runs one simulation of the market maker against the noise counterparty.

    Args:
        skew_enable: Determines whether the market maker uses v2 (inventory-skewed) quoting.
        ticks: The number of cycles to simulate.
        seed: The deterministic seed for the noise counterparty's random draws.
        buy_bias: The probability that a noise order is a buy rather than a sell.
        activity_rate: The per-cycle probability that the noise counterparty fires an order.
        anchor_price: The cold-start fair price passed to the market maker.
        noise_max_size: The maximum share count per noise market order.
        events: When provided, the noise counterparty replays this event list instead of
            drawing fresh RNG samples. Used to synchronize Python and ModelSim runs.

    Returns:
        A RunRecord capturing per-cycle metrics and end-of-run counters for this run.
    """
    # Bumps max_orders above the MatchingEngine default so stale partial-fill remnants from the
    # market maker's bid replenishments cannot exhaust a book side during long runs.
    engine = MatchingEngine(depth=16, max_orders=256)
    market_maker = MarketMakerGolden(skew_enable=skew_enable, anchor_price=anchor_price)
    noise = NoiseCounterparty(
        activity_rate=activity_rate,
        max_size=noise_max_size,
        buy_bias=buy_bias,
        seed=seed,
        events=events,
    )

    record = RunRecord(label="v2" if skew_enable else "v1")
    cash: float = 0.0
    pending_trades: deque[TradeRecord] = deque()
    last_known_price: int = anchor_price

    for _cycle in range(ticks):
        trade = pending_trades.popleft() if pending_trades else None
        observation = _build_observation(engine=engine, trade=trade)

        previous_inventory = market_maker.net_inventory
        order = market_maker.tick(observation=observation)
        inventory_delta = market_maker.net_inventory - previous_inventory

        if inventory_delta != 0 and trade is not None:
            cash -= inventory_delta * trade.price
            if inventory_delta > 0:
                record.fills_bid += 1
            else:
                record.fills_ask += 1
            record.total_volume += abs(inventory_delta)
            last_known_price = trade.price

        if order is not None:
            new_trades = engine.process_order(
                order_type=order.order_type,
                order_id=order.order_id,
                order_price=order.order_price,
                order_quantity=order.order_quantity,
            )
            pending_trades.extend(new_trades)
            if new_trades:
                last_known_price = new_trades[-1].price

        noise_order = noise.maybe_fire(engine=engine)
        if noise_order is not None:
            new_trades = engine.process_order(
                order_type=noise_order.order_type,
                order_id=noise_order.order_id,
                order_price=noise_order.order_price,
                order_quantity=noise_order.order_quantity,
            )
            pending_trades.extend(new_trades)
            if new_trades:
                last_known_price = new_trades[-1].price

        if engine._bid_book.best_valid and engine._ask_book.best_valid:
            mid = (engine._bid_book.best_price + engine._ask_book.best_price) // 2
            spread = float(engine._ask_book.best_price - engine._bid_book.best_price)
        else:
            mid = last_known_price
            spread = math.nan

        record.inventory.append(market_maker.net_inventory)
        record.cumulative_pnl.append(cash + market_maker.net_inventory * mid)
        record.spread.append(spread)

    return record


def summarize(record: RunRecord) -> dict[str, float]:
    """Reduces a run record to scalar metrics for the summary table.

    Args:
        record: The per-cycle metrics to summarize.

    Returns:
        A dictionary of scalar metrics keyed by metric name.
    """
    std_inventory = statistics.pstdev(record.inventory) if len(record.inventory) > 1 else 0.0

    peak_pnl = -math.inf
    max_drawdown = 0.0
    for value in record.cumulative_pnl:
        if value > peak_pnl:
            peak_pnl = value
        drawdown = peak_pnl - value
        if drawdown > max_drawdown:
            max_drawdown = drawdown

    valid_spreads = [value for value in record.spread if not math.isnan(value)]
    mean_spread = statistics.mean(valid_spreads) if valid_spreads else math.nan

    final_pnl = record.cumulative_pnl[-1] if record.cumulative_pnl else 0.0

    return {
        "std_inventory": std_inventory,
        "max_drawdown": max_drawdown,
        "final_pnl": final_pnl,
        "total_volume": float(record.total_volume),
        "fills_bid": float(record.fills_bid),
        "fills_ask": float(record.fills_ask),
        "mean_spread": mean_spread,
    }


def print_single_seed_table(record_v1: RunRecord, record_v2: RunRecord) -> None:
    """Prints a head-to-head scalar summary for a single-seed run."""
    summary_v1 = summarize(record=record_v1)
    summary_v2 = summarize(record=record_v2)

    console.log(message="Single-seed comparison (lower is better for std(inv) and max DD):")
    header = (
        f"  {'metric':<20} {'v1 (fixed)':>14} {'v2 (skewed)':>14} {'delta (v2-v1)':>16}"
    )
    print(header)  # noqa: T201
    print("  " + "-" * (len(header) - 2))  # noqa: T201

    rows: list[tuple[str, str]] = [
        ("std_inventory", "std(inventory)"),
        ("max_drawdown", "max drawdown"),
        ("final_pnl", "final PnL"),
        ("total_volume", "total volume"),
        ("fills_bid", "fills (bid)"),
        ("fills_ask", "fills (ask)"),
        ("mean_spread", "mean spread"),
    ]
    for key, label in rows:
        v1_value = summary_v1[key]
        v2_value = summary_v2[key]
        delta = v2_value - v1_value
        print(  # noqa: T201
            f"  {label:<20} {v1_value:>14.2f} {v2_value:>14.2f} {delta:>+16.2f}"
        )


def print_sweep_table(metrics_v1: list[dict[str, float]], metrics_v2: list[dict[str, float]]) -> None:
    """Prints a multi-seed summary table with per-metric mean and standard deviation."""
    seed_count = len(metrics_v1)
    console.log(message=f"Seed sweep comparison across {seed_count} seeds (mean ± stdev):")
    header = f"  {'metric':<20} {'v1 (fixed)':>24} {'v2 (skewed)':>24}"
    print(header)  # noqa: T201
    print("  " + "-" * (len(header) - 2))  # noqa: T201

    rows: list[tuple[str, str]] = [
        ("std_inventory", "std(inventory)"),
        ("max_drawdown", "max drawdown"),
        ("final_pnl", "final PnL"),
        ("total_volume", "total volume"),
        ("mean_spread", "mean spread"),
    ]
    for key, label in rows:
        values_v1 = [metrics[key] for metrics in metrics_v1]
        values_v2 = [metrics[key] for metrics in metrics_v2]
        mean_v1 = statistics.mean(values_v1)
        stdev_v1 = statistics.pstdev(values_v1) if len(values_v1) > 1 else 0.0
        mean_v2 = statistics.mean(values_v2)
        stdev_v2 = statistics.pstdev(values_v2) if len(values_v2) > 1 else 0.0
        print(  # noqa: T201
            f"  {label:<20} {mean_v1:>12.2f} ± {stdev_v1:>8.2f} "
            f"{mean_v2:>12.2f} ± {stdev_v2:>8.2f}"
        )


def plot_comparison(record_v1: RunRecord, record_v2: RunRecord, output_directory: Path) -> None:
    """Saves four comparison plots to the output directory.

    Args:
        record_v1: The per-cycle metrics from the v1 (fixed-spread) run.
        record_v2: The per-cycle metrics from the v2 (inventory-skewed) run.
        output_directory: The directory to save the PNG plots in.
    """
    output_directory.mkdir(parents=True, exist_ok=True)
    cycles = range(len(record_v1.inventory))

    figure, axis = plt.subplots(figsize=(10, 5))
    axis.plot(cycles, record_v1.inventory, label="v1 (fixed)", alpha=0.8)
    axis.plot(cycles, record_v2.inventory, label="v2 (skewed)", alpha=0.8)
    axis.axhline(y=0, color="black", linestyle=":", linewidth=0.5)
    axis.set_xlabel(xlabel="Cycle")
    axis.set_ylabel(ylabel="Net inventory (shares)")
    axis.set_title(label="Market maker inventory over time")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "inventory.png", dpi=120)
    plt.close(fig=figure)

    figure, axis = plt.subplots(figsize=(10, 5))
    axis.plot(cycles, record_v1.cumulative_pnl, label="v1 (fixed)", alpha=0.8)
    axis.plot(cycles, record_v2.cumulative_pnl, label="v2 (skewed)", alpha=0.8)
    axis.set_xlabel(xlabel="Cycle")
    axis.set_ylabel(ylabel="Mark-to-market PnL (tick · shares)")
    axis.set_title(label="Cumulative PnL over time")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "pnl.png", dpi=120)
    plt.close(fig=figure)

    figure, axis = plt.subplots(figsize=(10, 5))
    axis.plot(
        cycles, _rolling_mean(values=record_v1.spread, window=_SPREAD_ROLLING_WINDOW),
        label="v1 (fixed)", alpha=0.8,
    )
    axis.plot(
        cycles, _rolling_mean(values=record_v2.spread, window=_SPREAD_ROLLING_WINDOW),
        label="v2 (skewed)", alpha=0.8,
    )
    axis.set_xlabel(xlabel="Cycle")
    axis.set_ylabel(ylabel=f"Observed spread (ticks, {_SPREAD_ROLLING_WINDOW}-cycle rolling mean)")
    axis.set_title(label="Top-of-book spread over time")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "spread.png", dpi=120)
    plt.close(fig=figure)

    figure, axis = plt.subplots(figsize=(6, 5))
    labels = ["v1 (fixed)", "v2 (skewed)"]
    bid_counts = [record_v1.fills_bid, record_v2.fills_bid]
    ask_counts = [record_v1.fills_ask, record_v2.fills_ask]
    positions = range(len(labels))
    bar_width = 0.35
    axis.bar(
        x=[position - bar_width / 2 for position in positions],
        height=bid_counts,
        width=bar_width,
        label="Bid fills (MM bought)",
    )
    axis.bar(
        x=[position + bar_width / 2 for position in positions],
        height=ask_counts,
        width=bar_width,
        label="Ask fills (MM sold)",
    )
    axis.set_xticks(ticks=list(positions))
    axis.set_xticklabels(labels=labels)
    axis.set_ylabel(ylabel="Fill count")
    axis.set_title(label="Fills by side")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "fills_by_side.png", dpi=120)
    plt.close(fig=figure)


def plot_comparison_overlay(
    python_v1: RunRecord,
    python_v2: RunRecord,
    verilog_v1: RunRecord,
    verilog_v2: RunRecord,
    output_directory: Path,
) -> None:
    """Saves four comparison plots with Python and Verilog overlaid per policy.

    Each plot draws four lines using a color-per-policy and style-per-source convention so that
    Python-vs-Verilog agreement shows up as coincident lines of the same color while the v1-vs-v2
    comparison shows up as distinct colors. Any visible gap between a solid and dashed line of
    the same color is a bit-exact divergence worth investigating.

    Args:
        python_v1: The RunRecord from the Python golden model with the v1 (fixed) policy.
        python_v2: The RunRecord from the Python golden model with the v2 (skewed) policy.
        verilog_v1: The RunRecord parsed from the ModelSim log with the v1 policy.
        verilog_v2: The RunRecord parsed from the ModelSim log with the v2 policy.
        output_directory: The directory to save the PNG plots in.
    """
    output_directory.mkdir(parents=True, exist_ok=True)
    cycles = range(len(python_v1.inventory))

    v1_color = "tab:blue"
    v2_color = "tab:orange"
    python_style = "-"
    verilog_style = "--"

    figure, axis = plt.subplots(figsize=(10, 5))
    axis.plot(cycles, python_v1.inventory, color=v1_color, linestyle=python_style,
              label="Python v1 (fixed)", alpha=0.8)
    axis.plot(cycles, verilog_v1.inventory, color=v1_color, linestyle=verilog_style,
              label="Verilog v1 (fixed)", alpha=0.8)
    axis.plot(cycles, python_v2.inventory, color=v2_color, linestyle=python_style,
              label="Python v2 (skewed)", alpha=0.8)
    axis.plot(cycles, verilog_v2.inventory, color=v2_color, linestyle=verilog_style,
              label="Verilog v2 (skewed)", alpha=0.8)
    axis.axhline(y=0, color="black", linestyle=":", linewidth=0.5)
    axis.set_xlabel(xlabel="Cycle")
    axis.set_ylabel(ylabel="Net inventory (shares)")
    axis.set_title(label="Market maker inventory over time (Python vs Verilog)")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "inventory.png", dpi=120)
    plt.close(fig=figure)

    figure, axis = plt.subplots(figsize=(10, 5))
    axis.plot(cycles, python_v1.cumulative_pnl, color=v1_color, linestyle=python_style,
              label="Python v1 (fixed)", alpha=0.8)
    axis.plot(cycles, verilog_v1.cumulative_pnl, color=v1_color, linestyle=verilog_style,
              label="Verilog v1 (fixed)", alpha=0.8)
    axis.plot(cycles, python_v2.cumulative_pnl, color=v2_color, linestyle=python_style,
              label="Python v2 (skewed)", alpha=0.8)
    axis.plot(cycles, verilog_v2.cumulative_pnl, color=v2_color, linestyle=verilog_style,
              label="Verilog v2 (skewed)", alpha=0.8)
    axis.set_xlabel(xlabel="Cycle")
    axis.set_ylabel(ylabel="Mark-to-market PnL (tick · shares)")
    axis.set_title(label="Cumulative PnL over time (Python vs Verilog)")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "pnl.png", dpi=120)
    plt.close(fig=figure)

    figure, axis = plt.subplots(figsize=(10, 5))
    for record, color, style, label in (
        (python_v1, v1_color, python_style, "Python v1 (fixed)"),
        (verilog_v1, v1_color, verilog_style, "Verilog v1 (fixed)"),
        (python_v2, v2_color, python_style, "Python v2 (skewed)"),
        (verilog_v2, v2_color, verilog_style, "Verilog v2 (skewed)"),
    ):
        axis.plot(
            cycles,
            _rolling_mean(values=record.spread, window=_SPREAD_ROLLING_WINDOW),
            color=color, linestyle=style, label=label, alpha=0.8,
        )
    axis.set_xlabel(xlabel="Cycle")
    axis.set_ylabel(ylabel=f"Observed spread (ticks, {_SPREAD_ROLLING_WINDOW}-cycle rolling mean)")
    axis.set_title(label="Top-of-book spread over time (Python vs Verilog)")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "spread.png", dpi=120)
    plt.close(fig=figure)

    figure, axis = plt.subplots(figsize=(8, 5))
    labels = ["Python v1", "Verilog v1", "Python v2", "Verilog v2"]
    bid_counts = [
        python_v1.fills_bid, verilog_v1.fills_bid,
        python_v2.fills_bid, verilog_v2.fills_bid,
    ]
    ask_counts = [
        python_v1.fills_ask, verilog_v1.fills_ask,
        python_v2.fills_ask, verilog_v2.fills_ask,
    ]
    positions = range(len(labels))
    bar_width = 0.35
    axis.bar(
        x=[position - bar_width / 2 for position in positions],
        height=bid_counts, width=bar_width, label="Bid fills (MM bought)",
    )
    axis.bar(
        x=[position + bar_width / 2 for position in positions],
        height=ask_counts, width=bar_width, label="Ask fills (MM sold)",
    )
    axis.set_xticks(ticks=list(positions))
    axis.set_xticklabels(labels=labels)
    axis.set_ylabel(ylabel="Fill count")
    axis.set_title(label="Fills by side (Python vs Verilog)")
    axis.legend()
    figure.tight_layout()
    figure.savefig(fname=output_directory / "fills_by_side.png", dpi=120)
    plt.close(fig=figure)


_DEFAULT_SEED: int = 42


@click.command()
@click.option("--ticks", type=int, default=10_000, show_default=True,
              help="Number of simulation cycles.")
@click.option("--seeds", type=int, default=1, show_default=True,
              help="Number of seeds to sweep (1 = single-seed with plots).")
@click.option("--buy-bias", type=float, default=0.5, show_default=True,
              help="Noise counterparty buy probability (0.5 = symmetric).")
@click.option("--activity-rate", type=float, default=0.15, show_default=True,
              help="Per-cycle probability that the noise counterparty fires an order.")
@click.option("--no-plots", is_flag=True, default=False, help="Skip plot generation.")
@click.option("-o", "--output-dir", type=click.Path(path_type=Path), default=None,
              help="Directory to save plots in (defaults to agents/sim/study_artifacts).")
def main(
    ticks: int,
    seeds: int,
    buy_bias: float,
    activity_rate: float,
    no_plots: bool,
    output_dir: Path | None,
) -> None:
    """Compare fixed-spread (v1) vs inventory-skewed (v2) market maker policies.

    Runs the Python golden model against a random noise counterparty for each policy and
    reports aggregate metrics. With a single seed, also generates four diagnostic plots.
    With multiple seeds, reports mean and standard deviation across the sweep instead.
    """
    default_output = Path(__file__).resolve().parent.parent / "sim" / "study_artifacts"
    output_directory: Path = output_dir if output_dir is not None else default_output

    if seeds <= 1:
        record_v1 = run_single(
            skew_enable=False,
            ticks=ticks,
            seed=_DEFAULT_SEED,
            buy_bias=buy_bias,
            activity_rate=activity_rate,
        )
        record_v2 = run_single(
            skew_enable=True,
            ticks=ticks,
            seed=_DEFAULT_SEED,
            buy_bias=buy_bias,
            activity_rate=activity_rate,
        )
        print_single_seed_table(record_v1=record_v1, record_v2=record_v2)
        if not no_plots:
            plot_comparison(
                record_v1=record_v1, record_v2=record_v2, output_directory=output_directory,
            )
            console.success(message=f"Plots written to {output_directory}")
        return

    metrics_v1: list[dict[str, float]] = []
    metrics_v2: list[dict[str, float]] = []
    for offset in range(seeds):
        current_seed = _DEFAULT_SEED + offset
        record_v1 = run_single(
            skew_enable=False,
            ticks=ticks,
            seed=current_seed,
            buy_bias=buy_bias,
            activity_rate=activity_rate,
        )
        record_v2 = run_single(
            skew_enable=True,
            ticks=ticks,
            seed=current_seed,
            buy_bias=buy_bias,
            activity_rate=activity_rate,
        )
        metrics_v1.append(summarize(record=record_v1))
        metrics_v2.append(summarize(record=record_v2))
    print_sweep_table(metrics_v1=metrics_v1, metrics_v2=metrics_v2)


def _build_observation(engine: MatchingEngine, trade: TradeRecord | None) -> BookObservation:
    """Returns a BookObservation combining current engine state with an optional snoop event."""
    observation = BookObservation(
        best_bid_price=engine._bid_book.best_price,
        best_bid_quantity=engine._bid_book.best_quantity,
        best_bid_valid=engine._bid_book.best_valid,
        best_ask_price=engine._ask_book.best_price,
        best_ask_quantity=engine._ask_book.best_quantity,
        best_ask_valid=engine._ask_book.best_valid,
    )
    if trade is not None:
        observation.trade_valid = True
        observation.trade_aggressor_id = trade.aggressor_id
        observation.trade_resting_id = trade.resting_id
        observation.trade_price = trade.price
        observation.trade_quantity = trade.quantity
    return observation


def _rolling_mean(values: list[float], window: int) -> list[float]:
    """Returns a centered-ish rolling mean that ignores NaN entries for the spread plot."""
    output: list[float] = []
    buffer: deque[float] = deque()
    for value in values:
        if not math.isnan(value):
            buffer.append(value)
            if len(buffer) > window:
                buffer.popleft()
        if buffer:
            output.append(statistics.mean(buffer))
        else:
            output.append(math.nan)
    return output


if __name__ == "__main__":
    main()
