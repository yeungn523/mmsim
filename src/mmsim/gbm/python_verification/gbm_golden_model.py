"""
gbm_golden_model.py
===================
Integer-only fixed-point GBM golden model.
Supports both Euler-Maruyama and Log-Space architectures.
"""
import numpy as np
import matplotlib.pyplot as plt
from scipy import stats
import csv
import json
import argparse
import sys
import os

try:
    from exp_lut_golden import EXP_LUT, L_MIN_FIXED, L_STEP_RECIP, N_ENTRIES, L_MAX, L_FRAC, l_to_price
    L_FRAC   = 24
    L0_FIXED = 0x049AEC6F
    LOGSPACE_AVAILABLE = True
except ImportError:
    print("WARNING: exp_lut_golden.py not found. Run gen_exp_lut.py first.")
    EXP_LUT = []
    LOGSPACE_AVAILABLE = False

# Directory that ModelSim runs from; .hex outputs consumed by $readmemh are written here so
# the testbench can find them regardless of the Python script's working directory.
SIM_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sim"))

# Fixed-point format constants 
PRICE_FRAC  = 24   # Q8.24
SIGMA_FRAC  = 24   # Q8.24
Z_FRAC      = 12   # Q4.12
PRICE_WIDTH = 32
SIGMA_WIDTH = 32
Z_WIDTH     = 16
Q8_24_MAX   = (1 << PRICE_WIDTH) - 1
Q8_24_MIN   = 1
SIGMA_MAX   = (1 << SIGMA_WIDTH) - 1
SIGMA_MIN   = 1

# Simulation parameters
SIGMA_ANNUAL = 0.16
MU_ANNUAL    = 0.0
P0_REAL      = 100.0
ALPHA_REAL   = 0.99
FEEDBACK_EN  = True
DT           = 1.0 / (252 * 6.5 * 3600)
N_VALIDATE   = 1_000_000
N_GENERATE   = 1_000_000
BITEXACT_TICKS = 500
RNG_SEED     = 0xDEADBEEF

# Helpers 
def to_fixed(real_val, frac_bits):
    return int(round(real_val * (1 << frac_bits)))

def from_fixed(int_val, frac_bits):
    return int_val / (1 << frac_bits)

def round_shift(val, shift):
    if shift <= 0:
        return val << (-shift)
    return (val + (1 << (shift - 1))) >> shift

def clamp(val, lo, hi):
    return max(lo, min(hi, val))

def quantize_z(z_real):
    z_int = int(round(z_real * (1 << Z_FRAC)))
    return clamp(z_int, -(8 << Z_FRAC), (8 << Z_FRAC) - 1)

def sigma_tick_from_annual(sigma_annual, dt):
    return sigma_annual * np.sqrt(dt)

def mu_ito_tick(mu_annual, sigma_annual, dt):
    return (mu_annual - 0.5 * sigma_annual**2) * dt

# Precomputed constants 
def build_constants(dt=DT):
    sigma_t       = sigma_tick_from_annual(SIGMA_ANNUAL, dt)
    mu_ito_t      = mu_ito_tick(MU_ANNUAL, SIGMA_ANNUAL, dt)
    mu_ito_fp     = to_fixed(mu_ito_t, PRICE_FRAC)
    sigma_init_fp = clamp(to_fixed(sigma_t, SIGMA_FRAC), SIGMA_MIN, SIGMA_MAX)
    alpha_fp      = clamp(to_fixed(ALPHA_REAL, SIGMA_FRAC), 0, (1 << SIGMA_FRAC) - 1)
    one_m_alpha   = (1 << SIGMA_FRAC) - alpha_fp
    P0_fp         = clamp(to_fixed(P0_REAL, PRICE_FRAC), Q8_24_MIN, Q8_24_MAX)
    P0_recip_fp   = int(round((1 << PRICE_FRAC) / P0_REAL))
    return {
        "dt":            dt,
        "sigma_t":       sigma_t,
        "mu_ito_t":      mu_ito_t,
        "mu_ito_fp":     mu_ito_fp,
        "sigma_init_fp": sigma_init_fp,
        "alpha_fp":      alpha_fp,
        "one_m_alpha":   one_m_alpha,
        "P0_fp":         P0_fp,
        "P0_recip_fp":   P0_recip_fp,
    }

# Shared sigma feedback
def sigma_feedback(P_new, P_old, sigma, C):
    delta_P        = abs(P_new - P_old)
    # delta_P (Q8.24) * P0_recip (Q8.24) = Q16.48, shift by 24 -> Q8.24
    abs_ret_norm   = round_shift(delta_P * C["P0_recip_fp"], PRICE_FRAC)
    abs_ret_norm   = clamp(abs_ret_norm, 0, SIGMA_MAX)
    abs_ret_scaled = clamp(abs_ret_norm + (abs_ret_norm >> 2), 0, SIGMA_MAX)
    sigma_new = (round_shift(C["alpha_fp"]    * sigma,          SIGMA_FRAC) +
                 round_shift(C["one_m_alpha"] * abs_ret_scaled, SIGMA_FRAC))
    return clamp(sigma_new, C["sigma_init_fp"], SIGMA_MAX)

# Euler tick 
def gbm_tick_euler(P, sigma, Z_int, C, feedback_en=True):
    drift      = round_shift(P * C["mu_ito_fp"], PRICE_FRAC)
    P_sigma    = round_shift(P * sigma,          SIGMA_FRAC)
    diffusion  = round_shift(P_sigma * Z_int,    Z_FRAC)
    P_new      = clamp(P + drift + diffusion, Q8_24_MIN, Q8_24_MAX)
    sigma_new  = sigma_feedback(P_new, P, sigma, C) if feedback_en else sigma
    return int(P_new), int(sigma_new)

# Log-space tick 
def gbm_tick_logspace(L, P, sigma, Z_int, C, feedback_en=True):
    if not LOGSPACE_AVAILABLE:
        raise RuntimeError("exp_lut_golden.py not loaded — run gen_exp_lut.py first")
    
    L_MIN_FP  = L_MIN_FIXED
    L_MAX_FP  = int(round(L_MAX * (1 << L_FRAC)))
    
    diffusion = round_shift(C["sigma_init_fp"] * Z_int, Z_FRAC)
    L_new     = clamp(L + C["mu_ito_fp"] + diffusion, L_MIN_FP, L_MAX_FP)
    
    P_new     = l_to_price(L_new)
    
    sigma_new = sigma_feedback(P_new, P, sigma, C) if feedback_en else sigma
    return int(L_new), int(P_new), int(sigma_new)

# Run simulation 
def run_simulation(Z_int_array, C, feedback_en=True, dut="euler"):
    N           = len(Z_int_array)
    P_array     = np.zeros(N + 1, dtype=np.int64)
    sigma_array = np.zeros(N + 1, dtype=np.int64)
    P_array[0]     = C["P0_fp"]
    sigma_array[0] = C["sigma_init_fp"]

    if dut == "euler":
        for i in range(N):
            P_array[i+1], sigma_array[i+1] = gbm_tick_euler(
                int(P_array[i]), int(sigma_array[i]),
                int(Z_int_array[i]), C, feedback_en)
    else:
        L_array    = np.zeros(N + 1, dtype=np.int64)
        L_array[0] = L0_FIXED
        for i in range(N):
            L_array[i+1], P_array[i+1], sigma_array[i+1] = gbm_tick_logspace(
                int(L_array[i]), int(P_array[i]), int(sigma_array[i]),
                int(Z_int_array[i]), C, feedback_en)
    return P_array, sigma_array

# Float64 reference 
def run_float_reference(Z_real_array, C):
    N       = len(Z_real_array)
    sigma_t = C["sigma_t"]
    mu_t    = C["mu_ito_t"]
    P_f     = np.zeros(N + 1)
    sig_f   = np.zeros(N + 1)
    P_f[0]  = P0_REAL
    sig_f[0] = sigma_t
    for i in range(N):
        drift     = P_f[i] * mu_t
        diffusion = P_f[i] * sigma_t * Z_real_array[i]
        P_new     = max(P0_REAL * 1e-6, P_f[i] + drift + diffusion)
        P_f[i+1]  = P_new
        abs_ret   = (abs(P_f[i+1] - P_f[i]) / max(P0_REAL, 1e-10)) * 1.25
        sig_f[i+1] = max(sig_f[0], ALPHA_REAL * sig_f[i] + (1 - ALPHA_REAL) * abs_ret)
    return P_f, sig_f

# Statistical tests 
def run_statistical_tests(P_array, sigma_array, C, label="Golden Model"):
    P_real   = P_array / (1 << PRICE_FRAC)
    sig_real = sigma_array / (1 << SIGMA_FRAC)
    N        = len(P_real) - 1
    log_returns = np.diff(np.log(np.maximum(P_real, 1e-10)))
    theo_mean   = C["mu_ito_t"]
    theo_std    = C["sigma_t"]
    lr_sample   = log_returns[:100_000] if N > 100_000 else log_returns
    lr_normed   = (lr_sample - theo_mean) / theo_std
    ks_stat, ks_pval = stats.kstest(lr_normed, "norm")
    lr_mean = float(np.mean(log_returns))
    lr_std  = float(np.std(log_returns))
    mean_bias_sigma = abs(lr_mean - theo_mean) / theo_std
    std_err_frac    = abs(lr_std  - theo_std)  / theo_std
    acf_returns = [float(np.corrcoef(log_returns[:-k], log_returns[k:])[0,1])
                   for k in range(1, 11)]
    max_acf_return = max(abs(x) for x in acf_returns)
    abs_returns = np.abs(log_returns)
    acf_abs = [float(np.corrcoef(abs_returns[:-k], abs_returns[k:])[0,1])
               for k in range(1, 21)]
    negative_count   = int(np.sum(P_real <= 0))
    clamp_count_low  = int(np.sum(P_array == Q8_24_MIN))
    clamp_count_high = int(np.sum(P_array == Q8_24_MAX))
    results = {
        "label":             label,
        "N":                 N,
        "dt":                C["dt"],
        "lr_mean":           lr_mean,
        "lr_std":            lr_std,
        "theo_mean":         theo_mean,
        "theo_std":          theo_std,
        "mean_bias_sigma":   mean_bias_sigma,
        "std_err_frac":      std_err_frac,
        "ks_stat":           float(ks_stat),
        "ks_pval":           float(ks_pval),
        "ks_pass":           bool(ks_pval > 0.01),
        "acf_returns_lag1":  acf_returns[0],
        "acf_returns_max":   max_acf_return,
        "acf_abs_lag1":      acf_abs[0],
        "negative_price_count": negative_count,
        "clamp_low_count":      clamp_count_low,
        "clamp_high_count":     clamp_count_high,
        "G_KS_PASS":   bool(ks_pval > 0.01),
        "G_ACF_PASS":  bool(max_acf_return < 0.05),
        "G_SAFE_PASS": bool(negative_count == 0),
        "G_BIAS_PASS": bool(mean_bias_sigma < 0.10),
    }
    return results

def print_test_results(res):
    print(f"\n  {'─'*60}")
    print(f"  Statistical Test Results: {res['label']}")
    print(f"  {'─'*60}")
    print(f"  N = {res['N']:,}  dt = {res['dt']:.4e}")
    print(f"\n  Log-return mean:  {res['lr_mean']:.4e}  (theory: {res['theo_mean']:.4e})  "
          f"bias = {res['mean_bias_sigma']:.4f} sigma")
    print(f"  Log-return std:   {res['lr_std']:.6f}  (theory: {res['theo_std']:.6f})  "
          f"err = {res['std_err_frac']*100:.3f}%")
    print(f"\n  KS test:          stat={res['ks_stat']:.4f}  p={res['ks_pval']:.4f}  "
          f"[{'PASS' if res['G_KS_PASS'] else 'FAIL'}]")
    print(f"  Max |ACF| ret:    {res['acf_returns_max']:.4f}  "
          f"[{'PASS' if res['G_ACF_PASS'] else 'FAIL'}]")
    print(f"  ACF |ret| lag-1:  {res['acf_abs_lag1']:.4f}")
    print(f"  Negative prices:  {res['negative_price_count']}  "
          f"[{'PASS' if res['G_SAFE_PASS'] else 'FAIL'}]")
    print(f"  Clamp-low:        {res['clamp_low_count']}")
    print(f"  Clamp-high:       {res['clamp_high_count']}")
    overall = all([res["G_KS_PASS"], res["G_ACF_PASS"], res["G_SAFE_PASS"], res["G_BIAS_PASS"]])
    print(f"\n  OVERALL: {'PASS' if overall else 'REVIEW REQUIRED'}")

# Bit-exact comparison 
def compare_with_modelsim(sim_csv_path, Z_int_array, C, dut="euler"):
    print(f"\n  Loading ModelSim output: {sim_csv_path}")
    sim_prices = []
    sim_sigmas = []
    with open(sim_csv_path, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            sim_prices.append(int(row["price_out_hex"], 16))
            sim_sigmas.append(int(row["sigma_out_hex"], 16))
    N_sim = len(sim_prices)
    print(f"  Loaded {N_sim} ticks. DUT={dut}")
    P_gold, sigma_gold = run_simulation(Z_int_array[:N_sim], C, FEEDBACK_EN, dut=dut)
    match_P = match_S = 0
    first_mm_P = first_mm_S = None
    for i in range(N_sim):
        gp, gs = int(P_gold[i+1]), int(sigma_gold[i+1])
        sp, ss = sim_prices[i], sim_sigmas[i]
        if gp == sp:
            match_P += 1
        elif first_mm_P is None:
            first_mm_P = (i+1, gp, sp)
        if gs == ss:
            match_S += 1
        elif first_mm_S is None:
            first_mm_S = (i+1, gs, ss)
    for i in range(N_sim):
        gs = int(sigma_gold[i+1])
        ss = sim_sigmas[i]
        if gs != ss:
            print(f"\n  First sigma divergence tick {i+1}: "
                  f"golden={gs:#010x} sim={ss:#010x}  delta={gs-ss}")
            for j in range(max(0, i-2), min(N_sim, i+3)):
                print(f"    tick {j+1}: "
                      f"gold_sigma={int(sigma_gold[j+1]):#010x} "
                      f"sim_sigma={sim_sigmas[j]:#010x} "
                      f"gold_P={int(P_gold[j+1]):#010x} "
                      f"sim_P={sim_prices[j]:#010x}")
            break
    print(f"\n  Price bit-exact: {match_P}/{N_sim}")
    print(f"  Sigma bit-exact: {match_S}/{N_sim}")
    if first_mm_P:
        t, g, s = first_mm_P
        print(f"  First price mismatch tick {t}: "
              f"golden=0x{g:08X} ({from_fixed(g, PRICE_FRAC):.4f}), "
              f"sim=0x{s:08X} ({from_fixed(s, PRICE_FRAC):.4f})")
    if first_mm_S:
        t, g, s = first_mm_S
        print(f"  First sigma mismatch tick {t}: golden=0x{g:08X}, sim=0x{s:08X}")
    bw = min(BITEXACT_TICKS, N_sim)
    p_exact = all(int(P_gold[i+1]) == sim_prices[i] for i in range(bw))
    s_exact = all(int(sigma_gold[i+1]) == sim_sigmas[i] for i in range(bw))
    print(f"\n  Bit-exact first {bw} ticks — Price: {'PASS' if p_exact else 'FAIL'}  "
          f"Sigma: {'PASS' if s_exact else 'FAIL'}")
    return p_exact and s_exact

# CSV / hex export 
def export_reference_csv(P_array, sigma_array, Z_int_array,
                         filename="gbm_golden_reference.csv"):
    N = min(len(P_array) - 1, N_GENERATE)
    print(f"\n  Exporting reference CSV: {filename} ({N} ticks)")
    with open(filename, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["tick", "z_int_q412", "price_int_q824",
                         "sigma_int_q824", "price_real", "sigma_real"])
        for i in range(N):
            writer.writerow([
                i + 1,
                int(Z_int_array[i]),
                int(P_array[i+1]),
                int(sigma_array[i+1]),
                f"{from_fixed(int(P_array[i+1]), PRICE_FRAC):.8f}",
                f"{from_fixed(int(sigma_array[i+1]), SIGMA_FRAC):.8f}",
            ])

def export_z_hex(Z_int_array, filename=None):
    if filename is None:
        filename = os.path.join(SIM_DIR, "z_samples.hex")
    print(f"  Exporting Z samples for $readmemh: {filename}")
    with open(filename, "w") as f:
        for z in Z_int_array:
            f.write(f"{int(z) & 0xFFFF:04X}\n")
    print(f"  Written {len(Z_int_array)} samples.")

# Plotting 
def make_plots(P_array, sigma_array, Z_int_array, C, P_float=None, sig_float=None,
               label="Golden Model"):
    P_real   = P_array / (1 << PRICE_FRAC)
    sig_real = sigma_array / (1 << SIGMA_FRAC)
    N        = len(P_real) - 1
    N_plot   = min(N, 20_000)
    ticks    = np.arange(N_plot + 1)
    log_returns = np.diff(np.log(np.maximum(P_real, 1e-10)))
    abs_returns = np.abs(log_returns)
    fig, axes = plt.subplots(3, 2, figsize=(14, 15))
    fig.suptitle(f"GBM Golden Model - {label}\n"
                 f"Q8.24 price, Q8.24 sigma, Q4.12 Z, dt={C['dt']:.2e}",
                 fontsize=12, fontweight="bold")
    ax = axes[0, 0]
    ax.plot(ticks, P_real[:N_plot+1], lw=0.8, color="#185FA5")
    if P_float is not None:
        ax.plot(ticks, P_float[:N_plot+1], lw=0.8, color="#D85A30",
                alpha=0.7, linestyle="--", label="Float64")
        ax.legend(fontsize=9)
    ax.set_title("Price trace (Q8.24)", fontsize=11)
    ax.set_xlabel("Tick")
    ax.set_ylabel("Price ($)")
    ax.grid(True, alpha=0.3)
    ax = axes[0, 1]
    ax.plot(ticks, sig_real[:N_plot+1], lw=0.8, color="#1D9E75")
    ax.set_title("Volatility sigma (Q8.24 EMA)", fontsize=11)
    ax.set_xlabel("Tick")
    ax.set_ylabel("sigma per tick")
    ax.grid(True, alpha=0.3)
    ax = axes[1, 0]
    lr_sample = log_returns[:min(N, 500_000)]
    bins = np.linspace(np.percentile(lr_sample, 0.1),
                       np.percentile(lr_sample, 99.9), 100)
    ax.hist(lr_sample, bins=bins, density=True, color="#185FA5", alpha=0.7,
            label="Empirical")
    x = np.linspace(bins[0], bins[-1], 300)
    ax.plot(x, stats.norm.pdf(x, C["mu_ito_t"], C["sigma_t"]),
            lw=2, color="#D85A30", label="Theory")
    ax.set_title("Log-return distribution", fontsize=11)
    ax.set_xlabel("Log-return per tick")
    ax.set_ylabel("Density")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax = axes[1, 1]
    lags = range(1, 21)
    acf_r  = [np.corrcoef(log_returns[:-k], log_returns[k:])[0,1] for k in lags]
    acf_ar = [np.corrcoef(abs_returns[:-k],  abs_returns[k:])[0,1] for k in lags]
    ax.bar([l-0.2 for l in lags], acf_r,  width=0.35, color="#185FA5",
           alpha=0.8, label="ACF returns")
    ax.bar([l+0.2 for l in lags], acf_ar, width=0.35, color="#1D9E75",
           alpha=0.8, label="ACF |returns|")
    ax.axhline(0,     color="black",   lw=0.8)
    ax.axhline( 0.05, color="#D85A30", lw=1, linestyle="--", alpha=0.7)
    ax.axhline(-0.05, color="#D85A30", lw=1, linestyle="--", alpha=0.7)
    ax.set_title("Autocorrelation", fontsize=11)
    ax.set_xlabel("Lag (ticks)")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax = axes[2, 0]
    sigma_t    = C["sigma_t"]
    thresholds = np.linspace(0.5, 5.0, 50)
    ax.semilogy(thresholds,
                [np.mean(np.abs(log_returns) > k*sigma_t) for k in thresholds],
                lw=1.5, color="#185FA5", label="Empirical")
    ax.semilogy(thresholds,
                [2*(1-stats.norm.cdf(k)) for k in thresholds],
                lw=1.5, color="#D85A30", linestyle="--", label="Theory")
    ax.set_title("Tail probability (log scale)", fontsize=11)
    ax.set_xlabel("Threshold (sigma)")
    ax.set_ylabel("P(|Z| > k*sigma)")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3, which="both")
    ax = axes[2, 1]
    N_clust = min(N, 5000)
    ax.plot(range(N_clust), log_returns[:N_clust], lw=0.5, color="#185FA5", alpha=0.8)
    ax.set_title("Log-returns (volatility clustering)", fontsize=11)
    ax.set_xlabel("Tick")
    ax.set_ylabel("Log-return")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    outfile = f"gbm_golden_plots_{label.replace(' ', '_')}.png"
    plt.savefig(outfile, dpi=150, bbox_inches="tight")
    print(f"  Plots saved to {outfile}")

# Modes 
def mode_validate(dut="euler"):
    print("\n" + "#"*70)
    print(f"#  GBM GOLDEN MODEL - Standalone Validation ({dut.upper()})")
    print("#"*70)
    C = build_constants(DT)
    print(f"\n  Constants:")
    print(f"    dt           = {C['dt']:.4e}")
    print(f"    sigma_tick   = {C['sigma_t']:.4e}")
    print(f"    mu_ito_tick  = {C['mu_ito_t']:.4e}")
    print(f"    mu_ito_fp    = 0x{C['mu_ito_fp'] & 0xFFFFFFFF:08X}")
    print(f"    sigma_init   = 0x{C['sigma_init_fp']:08X}  "
          f"({from_fixed(C['sigma_init_fp'], SIGMA_FRAC):.6f})")
    print(f"    alpha_fp     = 0x{C['alpha_fp']:08X}  "
          f"({from_fixed(C['alpha_fp'], SIGMA_FRAC):.6f})")
    print(f"    P0_recip     = 0x{C['P0_recip_fp']:08X}")
    rng    = np.random.default_rng(RNG_SEED)
    Z_real = rng.standard_normal(N_VALIDATE)
    Z_int  = np.array([quantize_z(z) for z in Z_real], dtype=np.int64)
    print(f"\n  Running fixed-point simulation ({N_VALIDATE:,} ticks, dut={dut})...")
    P_array, sigma_array = run_simulation(Z_int, C, FEEDBACK_EN, dut=dut)
    print(f"  Running float64 reference...")
    P_float, sig_float = run_float_reference(Z_real, C)
    res = run_statistical_tests(P_array, sigma_array, C,
                                label=f"Q8.24 Fixed-Point ({dut})")
    print_test_results(res)
    P_real = P_array / (1 << PRICE_FRAC)
    rmse   = np.sqrt(np.mean((P_float - P_real)**2))
    print(f"\n  RMSE vs float64: {rmse:.6f}  ({rmse/P0_REAL*100:.4f}% of P0)")
    with open(f"gbm_golden_stats_{dut}.json", "w") as f:
        json.dump(res, f, indent=2)
    print(f"  Stats saved to gbm_golden_stats_{dut}.json")
    make_plots(P_array, sigma_array, Z_int, C, P_float, sig_float,
               label=f"Fixed-Point {dut}")
    export_reference_csv(P_array, sigma_array, Z_int,
                         filename=f"gbm_golden_reference_{dut}.csv")

def mode_generate(z_csv_path=None, dut="euler"):
    print("\n" + "#"*70)
    print(f"#  GBM GOLDEN MODEL - Reference CSV Generation ({dut.upper()})")
    print("#"*70)
    C = build_constants(DT)
    if z_csv_path and os.path.exists(z_csv_path):
        print(f"\n  Loading Z samples from: {z_csv_path}")
        z_vals = []
        with open(z_csv_path, "r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                z_vals.append(int(row.get("z_q412", row.get("sample", 0))))
        Z_int = np.array(z_vals[:N_GENERATE], dtype=np.int64)
        print(f"  Loaded {len(Z_int)} Z samples.")
    else:
        print(f"\n  Generating fresh Gaussian samples (seed=0x{RNG_SEED:08X})...")
        rng   = np.random.default_rng(RNG_SEED)
        Z_real = rng.standard_normal(N_GENERATE)
        Z_int  = np.array([quantize_z(z) for z in Z_real], dtype=np.int64)
    print(f"  Running simulation ({len(Z_int):,} ticks, dut={dut})...")
    P_array, sigma_array = run_simulation(Z_int, C, FEEDBACK_EN, dut=dut)
    export_reference_csv(P_array, sigma_array, Z_int,
                         filename=f"gbm_golden_reference_{dut}.csv")
    export_z_hex(Z_int)
    print(f"\n  Done. Use z_samples.hex with $readmemh in your testbench.")

def mode_compare(z_csv_path, sim_csv_path, dut="euler"):
    print("\n" + "#"*70)
    print(f"#  GBM GOLDEN MODEL - Bit-Exact Comparison ({dut.upper()})")
    print("#"*70)
    C = build_constants(DT)
    if not z_csv_path or not os.path.exists(z_csv_path):
        print(f"ERROR: Z sample CSV not found: {z_csv_path}")
        sys.exit(1)
    z_vals = []
    with open(z_csv_path, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            z_vals.append(int(row.get("z_int_q412", row.get("z_q412", 0))))
    Z_int  = np.array(z_vals, dtype=np.int64)
    passed = compare_with_modelsim(sim_csv_path, Z_int, C, dut=dut)
    sys.exit(0 if passed else 1)

def mode_compare_both(z_csv_path=None):
    """Run both architectures on same Z inputs and produce comparison plots."""
    print("\n" + "#"*70)
    print("#  GBM GOLDEN MODEL - Architecture Comparison")
    print("#"*70)

    C = build_constants(DT)

    ref_csv = z_csv_path if (z_csv_path and os.path.exists(z_csv_path)) \
              else "gbm_golden_reference_euler.csv"
    print(f"  Loading Z samples from {ref_csv}...")
    z_vals = []
    with open(ref_csv, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            z_vals.append(int(row.get("z_int_q412", row.get("z_q412", 0))))
    Z_int = np.array(z_vals[:N_GENERATE], dtype=np.int64)
    print(f"  Loaded {len(Z_int)} Z samples.")

    print("  Running Euler simulation...")
    P_euler, sigma_euler = run_simulation(Z_int, C, FEEDBACK_EN, dut="euler")

    print("  Running Log-Space simulation...")
    P_log, sigma_log = run_simulation(Z_int, C, FEEDBACK_EN, dut="logspace")

    print("  Running Float64 reference...")
    Z_real_ref = np.array([from_fixed(int(z), Z_FRAC) for z in Z_int])
    P_float, sig_float = run_float_reference(Z_real_ref, C)

    res_euler = run_statistical_tests(P_euler, sigma_euler, C,
                                      label="Euler-Maruyama Q8.24")
    res_log   = run_statistical_tests(P_log,   sigma_log,   C,
                                      label="Log-Space Q8.24")

    print("\n  ── Euler-Maruyama ──")
    print_test_results(res_euler)
    print("\n  ── Log-Space ──")
    print_test_results(res_log)

    with open("gbm_comparison_stats.json", "w", encoding="utf-8") as f:
        json.dump({"euler": res_euler, "logspace": res_log}, f, indent=2)
    print("\n  Stats saved to gbm_comparison_stats.json")

    make_comparison_plots(P_euler, sigma_euler, P_log, sigma_log,
                          P_float, sig_float, Z_int, C)


def make_comparison_plots(P_euler, sigma_euler, P_log, sigma_log,
                          P_float, sig_float, Z_int_array, C):
    P_euler_r = P_euler / (1 << PRICE_FRAC)
    P_log_r   = P_log   / (1 << PRICE_FRAC)
    sig_e_r   = sigma_euler / (1 << SIGMA_FRAC)
    sig_l_r   = sigma_log   / (1 << SIGMA_FRAC)

    N         = len(P_euler_r) - 1
    N_macro   = min(N, 1_000_000)
    N_micro   = min(N, 50_000)
    N_vol     = min(N, 50_000)
    N_sig     = min(N, 5_000)

    ticks_macro = np.arange(N_macro + 1)
    ticks_micro = np.arange(N_micro + 1)
    ticks_vol   = np.arange(N_vol + 1)
    ticks_sig   = np.arange(N_sig + 1)

    lr_euler = np.diff(np.log(np.maximum(P_euler_r, 1e-10)))
    lr_log   = np.diff(np.log(np.maximum(P_log_r,   1e-10)))

    fig, axes = plt.subplots(3, 2, figsize=(15, 16))
    fig.suptitle("GBM Architecture Comparison: Euler-Maruyama vs Log-Space\n"
                 "Q8.24 Fixed-Point, 1M ticks, Gaussian Z inputs",
                 fontsize=14, fontweight="bold")

    # Panel 1: Full Price Trace
    ax = axes[0, 0]
    ax.plot(ticks_macro, P_euler_r[:N_macro+1], lw=0.8, color="#D85A30", alpha=0.8, label="Euler-Maruyama")
    ax.plot(ticks_macro, P_log_r[:N_macro+1],   lw=0.8, color="#185FA5", alpha=0.8, label="Log-Space")
    ax.plot(ticks_macro, P_float[:N_macro+1],   lw=1.0, color="#2C2C2A", alpha=0.35, linestyle="--", label="Float64 ref")
    ax.set_ylim(97, 108)
    ax.set_title("MACRO: Price Trace (Full 1M Ticks)", fontsize=11, fontweight='bold')
    ax.set_xlabel("Tick")
    ax.set_ylabel("Price ($)")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 2: Cumulative Price Error (log scale)
    ax = axes[0, 1]
    cum_err_euler = np.abs(P_euler_r[:N_macro+1] - P_float[:N_macro+1])
    cum_err_log   = np.abs(P_log_r[:N_macro+1]   - P_float[:N_macro+1])
    cum_err_euler = np.maximum(cum_err_euler, 1e-6)
    cum_err_log   = np.maximum(cum_err_log,   1e-6)
    ax.plot(ticks_macro, cum_err_euler, lw=0.8, color="#D85A30", alpha=0.8, label="Euler-Maruyama")
    ax.plot(ticks_macro, cum_err_log,   lw=0.8, color="#185FA5", alpha=0.8, label="Log-Space")
    ax.set_yscale('log')
    ax.set_title("MACRO: Absolute Price Error vs Float64 (Log Scale)", fontsize=11, fontweight='bold')
    ax.set_xlabel("Tick")
    ax.set_ylabel("Absolute Error ($) — Log Scale")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3, which="both")

    # Panel 3: Micro Price Trace
    ax = axes[1, 0]
    ax.plot(ticks_micro, P_euler_r[:N_micro+1], lw=0.8, color="#D85A30", alpha=0.8, label="Euler-Maruyama")
    ax.plot(ticks_micro, P_log_r[:N_micro+1],   lw=0.8, color="#185FA5", alpha=0.8, label="Log-Space")
    ax.plot(ticks_micro, P_float[:N_micro+1],   lw=1.0, color="#2C2C2A", alpha=0.35, linestyle="--", label="Float64 ref")
    ax.set_title("MICRO: Price Trace (First 50k Ticks) — Note LUT Quantization", fontsize=11, fontweight='bold')
    ax.set_xlabel("Tick")
    ax.set_ylabel("Price ($)")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 4: Volatility Sigma 
    ax = axes[1, 1]
    ax.plot(ticks_sig, sig_e_r[:N_sig+1],   lw=0.5, color="#D85A30", alpha=0.6, label="Euler-Maruyama")
    ax.plot(ticks_sig, sig_l_r[:N_sig+1],   lw=0.5, color="#185FA5", alpha=0.6, label="Log-Space")
    ax.plot(ticks_sig, sig_float[:N_sig+1], lw=2.0, color="#2C2C2A", alpha=1.0, label="Float64 ref")
    ax.set_title("MICRO: Volatility Sigma (First 5k Ticks) — Note EMA Sawtooth", fontsize=11, fontweight='bold')
    ax.set_xlabel("Tick")
    ax.set_ylabel("Sigma per tick")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 5: Short-term Absolute Deviation
    ax = axes[2, 0]
    dev_euler = np.abs(P_euler_r[:N_vol+1] - P_float[:N_vol+1])
    dev_log   = np.abs(P_log_r[:N_vol+1]   - P_float[:N_vol+1])
    ax.plot(ticks_vol, dev_euler, lw=0.5, color="#D85A30", alpha=0.6, label="Euler-Maruyama")
    ax.plot(ticks_vol, dev_log,   lw=0.5, color="#185FA5", alpha=0.6, label="Log-Space")
    ax.set_title("MICRO: Absolute Deviation from Ref (First 50k Ticks)", fontsize=11, fontweight='bold')
    ax.set_xlabel("Tick")
    ax.set_ylabel("|P_fixed - P_float| ($)")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 6: Zoomed price trace around Euler divergence point
    ax = axes[2, 1]
    N_zoom_start = 150_000
    N_zoom_end   = min(N, 170_000)
    ticks_zoom   = np.arange(N_zoom_start, N_zoom_end + 1)
    ax.plot(ticks_zoom, P_euler_r[N_zoom_start:N_zoom_end+1], lw=1.0, color="#D85A30", alpha=0.9, label="Euler-Maruyama")
    ax.plot(ticks_zoom, P_log_r[N_zoom_start:N_zoom_end+1],   lw=1.0, color="#185FA5", alpha=0.9, label="Log-Space")
    ax.plot(ticks_zoom, P_float[N_zoom_start:N_zoom_end+1],   lw=1.0, color="#2C2C2A", alpha=0.35, linestyle="--", label="Float64 ref")
    ax.set_title("ZOOM: Euler Divergence Region (Ticks 150k–170k)", fontsize=11, fontweight='bold')
    ax.set_xlabel("Tick")
    ax.set_ylabel("Price ($)")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    plt.tight_layout(rect=[0, 0.03, 1, 0.96])
    plt.savefig("gbm_architecture_comparison.png", dpi=150, bbox_inches="tight", facecolor='white')
    print("  Comparison plots saved to gbm_architecture_comparison.png")

# Main 
def main():
    global DT
    parser = argparse.ArgumentParser(description="GBM Fixed-Point Golden Model")
    parser.add_argument("--mode",
                        choices=["validate", "generate", "compare", "compare_both"],
                        default="validate")
    parser.add_argument("--dut", choices=["euler", "logspace"], default="euler",
                        help="Architecture: euler or logspace")
    parser.add_argument("--z_csv",   default=None)
    parser.add_argument("--sim_csv", default=None)
    parser.add_argument("--dt", type=float, default=None)
    args = parser.parse_args()
    if args.dt is not None:
        DT = args.dt
    if args.mode == "validate":
        mode_validate(dut=args.dut)
    elif args.mode == "generate":
        mode_generate(args.z_csv, dut=args.dut)
    elif args.mode == "compare_both":
        mode_compare_both(args.z_csv)
    elif args.mode == "compare":
        if not args.sim_csv:
            print("ERROR: --mode compare requires --sim_csv")
            sys.exit(1)
        mode_compare(args.z_csv, args.sim_csv, dut=args.dut)

if __name__ == "__main__":
    main()
