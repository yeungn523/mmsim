#!/usr/bin/env python3
"""
Golden model for CLT-12 and Ziggurat Gaussian generators
Fixed-point Q1.15 representation matching hardware implementation
"""

import numpy as np
import json
from scipy import stats as scipy_stats
from ziggurat_tables_golden import TAIL_START_R, LAYER_VOLUME_V

# ============================================================
# Fixed-point utilities (Q1.15 = 1 sign bit, 15 fractional)
# ============================================================
Q1_15_SCALE = 2**15  # 32768
Q1_15_MAX   =  32767
Q1_15_MIN   = -32768

def to_q1_15(x):
    v = int(round(x * Q1_15_SCALE))
    return max(Q1_15_MIN, min(Q1_15_MAX, v))

def from_q1_15(v):
    return v / Q1_15_SCALE

# ============================================================
# LFSR (32-bit Galois) - matches Verilog exactly
# ============================================================
POLYS = [0xB4BCD35C, 0xD4E63F5B, 0xA3E1B2C4, 0xF12A4C3D]

def galois_lfsr(state, poly):
    lsb = state & 1
    state >>= 1
    if lsb:
        state ^= poly
    return state & 0xFFFFFFFF

def lfsr_to_uniform(state):
    return (state & 0xFFFFFFFF) / 2**32

# ============================================================
# CLT-12 Gaussian Generator
# ============================================================
class CLT12Generator:
    def __init__(self, seeds):
        self.states = list(seeds)

    def next_raw(self):
        total = 0.0
        for i in range(12):
            idx = i % 4
            self.states[idx] = galois_lfsr(self.states[idx], POLYS[idx])
            total += lfsr_to_uniform(self.states[idx])
        return total - 6.0

    def generate(self, n):
        floats, fixed = [], []
        for _ in range(n):
            r = self.next_raw()
            scaled = r / 16.0
            floats.append(scaled)
            fixed.append(from_q1_15(to_q1_15(scaled)))
        return np.array(floats), np.array(fixed)

# ============================================================
# Ziggurat Method (Marsaglia & Tsang 2000)
# ============================================================
def build_ziggurat_tables(n=256):
    r = TAIL_START_R
    v = LAYER_VOLUME_V
    x = np.zeros(n + 1)
    y = np.zeros(n + 1)
    x[n] = v / np.exp(-0.5 * r * r)
    x[n-1] = r
    y[n-1] = np.exp(-0.5 * r * r)
    for i in range(n - 2, 0, -1):
        x[i] = np.sqrt(-2.0 * np.log(v / x[i+1] + np.exp(-0.5 * x[i+1]**2)))
        y[i] = np.exp(-0.5 * x[i]**2)
    x[0] = 0.0
    y[0] = 1.0
    return x, y

class ZigguratGenerator:
    def __init__(self, seeds, n_layers=256):
        self.states = list(seeds)
        self.n = n_layers
        self.x, self.y = build_ziggurat_tables(n_layers)

    def _tick(self, idx):
        self.states[idx] = galois_lfsr(self.states[idx], POLYS[idx])
        return self.states[idx]

    def next_raw(self):
        while True:
            u0 = self._tick(0)
            u1 = self._tick(1)
            layer = u0 & 0xFF
            sign = 1 if (u0 & 0x100) else -1
            xi_frac = (u0 >> 9) & 0x7FFFFF
            x_val = (xi_frac / 2**23) * self.x[layer]

            if layer > 0 and x_val < self.x[layer - 1]:
                return sign * x_val

            if layer == 0:
                while True:
                    e1 = -np.log((self._tick(2) + 0.5) / 2**32)
                    e2 = -np.log((self._tick(3) + 0.5) / 2**32)
                    if 2 * e2 >= e1 * e1:
                        return sign * (self.x[1] + e1)

            y_val = self.y[layer] + (u1 / 2**32) * (self.y[layer - 1] - self.y[layer])
            if y_val < np.exp(-0.5 * x_val * x_val):
                return sign * x_val

    def generate(self, n):
        floats, fixed = [], []
        for _ in range(n):
            r = self.next_raw()
            scaled = r / 4.0
            floats.append(scaled)
            fixed.append(from_q1_15(to_q1_15(scaled)))
        return np.array(floats), np.array(fixed)

# ============================================================
# Statistical Analysis
# ============================================================
def analyze(name, samples, reference=None):
    n = len(samples)
    std = np.std(samples)
    ks_stat, ks_p = scipy_stats.kstest(samples, 'norm', args=(0, std))
    tail_2s = float(np.mean(np.abs(samples) > 2 * std))
    tail_3s = float(np.mean(np.abs(samples) > 3 * std))
    tail_2s_theory = 2 * (1 - scipy_stats.norm.cdf(2))
    tail_3s_theory = 2 * (1 - scipy_stats.norm.cdf(3))

    # CLT-12 theoretical excess kurtosis = -0.6 (known artifact)
    return {
        "name": name,
        "n": n,
        "mean": float(np.mean(samples)),
        "std": float(std),
        "skewness": float(scipy_stats.skew(samples)),
        "excess_kurtosis": float(scipy_stats.kurtosis(samples)),
        "ks_statistic": float(ks_stat),
        "ks_p_value": float(ks_p),
        "tail_2sigma_actual": tail_2s,
        "tail_2sigma_theory": float(tail_2s_theory),
        "tail_2sigma_error_pct": float(abs(tail_2s - tail_2s_theory) / tail_2s_theory * 100),
        "tail_3sigma_actual": tail_3s,
        "tail_3sigma_theory": float(tail_3s_theory),
        "tail_3sigma_error_pct": float(abs(tail_3s - tail_3s_theory) / tail_3s_theory * 100),
    }

def make_histogram(samples, bins=80, range_=(-1.5, 1.5)):
    counts, edges = np.histogram(samples, bins=bins, range=range_, density=True)
    centers = [(edges[i] + edges[i+1]) / 2 for i in range(len(edges)-1)]
    return {"centers": [round(c, 5) for c in centers],
            "counts":  [round(float(c), 5) for c in counts]}

def make_qq(samples, n_points=200):
    sorted_s = np.sort(samples)
    n = len(sorted_s)
    idx = np.linspace(0, n-1, n_points, dtype=int)
    empirical = sorted_s[idx]
    theoretical = scipy_stats.norm.ppf(np.linspace(0.5/n, 1-0.5/n, n)[idx])
    return {
        "theoretical": [round(float(x), 5) for x in theoretical],
        "empirical":   [round(float(x), 5) for x in empirical]
    }

def make_tail_data(samples, n_points=50):
    std = np.std(samples)
    ks = np.linspace(0.5, 4.5, n_points)
    empirical   = [max(float(np.mean(np.abs(samples) > k * std)), 1e-9) for k in ks]
    theoretical = [float(2 * (1 - scipy_stats.norm.cdf(k))) for k in ks]
    return {
        "k_values":    [round(float(k), 3) for k in ks],
        "empirical":   empirical,
        "theoretical": theoretical
    }

# ============================================================
# Main
# ============================================================
if __name__ == "__main__":
    N = 100_000
    SEEDS = [0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0xABCDEF01]

    print(f"Generating {N:,} samples from each generator...")
    clt = CLT12Generator(SEEDS[:])
    zig = ZigguratGenerator(SEEDS[:])

    clt_float, clt_fixed = clt.generate(N)
    print("  CLT-12 done")
    zig_float, zig_fixed = zig.generate(N)
    print("  Ziggurat done")

    rng = np.random.default_rng(42)
    true_ref = rng.normal(0, 0.25, N)
    print("  Reference Gaussian done")

    print("Running statistical analysis...")
    s_clt = analyze("CLT-12",    clt_fixed)
    s_zig = analyze("Ziggurat",  zig_fixed)
    s_ref = analyze("Reference", true_ref)

    for s in [s_clt, s_zig, s_ref]:
        print(f"\n{s['name']}")
        print(f"  Mean:            {s['mean']:+.6f}")
        print(f"  Std:             {s['std']:.6f}")
        print(f"  Skewness:        {s['skewness']:+.6f}")
        print(f"  Excess Kurtosis: {s['excess_kurtosis']:+.6f}  (CLT-12 theoretical: -0.6)")
        print(f"  KS statistic:    {s['ks_statistic']:.6f}")
        print(f"  KS p-value:      {s['ks_p_value']:.4f}")
        print(f"  2sigma tail err: {s['tail_2sigma_error_pct']:.2f}%")
        print(f"  3sigma tail err: {s['tail_3sigma_error_pct']:.2f}%")

    output = {
        "metadata": {
            "n_samples": N,
            "seeds": [hex(s) for s in SEEDS],
            "q_format": "Q1.15",
            "scale_factor": "div4"
        },
        "stats": {"clt12": s_clt, "ziggurat": s_zig, "reference": s_ref},
        "histograms": {
            "clt12":     make_histogram(clt_fixed),
            "ziggurat":  make_histogram(zig_fixed),
            "reference": make_histogram(true_ref)
        },
        "qq_plots": {
            "clt12":    make_qq(clt_fixed),
            "ziggurat": make_qq(zig_fixed)
        },
        "tail_analysis": {
            "clt12":     make_tail_data(clt_fixed),
            "ziggurat":  make_tail_data(zig_fixed),
            "reference": make_tail_data(true_ref)
        },
        "sample_window": {
            "clt12":    [round(float(x), 6) for x in clt_fixed[:500]],
            "ziggurat": [round(float(x), 6) for x in zig_fixed[:500]]
        }
    }

    with open("results.json", "w") as f:
        json.dump(output, f, indent=2)

    print("\nSaved results.json")