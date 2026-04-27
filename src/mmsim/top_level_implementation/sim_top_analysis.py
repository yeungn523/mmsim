"""
sim_top_analysis.py
Parses sim_top_events.csv, sim_top_snapshots.csv, and sim_top_summary.csv
produced by tb_sim_top.v and validates integration correctness.
"""
from __future__ import annotations
import sys
from pathlib import Path
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec

EVENTS_FILE    = "sim_top_events.csv"
SNAPSHOTS_FILE = "sim_top_snapshots.csv"
SUMMARY_FILE   = "sim_top_summary.csv"

VIOLATION_EVENTS = {
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
    p = Path(path)
    if not p.exists():
        print(f"[ERROR] Could not find {path}. Did the simulation run successfully?")
        sys.exit(1)
    return pd.read_csv(p)


def analyze_violations(events_df: pd.DataFrame) -> bool:
    """Returns True if all clean, False if violations found."""
    violations = events_df[events_df["event"].isin(VIOLATION_EVENTS)]
    if violations.empty:
        print("[PASSED] No invariant violations detected.")
        return True

    print("[FAILED] Invariant violations detected:")
    counts = violations["event"].value_counts()
    for event_type, count in counts.items():
        print(f"  {event_type:<35} {count}")

    # Print first occurrence of each violation type for quick debugging
    print("\nFirst occurrence of each violation type:")
    for event_type in counts.index:
        first = violations[violations["event"] == event_type].iloc[0]
        print(f"  {event_type} @ cycle {first['cycle']}  detail: {first.get('detail', '')}")

    return False


def analyze_trades(events_df: pd.DataFrame) -> None:
    trades = events_df[events_df["event"] == "TRADE"].copy()
    if trades.empty:
        print("[WARNING] No trade events found in event log.")
        return

    # Parse detail column: price=X,qty=Y,side=Z
    detail = trades["detail"].str.extractall(r"(\w+)=(\d+)").unstack(level=1)[0]
    detail.columns = detail.columns.droplevel(0)
    trades = trades.join(detail[["price", "qty", "side"]].apply(pd.to_numeric))

    print(f"\nTrade Statistics:")
    print(f"  Total trades          : {len(trades)}")
    print(f"  Buy-side fills        : {(trades['side'] == 0).sum()}")
    print(f"  Sell-side fills       : {(trades['side'] == 1).sum()}")
    print(f"  Mean trade price      : {trades['price'].mean():.1f} ticks")
    print(f"  Std trade price       : {trades['price'].std():.1f} ticks")
    print(f"  Mean trade quantity   : {trades['qty'].mean():.2f} shares")
    print(f"  Max trade quantity    : {trades['qty'].max()} shares")


def analyze_summary(summary_df: pd.DataFrame) -> None:
    print("\nSimulation Summary:")
    for _, row in summary_df.iterrows():
        print(f"  {row['metric']:<35} {row['value']}")


def plot_results(snapshots_df: pd.DataFrame, events_df: pd.DataFrame) -> None:
    valid = snapshots_df[
        (snapshots_df["best_bid_valid"] == 1) &
        (snapshots_df["best_ask_valid"] == 1)
    ].copy()

    if valid.empty:
        print("[WARNING] Book never reached a valid two-sided state. No plots generated.")
        return

    valid["spread"] = valid["best_ask_price"] - valid["best_bid_price"]

    trades = events_df[events_df["event"] == "TRADE"].copy()
    trade_cycles = pd.to_numeric(trades["cycle"], errors="coerce").dropna()

    fig = plt.figure(figsize=(14, 10))
    gs  = gridspec.GridSpec(3, 1, hspace=0.4)

    # Plot 1: top of book prices
    ax1 = fig.add_subplot(gs[0])
    ax1.plot(valid["cycle"], valid["best_ask_price"],
             label="Best Ask", color="red",   alpha=0.8, linewidth=0.8)
    ax1.plot(valid["cycle"], valid["best_bid_price"],
             label="Best Bid", color="green", alpha=0.8, linewidth=0.8)
    ax1.fill_between(valid["cycle"],
                     valid["best_bid_price"], valid["best_ask_price"],
                     alpha=0.15, color="gray", label="Spread")
    ax1.set_title("Top of Book Prices")
    ax1.set_ylabel("Price (ticks)")
    ax1.legend(fontsize=8)
    ax1.grid(True, alpha=0.3)

    # Plot 2: spread over time
    ax2 = fig.add_subplot(gs[1])
    ax2.plot(valid["cycle"], valid["spread"],
             color="purple", alpha=0.8, linewidth=0.8, label="Spread")
    ax2.axhline(valid["spread"].mean(), color="orange", linestyle="--",
                linewidth=1, label=f"Mean {valid['spread'].mean():.1f}")
    ax2.set_title("Bid-Ask Spread Over Time")
    ax2.set_ylabel("Spread (ticks)")
    ax2.legend(fontsize=8)
    ax2.grid(True, alpha=0.3)

    # Plot 3: trade activity
    ax3 = fig.add_subplot(gs[2])
    if not trade_cycles.empty:
        ax3.hist(trade_cycles, bins=100, color="steelblue", alpha=0.7)
        ax3.set_title("Trade Activity Distribution Over Time")
        ax3.set_ylabel("Trade Count")
    else:
        ax3.text(0.5, 0.5, "No trade data", ha="center", va="center",
                 transform=ax3.transAxes)
    ax3.set_xlabel("Clock Cycles")
    ax3.grid(True, alpha=0.3)

    # Plot 4: last executed trade price over time
    ax4 = fig.add_subplot(gs[3])
    if 'last_trade_price' in valid.columns:
        ax4.plot(valid["cycle"], valid["last_trade_price"],
                 color="darkorange", alpha=0.8, linewidth=0.8, label="Last Trade Price")
        ax4.set_title("Last Executed Trade Price Over Time")
        ax4.set_ylabel("Price (ticks)")
        ax4.set_xlabel("Clock Cycles")
        ax4.legend(fontsize=8)
        ax4.grid(True, alpha=0.3)

    plt.suptitle("sim_top Integration Test Results", fontsize=13, fontweight="bold")

    plt.suptitle("sim_top Integration Test Results", fontsize=13, fontweight="bold")
    out_path = "sim_top_analysis.png"
    plt.savefig(out_path, dpi=150)
    print(f"\nPlot saved to {out_path}")

    # Sanity checks on spread
    print(f"\nSpread Analysis:")
    print(f"  Mean spread   : {valid['spread'].mean():.2f} ticks")
    print(f"  Max spread    : {valid['spread'].max()} ticks")
    print(f"  Min spread    : {valid['spread'].min()} ticks")
    if (valid["spread"] < 0).any():
        print("  [FAILED] Negative spread detected -- crossed book in snapshot data")
    else:
        print("  [PASSED] Spread always positive")


def main() -> None:
    print("=" * 50)
    print("sim_top Integration Test Analysis")
    print("=" * 50)

    events_df    = load_csv(EVENTS_FILE)
    snapshots_df = load_csv(SNAPSHOTS_FILE)
    summary_df   = load_csv(SUMMARY_FILE)

    passed = analyze_violations(events_df)
    analyze_trades(events_df)
    analyze_summary(summary_df)
    plot_results(snapshots_df, events_df)

    print("\n" + "=" * 50)
    print("RESULT:", "PASS" if passed else "FAIL")
    print("=" * 50)
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()