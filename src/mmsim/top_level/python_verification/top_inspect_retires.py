"""Prints the raw detail strings of retired events captured in sim_top_events.csv.
"""

from pathlib import Path

import pandas as pd

_EVENTS_CSV: Path = Path(r"C:\Users\gaa59\Desktop\mmsim\src\mmsim\top_level\sim\sim_top_events.csv")
_PREVIEW_ROW_COUNT: int = 5
_EVENT_DETAIL_COLUMNS: tuple[str, ...] = ("c2", "c3", "c4", "c5", "c6", "c7")


def rejoin_event_detail(row: pd.Series) -> str:
    """Rejoins the trailing event-detail columns into a single comma-separated string.

    Args:
        row: The row from the events DataFrame containing the c2 through c7 columns.

    Returns:
        The reconstructed detail string with empty columns omitted.
    """
    parts = [row[column] for column in _EVENT_DETAIL_COLUMNS]
    return ",".join(str(part) for part in parts if pd.notna(part) and str(part).strip() != "")


def main() -> None:
    """Loads the events CSV and prints the first RETIRE detail strings as repr literals."""
    if not _EVENTS_CSV.exists():
        print(f"[ERROR] Could not find {_EVENTS_CSV}. Did the simulation run successfully?")
        return

    events_df = pd.read_csv(
        _EVENTS_CSV,
        header=None,
        skiprows=1,
        index_col=False,
        names=["cycle", "event", *_EVENT_DETAIL_COLUMNS],
        dtype=str,
    )
    events_df["detail"] = events_df.apply(rejoin_event_detail, axis=1)
    events_df["event"] = events_df["event"].str.strip()

    retires = events_df[events_df["event"] == "RETIRE"]
    print(f"Total RETIRE rows: {len(retires)}")
    print(f"\nFirst {_PREVIEW_ROW_COUNT} raw detail strings:")
    for detail in retires["detail"].head(_PREVIEW_ROW_COUNT).tolist():
        print(repr(detail))


if __name__ == "__main__":
    main()
