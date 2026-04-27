"""Parses tb_sim_top.v output CSVs and validates integration correctness.

Consumes sim_top_events.csv, sim_top_snapshots.csv, and sim_top_summary.csv produced by the
testbench, prints invariant pass/fail and trade statistics, and emits a four-panel plot of
top-of-book prices, spread, trade activity, and last execution price.
"""

import sys
from pathlib import Path

import matplotlib.gridspec as gridspec
import matplotlib.pyplot as plt
import pandas as pd

_EVENTS_FILE: str = "sim_top_events.csv"
_SNAPSHOTS_FILE: str = "sim_top_snapshots.csv"
_SUMMARY_FILE: str = "sim_top_summary.csv"
_PLOT_OUTPUT: str = "sim_top_analysis.png"

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


def load_csv(path: str) -> pd.DataFrame:
    """Loads a CSV file produced by the testbench, exiting if the file is missing.

    Args:
        path: The CSV path relative to the simulation working directory.

    Returns:
        The parsed DataFrame.
    """
    csv_path = Path(path)
    if not csv_path.exists():
        print(f"[ERROR] Could not find {path}. Did the simulation run successfully?")
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

    detail = trades["detail"].str.extractall(r"(\w+)=(\d+)").unstack(level=1)[0]
    detail.columns = detail.columns.droplevel(0)
    trades = trades.join(detail[["price", "qty", "side"]].apply(pd.to_numeric))

    print("\nTrade Statistics:")
    print(f"  Total trades          : {len(trades)}")
    print(f"  Buy-side fills        : {(trades['side'] == 0).sum()}")
    print(f"  Sell-side fills       : {(trades['side'] == 1).sum()}")
    print(f"  Mean trade price      : {trades['price'].mean():.1f} ticks")
    print(f"  Std trade price       : {trades['price'].std():.1f} ticks")
    print(f"  Mean trade quantity   : {trades['qty'].mean():.2f} shares")
    print(f"  Max trade quantity    : {trades['qty'].max()} shares")


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

    trades = events_df[events_df["event"] == "TRADE"].copy()
    trade_cycles = pd.to_numeric(trades["cycle"], errors="coerce").dropna()

    fig = plt.figure(figsize=(14, 12))
    grid = gridspec.GridSpec(4, 1, hspace=0.5)

    ax_top = fig.add_subplot(grid[0])
    ax_top.plot(valid["cycle"], valid["best_ask_price"], label="Best Ask", color="red", alpha=0.8, linewidth=0.8)
    ax_top.plot(valid["cycle"], valid["best_bid_price"], label="Best Bid", color="green", alpha=0.8, linewidth=0.8)
    ax_top.fill_between(
        valid["cycle"],
        valid["best_bid_price"],
        valid["best_ask_price"],
        alpha=0.15,
        color="gray",
        label="Spread",
    )
    ax_top.set_title("Top of Book Prices")
    ax_top.set_ylabel("Price (ticks)")
    ax_top.legend(fontsize=8)
    ax_top.grid(True, alpha=0.3)

    ax_spread = fig.add_subplot(grid[1])
    ax_spread.plot(valid["cycle"], valid["spread"], color="purple", alpha=0.8, linewidth=0.8, label="Spread")
    ax_spread.axhline(
        valid["spread"].mean(),
        color="orange",
        linestyle="--",
        linewidth=1,
        label=f"Mean {valid['spread'].mean():.1f}",
    )
    ax_spread.set_title("Bid-Ask Spread Over Time")
    ax_spread.set_ylabel("Spread (ticks)")
    ax_spread.legend(fontsize=8)
    ax_spread.grid(True, alpha=0.3)

    ax_trades = fig.add_subplot(grid[2])
    if not trade_cycles.empty:
        ax_trades.hist(trade_cycles, bins=100, color="steelblue", alpha=0.7)
        ax_trades.set_title("Trade Activity Distribution Over Time")
        ax_trades.set_ylabel("Trade Count")
    else:
        ax_trades.text(0.5, 0.5, "No trade data", ha="center", va="center", transform=ax_trades.transAxes)
    ax_trades.grid(True, alpha=0.3)

    ax_last = fig.add_subplot(grid[3])
    if "last_executed_price" in valid.columns:
        ax_last.plot(
            valid["cycle"],
            valid["last_executed_price"],
            color="darkorange",
            alpha=0.8,
            linewidth=0.8,
            label="Last Executed Price",
        )
        ax_last.set_title("Last Executed Price Over Time")
        ax_last.set_ylabel("Price (ticks)")
        ax_last.legend(fontsize=8)
        ax_last.grid(True, alpha=0.3)
    ax_last.set_xlabel("Clock Cycles")

    plt.suptitle("sim_top Integration Test Results", fontsize=13, fontweight="bold")
    plt.savefig(_PLOT_OUTPUT, dpi=150)
    print(f"\nPlot saved to {_PLOT_OUTPUT}")

    print("\nSpread Analysis:")
    print(f"  Mean spread   : {valid['spread'].mean():.2f} ticks")
    print(f"  Max spread    : {valid['spread'].max()} ticks")
    print(f"  Min spread    : {valid['spread'].min()} ticks")
    if (valid["spread"] < 0).any():
        print("  [FAILED] Negative spread detected -- crossed book in snapshot data")
    else:
        print("  [PASSED] Spread always positive")


def main() -> None:
    """Runs the analysis pipeline against the testbench's CSV outputs."""
    print("=" * 50)
    print("sim_top Integration Test Analysis")
    print("=" * 50)

    events_df = load_csv(path=_EVENTS_FILE)
    snapshots_df = load_csv(path=_SNAPSHOTS_FILE)
    summary_df = load_csv(path=_SUMMARY_FILE)

    passed = analyze_violations(events_df=events_df)
    analyze_trades(events_df=events_df)
    analyze_summary(summary_df=summary_df)
    plot_results(snapshots_df=snapshots_df, events_df=events_df)

    print("\n" + "=" * 50)
    print("RESULT:", "PASS" if passed else "FAIL")
    print("=" * 50)
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
