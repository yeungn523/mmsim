"""Parses tb_sim_top.v output CSVs and validates integration correctness.

Consumes sim_top_events.csv, sim_top_snapshots.csv, and sim_top_summary.csv produced by the
testbench, prints invariant pass/fail and trade statistics, and emits a four-panel plot of
top-of-book prices, spread, trade activity, and last execution price. Exits with code 0 when
no invariants are violated and 1 otherwise so callers can chain the script into CI pipelines.
"""

import sys
from pathlib import Path

import matplotlib.gridspec as gridspec
import matplotlib.pyplot as plt
import pandas as pd

_SIM_DIR: Path = Path(__file__).parent.parent / "sim"
_EVENTS_CSV: Path = _SIM_DIR / "sim_top_events.csv"
_SNAPSHOTS_CSV: Path = _SIM_DIR / "sim_top_snapshots.csv"
_SUMMARY_CSV: Path = _SIM_DIR / "sim_top_summary.csv"
_PLOT_OUTPUT_PATH: Path = Path(__file__).parent / "top_verify.png"
_SPREAD_PLOT_PATH: Path = Path(__file__).parent / "top_verify_spread.png"

_TICK_SHIFT_BITS: int = 23
_MARKET_MAKER_MIN_SPREAD: int = 8
_SPREAD_CUTOFF_TICKS: int = 10

_VIOLATION_EVENTS: set[str] = {
    "CROSSED_BOOK",
    "PHANTOM_BID_VALID",
    "PHANTOM_ASK_VALID",
    "FIFO_FULL",
    "IN_FLIGHT_OVERFLOW",
    "ZERO_QTY_TRADE",
    "CONSERVATION_ERROR",
    "INVALID_TRADE_PRICE",
    "TRADE_PRICE_OUT_OF_RANGE",
}

_EVENT_DETAIL_COLUMNS: tuple[str, ...] = ("c2", "c3", "c4", "c5", "c6", "c7")


def rejoin_event_detail(row: pd.Series) -> str:
    """Rejoins the trailing event-detail columns into a single comma-separated string.

    Notes:
        The testbench emits a jagged CSV in which the detail field contains commas. The reader
        splits the detail across columns c2 through c7. This helper concatenates the non-empty
        values back into the canonical detail string consumed by the downstream parsers.

    Args:
        row: The row from the events DataFrame containing the c2 through c7 columns.

    Returns:
        The reconstructed detail string with empty columns omitted.
    """
    parts = [row[column] for column in _EVENT_DETAIL_COLUMNS]
    return ",".join(str(part) for part in parts if pd.notna(part) and str(part).strip() != "")


def load_events_dataframe(csv_path: Path) -> pd.DataFrame:
    """Loads the jagged events CSV and reconstructs the detail column.

    Args:
        csv_path: The path to the sim_top_events.csv emitted by the testbench.

    Returns:
        A DataFrame with the canonical cycle, event, and detail columns. Rows with a
        non-numeric cycle field are dropped.
    """
    if not csv_path.exists():
        print(f"[ERROR] Could not find {csv_path}. Did the simulation run successfully?")
        sys.exit(1)

    events_df = pd.read_csv(
        csv_path,
        header=None,
        skiprows=1,
        index_col=False,
        names=["cycle", "event", *_EVENT_DETAIL_COLUMNS],
        dtype=str,
    )
    events_df["detail"] = events_df.apply(rejoin_event_detail, axis=1)
    events_df = events_df[["cycle", "event", "detail"]].copy()
    events_df["cycle"] = pd.to_numeric(events_df["cycle"], errors="coerce")
    events_df = events_df.dropna(subset=["cycle"])
    events_df["cycle"] = events_df["cycle"].astype(int)
    events_df["event"] = events_df["event"].str.strip()
    return events_df


def load_dataframe(csv_path: Path) -> pd.DataFrame:
    """Loads a regularly-shaped CSV produced by the testbench.

    Args:
        csv_path: The path to the CSV file written by the testbench.

    Returns:
        The parsed DataFrame.
    """
    if not csv_path.exists():
        print(f"[ERROR] Could not find {csv_path}. Did the simulation run successfully?")
        sys.exit(1)
    return pd.read_csv(csv_path)


def analyze_violations(events_df: pd.DataFrame) -> bool:
    """Reports invariant violations from the event log.

    Args:
        events_df: The DataFrame parsed from sim_top_events.csv.

    Returns:
        True when the log contains no invariant violations, False otherwise.
    """
    violations = events_df[events_df["event"].isin(_VIOLATION_EVENTS)]
    if violations.empty:
        print("[PASSED] No invariant violations detected.")
        return True

    print("[FAILED] Invariant violations detected:")
    counts = violations["event"].value_counts()
    for event_type, count in counts.items():
        print(f"  {event_type:<35} {count}")

    print("\nFirst occurrence of each violation type:")
    for event_type in counts.index:
        first = violations[violations["event"] == event_type].iloc[0]
        print(f"  {event_type} @ cycle {first['cycle']}  detail: {first.get('detail', '')}")

    return False


def analyze_trades(events_df: pd.DataFrame) -> None:
    """Prints summary statistics for every TRADE event in the log.

    Args:
        events_df: The DataFrame parsed from sim_top_events.csv.
    """
    trades = events_df[events_df["event"] == "TRADE"].copy()
    if trades.empty:
        print("[WARNING] No trade events found in event log.")
        return

    detail = trades["detail"].str.extract(
        r"price=(?P<price>\d+),qty=(?P<qty>\d+),side=(?P<side>\d+)",
    )
    trades = trades.join(detail)
    trades[["price", "qty", "side"]] = trades[["price", "qty", "side"]].apply(pd.to_numeric)

    print("\nTrade Statistics:")
    print(f"  Total trades          : {len(trades)}")
    print(f"  Buy-side fills        : {(trades['side'] == 0).sum()}")
    print(f"  Sell-side fills       : {(trades['side'] == 1).sum()}")
    print(f"  Mean trade price      : {trades['price'].mean():.1f} ticks")
    print(f"  Std trade price       : {trades['price'].std():.1f} ticks")
    print(f"  Mean trade quantity   : {trades['qty'].mean():.2f} shares")
    print(f"  Max trade quantity    : {trades['qty'].max()} shares")


def analyze_spread_distribution(events_df: pd.DataFrame) -> None:
    """Reports spread statistics and renders a spread distribution plot at retirement points.

    Notes:
        Only retirements with a valid two-sided book at the moment of capture are included so
        the spread reflects the genuine bid-ask gap rather than an artefact of a one-sided
        book. The histogram and time series are written to _SPREAD_PLOT_PATH.

    Args:
        events_df: The DataFrame parsed from sim_top_events.csv.
    """
    retires = events_df[events_df["event"] == "RETIRE"].copy()
    if retires.empty:
        print("[WARNING] No RETIRE events found.")
        return

    detail = retires["detail"].str.extract(
        r"trade_count=(?P<trade_count>\d+),fill_qty=(?P<fill_qty>\d+),"
        r"bid=(?P<bid>\d+),ask=(?P<ask>\d+),bid_v=(?P<bid_v>\d+),ask_v=(?P<ask_v>\d+)",
    )
    retires = retires.join(detail)

    numeric_columns = ["bid", "ask", "trade_count", "fill_qty", "bid_v", "ask_v"]
    retires[numeric_columns] = retires[numeric_columns].apply(pd.to_numeric)

    # Only consider retirements where both sides of the book are populated.
    retires = retires[(retires["bid_v"] == 1) & (retires["ask_v"] == 1)].copy()
    retires["spread"] = retires["ask"] - retires["bid"]

    spread_under_cutoff = retires["spread"] < _SPREAD_CUTOFF_TICKS
    print("\nSpread at Retirement Points:")
    print(f"  Samples               : {len(retires)}")
    print(f"  Mean spread           : {retires['spread'].mean():.2f} ticks")
    print(f"  Median spread         : {retires['spread'].median():.2f} ticks")
    print(f"  Std spread            : {retires['spread'].std():.2f} ticks")
    print(f"  Min spread            : {retires['spread'].min()} ticks")
    print(f"  Max spread            : {retires['spread'].max()} ticks")
    print(f"  Zero spread events    : {(retires['spread'] == 0).sum()}")
    print(f"  Negative spread events: {(retires['spread'] < 0).sum()}")
    print(
        f"  Spread < {_SPREAD_CUTOFF_TICKS} ticks     : {spread_under_cutoff.sum()} "
        f"({100 * spread_under_cutoff.mean():.1f}%)",
    )

    figure, (histogram_axis, time_axis) = plt.subplots(1, 2, figsize=(12, 4))

    retires["spread"].hist(bins=50, ax=histogram_axis, color="steelblue", alpha=0.7)
    histogram_axis.axvline(
        retires["spread"].mean(),
        color="orange",
        linestyle="--",
        label=f"Mean {retires['spread'].mean():.1f}",
    )
    histogram_axis.axvline(
        _MARKET_MAKER_MIN_SPREAD,
        color="red",
        linestyle=":",
        label=f"MM min spread ({_MARKET_MAKER_MIN_SPREAD})",
    )
    histogram_axis.set_title("Spread Distribution at Retirement")
    histogram_axis.set_xlabel("Spread (ticks)")
    histogram_axis.set_ylabel("Count")
    histogram_axis.legend(fontsize=8)

    time_axis.plot(
        retires["cycle"],
        retires["spread"],
        linewidth=0.6,
        color="purple",
        alpha=0.7,
    )
    time_axis.axhline(
        _MARKET_MAKER_MIN_SPREAD,
        color="red",
        linestyle=":",
        linewidth=1,
        label=f"MM min ({_MARKET_MAKER_MIN_SPREAD})",
    )
    time_axis.axhline(
        retires["spread"].mean(),
        color="orange",
        linestyle="--",
        linewidth=1,
        label=f"Mean {retires['spread'].mean():.1f}",
    )
    time_axis.set_title("Spread Over Time (at Retirements)")
    time_axis.set_xlabel("Cycle")
    time_axis.set_ylabel("Spread (ticks)")
    time_axis.legend(fontsize=8)

    plt.tight_layout()
    plt.savefig(_SPREAD_PLOT_PATH, dpi=150)
    print(f"  Spread analysis plot saved to {_SPREAD_PLOT_PATH}")


def analyze_summary(summary_df: pd.DataFrame) -> None:
    """Prints the per-metric counts captured by the testbench at end of run.

    Args:
        summary_df: The DataFrame parsed from sim_top_summary.csv.
    """
    print("\nSimulation Summary:")
    for _, row in summary_df.iterrows():
        print(f"  {row['metric']:<35} {row['value']}")


def plot_results(snapshots_df: pd.DataFrame, events_df: pd.DataFrame) -> None:
    """Renders a four-panel summary plot of book state and trade activity.

    Args:
        snapshots_df: The DataFrame parsed from sim_top_snapshots.csv.
        events_df: The DataFrame parsed from sim_top_events.csv.
    """
    valid = snapshots_df[
        (snapshots_df["best_bid_valid"] == 1) & (snapshots_df["best_ask_valid"] == 1)
    ].copy()

    if valid.empty:
        print("[WARNING] Book never reached a valid two-sided state. No plots generated.")
        return

    valid["spread"] = valid["best_ask_price"] - valid["best_bid_price"]
    valid["last_executed_price_ticks"] = valid["last_executed_price"] / (2 ** _TICK_SHIFT_BITS)

    trades = events_df[events_df["event"] == "TRADE"].copy()
    trade_cycles = pd.to_numeric(trades["cycle"], errors="coerce").dropna()

    figure = plt.figure(figsize=(14, 12))
    grid = gridspec.GridSpec(4, 1, hspace=0.5)

    top_axis = figure.add_subplot(grid[0])
    top_axis.plot(
        valid["cycle"],
        valid["best_ask_price"],
        label="Best Ask",
        color="red",
        alpha=0.8,
        linewidth=0.8,
    )
    top_axis.plot(
        valid["cycle"],
        valid["best_bid_price"],
        label="Best Bid",
        color="green",
        alpha=0.8,
        linewidth=0.8,
    )
    top_axis.fill_between(
        valid["cycle"],
        valid["best_bid_price"],
        valid["best_ask_price"],
        alpha=0.15,
        color="gray",
        label="Spread",
    )
    top_axis.set_title("Top of Book Prices")
    top_axis.set_ylabel("Price (ticks)")
    top_axis.legend(fontsize=8)
    top_axis.grid(True, alpha=0.3)

    spread_axis = figure.add_subplot(grid[1])
    spread_axis.plot(
        valid["cycle"],
        valid["spread"],
        color="purple",
        alpha=0.8,
        linewidth=0.8,
        label="Spread",
    )
    spread_axis.axhline(
        valid["spread"].mean(),
        color="orange",
        linestyle="--",
        linewidth=1,
        label=f"Mean {valid['spread'].mean():.1f}",
    )
    spread_axis.set_title("Bid-Ask Spread Over Time")
    spread_axis.set_ylabel("Spread (ticks)")
    spread_axis.legend(fontsize=8)
    spread_axis.grid(True, alpha=0.3)

    trades_axis = figure.add_subplot(grid[2])
    if not trade_cycles.empty:
        trades_axis.hist(trade_cycles, bins=100, color="steelblue", alpha=0.7)
        trades_axis.set_title("Trade Activity Distribution Over Time")
        trades_axis.set_ylabel("Trade Count")
    else:
        trades_axis.text(
            0.5,
            0.5,
            "No trade data",
            ha="center",
            va="center",
            transform=trades_axis.transAxes,
        )
    trades_axis.grid(True, alpha=0.3)

    last_price_axis = figure.add_subplot(grid[3])
    if "last_executed_price" in valid.columns:
        last_price_axis.plot(
            valid["cycle"],
            valid["last_executed_price_ticks"],
            color="darkorange",
            alpha=0.8,
            linewidth=0.8,
            label="Last Executed Price",
        )
        last_price_axis.set_title("Last Executed Price Over Time")
        last_price_axis.set_ylabel("Price (ticks)")
        last_price_axis.legend(fontsize=8)
        last_price_axis.grid(True, alpha=0.3)
    last_price_axis.set_xlabel("Clock Cycles")

    plt.suptitle("sim_top Integration Test Results", fontsize=13, fontweight="bold")
    plt.savefig(_PLOT_OUTPUT_PATH, dpi=150)
    print(f"\nPlot saved to {_PLOT_OUTPUT_PATH}")

    print("\nSpread Analysis:")
    print(f"  Mean spread   : {valid['spread'].mean():.2f} ticks")
    print(f"  Max spread    : {valid['spread'].max()} ticks")
    print(f"  Min spread    : {valid['spread'].min()} ticks")
    if (valid["spread"] < 0).any():
        print("  [FAILED] Negative spread detected -- crossed book in snapshot data")
    else:
        print("  [PASSED] Spread always positive")


def main() -> None:
    """Runs the analysis pipeline against the testbench's CSV outputs.

    Loads the events, snapshots, and summary CSVs, validates invariants, prints trade and
    spread statistics, renders the diagnostic plots, and exits with a non-zero status when any
    invariant violation was detected so the caller can branch on the verdict.
    """
    print("=" * 50)
    print("sim_top Integration Test Analysis")
    print("=" * 50)

    events_df = load_events_dataframe(csv_path=_EVENTS_CSV)
    snapshots_df = load_dataframe(csv_path=_SNAPSHOTS_CSV)
    summary_df = load_dataframe(csv_path=_SUMMARY_CSV)

    passed = analyze_violations(events_df=events_df)
    analyze_trades(events_df=events_df)
    analyze_spread_distribution(events_df=events_df)
    analyze_summary(summary_df=summary_df)
    plot_results(snapshots_df=snapshots_df, events_df=events_df)

    print("\n" + "=" * 50)
    print("RESULT:", "PASS" if passed else "FAIL")
    print("=" * 50)
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
