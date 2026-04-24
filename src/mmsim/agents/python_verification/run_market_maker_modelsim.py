"""Drives the closed-loop ModelSim market maker pipeline and produces Python-vs-Verilog plots.

Runs three stages in sequence. First, generates a deterministic noise event stream and the
Python reference run for both v1 and v2. Second, invokes ModelSim twice (once per policy) to
simulate the Verilog DUTs against the replayed noise. Third, parses the ModelSim logs into
RunRecords, reports sequence-level agreement between Python and Verilog orders, and draws
four-line overlay plots covering inventory, PnL, spread, and fills.

Strict cycle-by-cycle bit-exactness is not achievable because the Python MatchingEngine golden
model returns trades synchronously while the Verilog engine processes orders across multiple
clock cycles. The orchestrator therefore reports Python-vs-Verilog agreement on aggregate
summary statistics and emitted order counts instead, which still validates the DUT under
identical noise stimulus while setting honest expectations about what the plots show.
"""

from __future__ import annotations

import csv
import math
import subprocess
from collections import deque
from pathlib import Path

import click

from ...matching_engine.python_verification.matching_engine_golden import (
    MatchingEngine,
    TradeRecord,
)
from ...utilities import console
from .market_maker_golden import (
    BookObservation,
    MarketMakerGolden,
    OrderCommand,
)
from .market_maker_inventory_study import (
    NoiseCounterparty,
    NoiseEvent,
    RunRecord,
    _build_observation,
    plot_comparison_overlay,
    precompute_noise_events,
    summarize,
)


# File names written inside the sim working directory. The ModelSim testbench reads and writes
# these names unqualified, so Python and Verilog stages must use the same directory.
_NOISE_CSV: str = "noise_events.csv"
_PYTHON_ORDERS_CSV_FMT: str = "expected_orders_{policy}.csv"
_PYTHON_METRICS_CSV_FMT: str = "python_run_{policy}.csv"
_VERILOG_LOG_CSV_FMT: str = "run_log_{policy}.csv"
_VERILOG_ORDERS_CSV_FMT: str = "actual_orders_{policy}.csv"


def write_noise_events(events: list[NoiseEvent], path: Path) -> None:
    """Writes the noise event stream to a CSV consumable by the ModelSim testbench.

    Args:
        events: The pre-computed per-cycle noise events to serialize.
        path: The absolute file path to write.
    """
    with path.open(mode="w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["fire", "is_buy", "size"])
        for event in events:
            writer.writerow([
                1 if event.fire else 0,
                1 if event.is_buy else 0,
                event.size,
            ])


def run_python_reference(
    skew_enable: bool,
    ticks: int,
    events: list[NoiseEvent],
    anchor_price: int,
    noise_max_size: int,
    orders_path: Path,
    metrics_path: Path,
) -> RunRecord:
    """Runs the Python golden pipeline against a replayed noise stream and persists results.

    Mirrors the simulation loop used by the inventory study but captures every market maker
    order into orders_path for later comparison against the Verilog testbench output.

    Args:
        skew_enable: Determines whether the market maker uses v2 (inventory-skewed) quoting.
        ticks: The number of cycles to simulate.
        events: The deterministic noise event stream shared with the ModelSim run.
        anchor_price: The cold-start fair price passed to the market maker.
        noise_max_size: The maximum share count per noise market order.
        orders_path: The CSV path to write MM-emitted orders to.
        metrics_path: The CSV path to write per-cycle metric series to.

    Returns:
        The in-memory RunRecord produced during the run for direct reuse by the plot stage.
    """
    engine = MatchingEngine(depth=16, max_orders=256)
    market_maker = MarketMakerGolden(skew_enable=skew_enable, anchor_price=anchor_price)
    noise = NoiseCounterparty(
        activity_rate=0.0,
        max_size=noise_max_size,
        buy_bias=0.5,
        seed=0,
        events=events,
    )

    record = RunRecord(label="v2" if skew_enable else "v1")
    cash: float = 0.0
    pending_trades: deque[TradeRecord] = deque()
    last_known_price: int = anchor_price

    with orders_path.open(mode="w", newline="") as orders_handle:
        orders_writer = csv.writer(orders_handle)
        orders_writer.writerow(
            ["cycle", "order_type", "order_id", "order_price", "order_quantity"],
        )

        for cycle in range(ticks):
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
                orders_writer.writerow([
                    cycle,
                    order.order_type,
                    order.order_id,
                    order.order_price,
                    order.order_quantity,
                ])
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

    write_metrics_csv(record=record, path=metrics_path)
    return record


def write_metrics_csv(record: RunRecord, path: Path) -> None:
    """Serializes a RunRecord's per-cycle series to CSV for post-hoc inspection."""
    with path.open(mode="w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["cycle", "inventory", "cumulative_pnl", "spread"])
        for cycle, (inventory, pnl, spread) in enumerate(
            zip(record.inventory, record.cumulative_pnl, record.spread, strict=True),
        ):
            writer.writerow([cycle, inventory, pnl, spread])


def invoke_modelsim(sim_directory: Path, skew_enable: bool) -> None:
    """Invokes ModelSim headless with the requested kSkewEnable override.

    Args:
        sim_directory: The sim/ directory that the testbench reads inputs from and writes to.
        skew_enable: The policy selection passed through to the Verilog parameter.

    Raises:
        RuntimeError: When the vsim invocation exits with a nonzero status.
    """
    skew_flag = "1" if skew_enable else "0"
    command = [
        "vsim", "-c",
        f"-gkSkewEnable={skew_flag}",
        "-do", "do run_market_maker.tcl; quit -f",
    ]
    console.log(message=f"Invoking ModelSim with kSkewEnable={skew_flag}")
    result = subprocess.run(
        args=command,
        cwd=sim_directory,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip():
        print(result.stdout.rstrip())  # noqa: T201
    if result.returncode != 0:
        if result.stderr.strip():
            print(result.stderr.rstrip())  # noqa: T201
        message = (
            f"vsim exited with status {result.returncode}. Verify ModelSim is installed "
            f"and vsim is available on PATH, or pass --skip-modelsim to re-plot from the "
            f"existing run_log_*.csv files."
        )
        raise RuntimeError(message)


def parse_verilog_log(path: Path, label: str) -> RunRecord:
    """Builds a RunRecord from the per-cycle CSV written by the ModelSim testbench.

    Args:
        path: The run_log_vX.csv path produced by tb_market_maker.v.
        label: The policy label (e.g. "v1" or "v2") to tag the returned record with.

    Returns:
        A RunRecord populated from the Verilog simulation output.
    """
    record = RunRecord(label=label)
    cash: float = 0.0
    last_known_price: int | None = None

    with path.open(mode="r", newline="") as handle:
        reader = csv.DictReader(handle)
        previous_inventory = 0
        for row in reader:
            inventory = int(row["mm_net_inventory"])
            trade_valid = int(row["trade_valid"]) != 0
            trade_price = int(row["trade_price"])
            best_bid_price = int(row["best_bid_price"])
            best_ask_price = int(row["best_ask_price"])
            best_bid_valid = int(row["best_bid_valid"]) != 0
            best_ask_valid = int(row["best_ask_valid"]) != 0

            inventory_delta = inventory - previous_inventory
            if inventory_delta != 0 and trade_valid:
                cash -= inventory_delta * trade_price
                if inventory_delta > 0:
                    record.fills_bid += 1
                else:
                    record.fills_ask += 1
                record.total_volume += abs(inventory_delta)
                last_known_price = trade_price

            if trade_valid:
                last_known_price = trade_price

            if best_bid_valid and best_ask_valid:
                mid = (best_bid_price + best_ask_price) // 2
                spread = float(best_ask_price - best_bid_price)
            else:
                mid = last_known_price if last_known_price is not None else 0
                spread = math.nan

            record.inventory.append(inventory)
            record.cumulative_pnl.append(cash + inventory * mid)
            record.spread.append(spread)
            previous_inventory = inventory

    return record


def count_orders(path: Path) -> int:
    """Returns the number of data rows in an orders CSV, excluding the header."""
    with path.open(mode="r", newline="") as handle:
        reader = csv.reader(handle)
        next(reader, None)
        return sum(1 for _ in reader)


def print_comparison_table(
    python_v1: RunRecord,
    python_v2: RunRecord,
    verilog_v1: RunRecord,
    verilog_v2: RunRecord,
    python_orders_counts: tuple[int, int],
    verilog_orders_counts: tuple[int, int],
) -> None:
    """Prints an eight-way Python-vs-Verilog summary table grouped by policy."""
    summary_python_v1 = summarize(record=python_v1)
    summary_python_v2 = summarize(record=python_v2)
    summary_verilog_v1 = summarize(record=verilog_v1)
    summary_verilog_v2 = summarize(record=verilog_v2)

    console.log(message="Python vs Verilog aggregate comparison:")
    header = (
        f"  {'metric':<20} {'Py v1':>12} {'Ver v1':>12} "
        f"{'Py v2':>12} {'Ver v2':>12}"
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
        print(  # noqa: T201
            f"  {label:<20} "
            f"{summary_python_v1[key]:>12.2f} {summary_verilog_v1[key]:>12.2f} "
            f"{summary_python_v2[key]:>12.2f} {summary_verilog_v2[key]:>12.2f}"
        )

    python_v1_count, python_v2_count = python_orders_counts
    verilog_v1_count, verilog_v2_count = verilog_orders_counts
    print(  # noqa: T201
        f"  {'orders emitted':<20} "
        f"{python_v1_count:>12d} {verilog_v1_count:>12d} "
        f"{python_v2_count:>12d} {verilog_v2_count:>12d}"
    )


_DEFAULT_SEED: int = 42


@click.command()
@click.option("--ticks", type=int, default=10_000, show_default=True,
              help="Total simulation cycles.")
@click.option("--buy-bias", type=float, default=0.5, show_default=True,
              help="Noise counterparty buy probability (0.5 = symmetric).")
@click.option("--activity-rate", type=float, default=0.15, show_default=True,
              help="Per-cycle probability that the noise counterparty fires an order.")
@click.option("--anchor-price", type=int, default=1024, show_default=True,
              help="Cold-start fair price passed to the market maker.")
@click.option("--noise-max-size", type=int, default=3, show_default=True,
              help="Maximum share count per noise market order.")
@click.option("--skip-modelsim", is_flag=True, default=False,
              help="Skip invoking vsim; reuse existing run_log_*.csv files.")
@click.option("--skip-python", is_flag=True, default=False,
              help="Skip the Python reference runs; reuse existing python_run_*.csv files.")
@click.option("-o", "--output-dir", type=click.Path(path_type=Path), default=None,
              help="Directory to save overlay plots in "
                   "(defaults to agents/sim/modelsim_study_artifacts).")
def main(
    ticks: int,
    buy_bias: float,
    activity_rate: float,
    anchor_price: int,
    noise_max_size: int,
    skip_modelsim: bool,
    skip_python: bool,
    output_dir: Path | None,
) -> None:
    """Drive the closed-loop ModelSim market_maker pipeline and produce overlay plots.

    Runs three stages: generates a deterministic noise stream and the Python reference
    runs for v1 and v2, invokes ModelSim twice to simulate the Verilog DUT against the
    same noise, then parses the logs and draws four-line Python-vs-Verilog overlay plots.
    """
    agents_directory = Path(__file__).resolve().parent.parent
    sim_directory = agents_directory / "sim"
    sim_directory.mkdir(parents=True, exist_ok=True)
    plots_directory: Path = (
        output_dir if output_dir is not None
        else sim_directory / "modelsim_study_artifacts"
    )

    noise_path = sim_directory / _NOISE_CSV
    python_orders_v1_path = sim_directory / _PYTHON_ORDERS_CSV_FMT.format(policy="v1")
    python_orders_v2_path = sim_directory / _PYTHON_ORDERS_CSV_FMT.format(policy="v2")
    python_metrics_v1_path = sim_directory / _PYTHON_METRICS_CSV_FMT.format(policy="v1")
    python_metrics_v2_path = sim_directory / _PYTHON_METRICS_CSV_FMT.format(policy="v2")
    verilog_log_v1_path = sim_directory / _VERILOG_LOG_CSV_FMT.format(policy="v1")
    verilog_log_v2_path = sim_directory / _VERILOG_LOG_CSV_FMT.format(policy="v2")
    verilog_orders_v1_path = sim_directory / _VERILOG_ORDERS_CSV_FMT.format(policy="v1")
    verilog_orders_v2_path = sim_directory / _VERILOG_ORDERS_CSV_FMT.format(policy="v2")
    default_log_path = sim_directory / "run_log.csv"
    default_orders_path = sim_directory / "actual_orders.csv"

    console.log(message="Stage 1: generating noise event stream + Python reference runs.")
    events = precompute_noise_events(
        ticks=ticks,
        activity_rate=activity_rate,
        max_size=noise_max_size,
        buy_bias=buy_bias,
        seed=_DEFAULT_SEED,
    )
    write_noise_events(events=events, path=noise_path)
    console.success(message=f"  Wrote {noise_path} ({len(events)} events).")

    if skip_python:
        console.warning(
            message="Skipping Python reference runs per --skip-python; existing CSVs will be reused.",
        )
        python_v1_record = parse_verilog_log(path=python_metrics_v1_path, label="v1")
        python_v2_record = parse_verilog_log(path=python_metrics_v2_path, label="v2")
    else:
        python_v1_record = run_python_reference(
            skew_enable=False,
            ticks=ticks,
            events=events,
            anchor_price=anchor_price,
            noise_max_size=noise_max_size,
            orders_path=python_orders_v1_path,
            metrics_path=python_metrics_v1_path,
        )
        python_v2_record = run_python_reference(
            skew_enable=True,
            ticks=ticks,
            events=events,
            anchor_price=anchor_price,
            noise_max_size=noise_max_size,
            orders_path=python_orders_v2_path,
            metrics_path=python_metrics_v2_path,
        )
        console.success(
            message=f"  Python v1 emitted {count_orders(path=python_orders_v1_path)} orders; "
                    f"v2 emitted {count_orders(path=python_orders_v2_path)} orders.",
        )

    if skip_modelsim:
        console.warning(
            message="Skipping ModelSim per --skip-modelsim; existing run_log_*.csv will be reused.",
        )
    else:
        console.log(message="Stage 2: running ModelSim for v1 and v2.")
        invoke_modelsim(sim_directory=sim_directory, skew_enable=False)
        if default_log_path.exists():
            default_log_path.replace(verilog_log_v1_path)
        if default_orders_path.exists():
            default_orders_path.replace(verilog_orders_v1_path)

        invoke_modelsim(sim_directory=sim_directory, skew_enable=True)
        if default_log_path.exists():
            default_log_path.replace(verilog_log_v2_path)
        if default_orders_path.exists():
            default_orders_path.replace(verilog_orders_v2_path)

    console.log(message="Stage 3: parsing Verilog logs and drawing overlay plots.")
    if not verilog_log_v1_path.exists() or not verilog_log_v2_path.exists():
        console.warning(
            message=(
                f"Missing {verilog_log_v1_path.name} and/or {verilog_log_v2_path.name} in "
                f"{sim_directory}. Run without --skip-modelsim to produce them, or copy them "
                f"in from another host that has ModelSim. Exiting without plots."
            ),
        )
        return
    verilog_v1_record = parse_verilog_log(path=verilog_log_v1_path, label="v1")
    verilog_v2_record = parse_verilog_log(path=verilog_log_v2_path, label="v2")

    python_orders_counts = (
        count_orders(path=python_orders_v1_path),
        count_orders(path=python_orders_v2_path),
    )
    verilog_orders_counts = (
        count_orders(path=verilog_orders_v1_path),
        count_orders(path=verilog_orders_v2_path),
    )

    print_comparison_table(
        python_v1=python_v1_record,
        python_v2=python_v2_record,
        verilog_v1=verilog_v1_record,
        verilog_v2=verilog_v2_record,
        python_orders_counts=python_orders_counts,
        verilog_orders_counts=verilog_orders_counts,
    )

    plot_comparison_overlay(
        python_v1=python_v1_record,
        python_v2=python_v2_record,
        verilog_v1=verilog_v1_record,
        verilog_v2=verilog_v2_record,
        output_directory=plots_directory,
    )
    console.success(message=f"Overlay plots written to {plots_directory}.")


if __name__ == "__main__":
    main()
