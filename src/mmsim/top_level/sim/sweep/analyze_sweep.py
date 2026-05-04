"""Ranks main effects across a 2^(12-6) resolution-IV sweep.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

AXES = [
    "p1_noise", "p2_noise", "p3_noise",
    "p1_mm",    "p2_mm",    "p3_mm",
    "p1_mom",   "p2_mom",   "p3_mom",
    "p1_val",   "p2_val",   "p3_val",
]

# Mirrors the bounds in sweep.ps1; analyzer must agree on which level counts as "high".
LEVELS = {
    "p1_noise": (350,  1023),
    "p2_noise": (16,   64),
    "p3_noise": (4,    16),
    "p1_mm":    (400,  1023),
    "p2_mm":    (2,    8),
    "p3_mm":    (3,    10),
    "p1_mom":   (8,    30),
    "p2_mom":   (2,    8),
    "p3_mom":   (2,    8),
    "p1_val":   (4,    16),
    "p2_val":   (8,    32),
    "p3_val":   (5,    20),
}


def parse_args() -> argparse.Namespace:
    """Returns CLI arguments selecting the response column and ranking direction."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--results", default="results.csv",
        help="path to the sweep results CSV (default: ./results.csv)",
    )
    parser.add_argument(
        "--metric", default="drift_mse",
        help="response column to rank by (default: drift_mse)",
    )
    parser.add_argument(
        "--ascending", action="store_true",
        help="rank rows ascending instead of descending (use for drift/loss metrics)",
    )
    parser.add_argument(
        "--top", type=int, default=5,
        help="number of best/worst rows to display (default: 5)",
    )
    return parser.parse_args()


def encode_sign(row: dict[str, str], axis: str) -> int:
    """Returns +1 if the row used the high level for the named axis, else -1."""
    low, high = LEVELS[axis]
    value = int(row[axis])
    if value == high:
        return 1
    if value == low:
        return -1
    raise ValueError(
        f"row {row.get('tag')} axis {axis} = {value} is neither low ({low}) nor high ({high})"
    )


def main() -> None:
    """Loads results.csv, computes main effects, and prints the ranking tables."""
    args = parse_args()

    results_path = Path(args.results)
    if not results_path.exists():
        raise SystemExit(f"results file not found: {results_path}")

    with results_path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))

    if not rows:
        raise SystemExit("results file is empty")

    if args.metric not in rows[0]:
        raise SystemExit(
            f"metric '{args.metric}' not in results; available: {list(rows[0].keys())}"
        )

    # Builds a (n_rows, 12) sign matrix and an n_rows response vector.
    signs: list[list[int]] = []
    response: list[float] = []
    for row in rows:
        signs.append([encode_sign(row, axis) for axis in AXES])
        response.append(float(row[args.metric]))

    # Computes Yates-style main effect: mean(response | axis=high) - mean(response | axis=low).
    print(f"\nMain effects on '{args.metric}' (n = {len(rows)} rows):")
    print(f"{'axis':<10}  {'low_mean':>14}  {'high_mean':>14}  {'effect':>14}")
    print("-" * 60)
    effects = []
    for i, axis in enumerate(AXES):
        low_vals  = [response[r] for r in range(len(rows)) if signs[r][i] == -1]
        high_vals = [response[r] for r in range(len(rows)) if signs[r][i] ==  1]
        low_mean  = sum(low_vals)  / max(len(low_vals),  1)
        high_mean = sum(high_vals) / max(len(high_vals), 1)
        effect    = high_mean - low_mean
        effects.append((axis, low_mean, high_mean, effect))

    # Sorts axes by absolute effect so the dominant levers float to the top.
    effects.sort(key=lambda x: abs(x[3]), reverse=True)
    for axis, low_mean, high_mean, effect in effects:
        print(f"{axis:<10}  {low_mean:>14.2f}  {high_mean:>14.2f}  {effect:>+14.2f}")

    # Picks the top-N rows by the response metric.
    sorted_rows = sorted(
        zip(rows, response),
        key=lambda pair: pair[1],
        reverse=not args.ascending,
    )
    direction = "lowest" if args.ascending else "highest"
    print(f"\nTop {args.top} rows by {direction} {args.metric}:")
    print(f"{'tag':<8}  {'metric':>14}  params")
    print("-" * 80)
    for row, value in sorted_rows[: args.top]:
        params = " ".join(f"{a}={row[a]}" for a in AXES)
        print(f"{row['tag']:<8}  {value:>14.2f}  {params}")

    # Surfaces invariant violations so the user does not chase a "best" row that crashed.
    bad_rows = [
        r for r in rows
        if any(int(r.get(col, 0)) > 0 for col in
               ("crossed", "phantom", "fifo_full", "conservation", "invalid_price"))
    ]
    if bad_rows:
        print(f"\nWARNING: {len(bad_rows)} rows triggered invariant violations:")
        for r in bad_rows[:10]:
            print(f"  {r['tag']}  cross={r['crossed']} phantom={r['phantom']} "
                  f"fifo={r['fifo_full']} cons={r['conservation']} bad_price={r['invalid_price']}")


if __name__ == "__main__":
    main()
