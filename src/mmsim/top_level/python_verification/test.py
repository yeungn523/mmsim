from pathlib import Path
import pandas as pd

p = Path(r"C:\Users\gaa59\Desktop\mmsim\src\mmsim\top_level\sim\sim_top_events.csv")

df = pd.read_csv(p, header=None, skiprows=1, index_col=False,
                 names=["cycle","event","c2","c3","c4","c5","c6","c7"],
                 dtype=str)

def rejoin(row):
    parts = [row["c2"], row["c3"], row["c4"], row["c5"], row["c6"], row["c7"]]
    return ",".join(str(x) for x in parts if pd.notna(x) and str(x).strip() != "")

df["detail"] = df.apply(rejoin, axis=1)
df["event"] = df["event"].str.strip()

retires = df[df["event"] == "RETIRE"]
print(f"Total RETIRE rows: {len(retires)}")
print("\nFirst 5 raw detail strings:")
for d in retires["detail"].head(5).tolist():
    print(repr(d))