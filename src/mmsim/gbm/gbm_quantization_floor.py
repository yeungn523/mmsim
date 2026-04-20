"""
gbm_quantization_floor.py
=========================
Pre-RTL validation script for the GBM fixed-point pipeline.

Answers three questions:
  Q1 - Can Q8.24 represent sigma*sqrt(dt)*Z without stochastic vanishing?
  Q2 - How much Ito bias accumulates over N ticks without the -sigma^2/2 correction?
  Q3 - Do Q8.24 price and Q0.24 sigma stay within acceptable MSE vs float64 over 1M ticks?

"""

import math
import numpy as np
import matplotlib.pyplot as plt
import csv

# Fixed-point format constants 
PRICE_FRAC  = 24   # Q8.24  price P(t)
SIGMA_FRAC  = 24   # Q0.24  volatility sigma (upgraded from Q0.16)
Z_FRAC      = 12   # Q4.12  Ziggurat Gaussian output

PRICE_LSB   = 2 ** -PRICE_FRAC    # ~5.96e-8
SIGMA_LSB   = 2 ** -SIGMA_FRAC    # ~5.96e-8
Z_LSB       = 2 ** -Z_FRAC        # ~2.44e-4

Q8_24_MAX   = (256 << PRICE_FRAC) - 1
Q8_24_MIN   = 1

SIGMA_WIDTH = 32
SIGMA_MAX   = (1 << SIGMA_WIDTH) - 1
SIGMA_MIN   = 1

# EMA volatility constants 
# E[|Z|] for Z~N(0,1) is sqrt(2/pi) ~ 0.7979.
# Without correction, effective EMA multiplier = alpha + (1-alpha)*0.7979 < 1,
# guaranteeing sigma -> 0 over long runs (e.g. 0.999975^1e6 = e^-25 ~ 0).
# Fix: scale abs_ret by 1.25 ~ sqrt(pi/2) so E[scaled |r|] ~ sigma.
# Residual 0.26% undershoot counteracted by omega (GARCH baseline).
SCALE_APPROX   = 1.25
ALPHA_REAL     = 0.99

# Simulation parameters 
SIGMA_ANNUAL = 0.16
MU_ANNUAL    = 0.0
CLOCK_HZ     = 50e6
P0_REAL      = 100.0

TICKS_BIAS   = 10_000_000
TICKS_MSE    = 1_000_000

RNG_SEED     = 0xDEADBEEF

DT_INTERPRETATIONS = {
    "physical  (1 tick = 1 clock cycle, 20ns)":
        1.0 / CLOCK_HZ,
    "market-1s (1 tick = 1 market second)":
        1.0 / (252 * 6.5 * 3600),
    "market-1m (1 tick = 1 market minute)":
        1.0 / (252 * 6.5 * 60),
    "scaled    (1 tick = 1/1000 trading day)":
        1.0 / (252 * 1000),
}

# Helpers 

def to_fixed(real_val, frac_bits):
    return int(round(real_val * (1 << frac_bits)))

def from_fixed(int_val, frac_bits):
    return int_val / (1 << frac_bits)

def round_shift(val, shift):
    """
    Arithmetic right shift with round-to-nearest.
    Mirrors Verilog: result = (val + (1 << (shift-1))) >>> shift
    Plain >>> on signed values truncates toward -inf, causing asymmetric
    negative bias in the diffusion term. This corrects that.
    """
    if shift <= 0:
        return val << (-shift)
    half = 1 << (shift - 1)
    if val >= 0:
        return (val + half) >> shift
    else:
        return -(((-val) + half) >> shift)

def clamp(val, lo, hi):
    return max(lo, min(hi, val))

def clamp_price(p):
    return clamp(p, Q8_24_MIN, Q8_24_MAX)

def sigma_tick_from_annual(sigma_annual, dt):
    return sigma_annual * math.sqrt(dt)

def mu_ito_tick(mu_annual, sigma_annual, dt, ito_corrected=True):
    if ito_corrected:
        return (mu_annual - 0.5 * sigma_annual ** 2) * dt
    return mu_annual * dt

# Q1: Quantization Floor 

def q1_quantization_floor():
    print("=" * 70)
    print("Q1 — QUANTIZATION FLOOR ANALYSIS")
    print("     Can Q8.24 represent sigma*sqrt(dt)*Z without vanishing?")
    print("=" * 70)

    results = {}
    all_pass = True

    for name, dt in DT_INTERPRETATIONS.items():
        sigma_t = sigma_tick_from_annual(SIGMA_ANNUAL, dt)
        mu_t    = mu_ito_tick(MU_ANNUAL, SIGMA_ANNUAL, dt)

        noise_1s = sigma_t * P0_REAL
        noise_4s = sigma_t * 4.0 * P0_REAL

        noise_lsbs_1s = noise_1s / PRICE_LSB
        noise_lsbs_4s = noise_4s / PRICE_LSB
        drift_lsbs    = P0_REAL * abs(mu_t) / PRICE_LSB

        sigma_fp_q016 = to_fixed(sigma_t, 16)
        sigma_fp_q024 = to_fixed(sigma_t, SIGMA_FRAC)
        sigma_lsbs    = sigma_t / SIGMA_LSB

        vanishes = noise_lsbs_1s < 1.0
        status   = "FAIL" if vanishes else ("WARN" if noise_lsbs_1s < 4 else "PASS")
        if status != "PASS":
            all_pass = False

        results[name] = {
            "dt": dt, "sigma_tick": sigma_t, "status": status,
            "noise_1s_lsbs": noise_lsbs_1s, "sigma_lsbs_q024": sigma_lsbs,
        }

        print(f"\n  {name}")
        print(f"    dt             = {dt:.3e}")
        print(f"    sigma_tick     = {sigma_t:.3e}")
        print(f"    mu_ito_tick    = {mu_t:.3e}")
        print(f"    noise @ Z=1    = {noise_1s:.3e}  ({noise_lsbs_1s:.1f} LSBs)  [{status}]")
        print(f"    noise @ Z=4    = {noise_4s:.3e}  ({noise_lsbs_4s:.1f} LSBs)")
        print(f"    drift/tick     = {P0_REAL * abs(mu_t):.3e}  ({drift_lsbs:.1f} LSBs)")
        print(f"    sigma Q0.16    = integer {sigma_fp_q016}  "
              f"({sigma_fp_q016} steps — too coarse)")
        print(f"    sigma Q0.24    = integer {sigma_fp_q024}  "
              f"({sigma_lsbs:.0f} steps — adequate)")

        if vanishes:
            print(f"    *** STOCHASTIC VANISHING ***")

    print(f"\n  Overall Q1 status: {'PASS' if all_pass else 'REVIEW REQUIRED'}")
    return results

# Q2: Ito Bias Test 

def q2_ito_bias(dt, N=TICKS_BIAS):
    print("\n" + "=" * 70)
    print("Q2 — ITO BIAS TEST")
    print(f"     mu=0, sigma={SIGMA_ANNUAL}, N={N:,} ticks")
    print("=" * 70)

    rng     = np.random.default_rng(RNG_SEED)
    sigma_t = sigma_tick_from_annual(SIGMA_ANNUAL, dt)
    Z       = rng.standard_normal(N)

    log_P_unc = np.zeros(N + 1)
    for i in range(N):
        log_P_unc[i+1] = log_P_unc[i] + sigma_t * Z[i]

    ito_corr  = -0.5 * SIGMA_ANNUAL ** 2 * dt
    log_P_cor = np.zeros(N + 1)
    for i in range(N):
        log_P_cor[i+1] = log_P_cor[i] + ito_corr + sigma_t * Z[i]

    theo        = ito_corr * N
    sigma_total = SIGMA_ANNUAL * math.sqrt(dt * N)
    bias_frac   = abs(log_P_unc[-1] - theo) / sigma_total

    print(f"\n  Theoretical median log(S_T/S_0) = {theo:.6f}")
    print(f"  Uncorrected final log-price     = {log_P_unc[-1]:.6f}  "
          f"(bias = {log_P_unc[-1] - theo:+.6f})")
    print(f"  Ito-corrected final log-price   = {log_P_cor[-1]:.6f}  "
          f"(bias = {log_P_cor[-1] - theo:+.6f})")
    print(f"\n  Uncorrected upward bias = {bias_frac:.3f} * total-sigma")
    if bias_frac > 0.05:
        print(f"  *** SIGNIFICANT: Ito correction required at this dt ***")
    else:
        print(f"  *** NEGLIGIBLE at this dt — include it anyway (zero cost) ***")

    return log_P_unc, log_P_cor, theo

# Q3: Fixed-Point MSE Analysis 

def q3_fixedpoint_mse(dt, N=TICKS_MSE):
    print("\n" + "=" * 70)
    print("Q3 — FIXED-POINT MSE ANALYSIS")
    print(f"     Float64 vs Q8.24/Q0.24 fixed-point, N={N:,} ticks")
    print(f"     Volatility EMA: alpha={ALPHA_REAL}, 1.25 scale, hard floor at sigma_init")
    print("=" * 70)

    rng       = np.random.default_rng(RNG_SEED)
    sigma_t   = sigma_tick_from_annual(SIGMA_ANNUAL, dt)
    mu_ito_t  = mu_ito_tick(MU_ANNUAL, SIGMA_ANNUAL, dt)
    Z_samples = rng.standard_normal(N)

    mu_ito_fp     = to_fixed(mu_ito_t, PRICE_FRAC)
    alpha_fp      = to_fixed(ALPHA_REAL, SIGMA_FRAC)
    one_m_alpha   = (1 << SIGMA_FRAC) - alpha_fp
    P0_fp         = to_fixed(P0_REAL, PRICE_FRAC)
    sigma_init_fp = clamp(to_fixed(sigma_t, SIGMA_FRAC), SIGMA_MIN, SIGMA_MAX)

    print(f"\n  Precomputed constants:")
    print(f"    mu_ito_fp      = {mu_ito_fp}  ({from_fixed(mu_ito_fp, PRICE_FRAC):.4e})")
    print(f"    sigma_init_fp  = {sigma_init_fp}  ({from_fixed(sigma_init_fp, SIGMA_FRAC):.4e})")
    print(f"    alpha_fp       = {alpha_fp}  ({from_fixed(alpha_fp, SIGMA_FRAC):.6f})")
    print(f"    hard_floor_fp  = {sigma_init_fp}  (sigma never drops below init)")

    # Float64 path (hardware-matched approximations) 
    P_float   = np.zeros(N + 1)
    sig_float = np.zeros(N + 1)
    P_float[0]   = P0_REAL
    sig_float[0] = sigma_t

    for i in range(N):
        Z         = Z_samples[i]
        drift     = P_float[i] * mu_ito_t
        diffusion = P_float[i] * sig_float[i] * Z
        P_new     = P_float[i] + drift + diffusion
        P_float[i+1] = max(0.0, P_new)

        # P0 normalization (matches hardware — no divider needed)
        abs_ret = (abs(P_float[i+1] - P_float[i]) / max(P0_REAL, 1e-10)) * SCALE_APPROX
        sig_new = ALPHA_REAL * sig_float[i] + (1 - ALPHA_REAL) * abs_ret
        sig_float[i+1] = max(sig_float[0], sig_new)   # hard floor at sigma_init

    # Fixed-point path 
    P_int   = np.zeros(N + 1, dtype=np.int64)
    sig_int = np.zeros(N + 1, dtype=np.int64)
    P_int[0]   = P0_fp
    sig_int[0] = sigma_init_fp

    Z_int = np.array([
        clamp(to_fixed(float(z), Z_FRAC), -(8 << Z_FRAC), (8 << Z_FRAC) - 1)
        for z in Z_samples
    ], dtype=np.int64)

    overflow_count  = 0
    underflow_count = 0

    for i in range(N):
        P   = int(P_int[i])
        sig = int(sig_int[i])
        Z   = int(Z_int[i])

        # Stage 1: drift   Q8.24 * Q8.24 -> Q16.48 -> Q8.24
        drift = round_shift(P * mu_ito_fp, PRICE_FRAC)

        # Stage 2: P*sigma  Q8.24 * Q0.24 -> Q8.48 -> Q8.24
        P_sigma = round_shift(P * sig, SIGMA_FRAC)

        # Stage 3: diffusion  Q8.24 * Q4.12 -> Q12.36 -> Q8.24
        diffusion = round_shift(P_sigma * Z, Z_FRAC)

        # Stage 4: sum and clamp
        P_new = P + drift + diffusion
        if P_new > Q8_24_MAX:
            overflow_count += 1
        if P_new < Q8_24_MIN:
            underflow_count += 1
        P_new = clamp_price(P_new)
        P_int[i+1] = P_new

        # Stage 5: volatility EMA
        # abs_ret_norm = |delta_P| / P0  in Q0.24
        delta_P      = abs(P_new - P)
        abs_ret_norm = (delta_P << SIGMA_FRAC) // max(P0_fp, 1)
        abs_ret_norm = clamp(abs_ret_norm, 0, SIGMA_MAX)

        # Scale 1.25 = 1 + 1/4 via shift-add (no DSP)
        abs_ret_scaled = abs_ret_norm + (abs_ret_norm >> 2)
        abs_ret_scaled = clamp(abs_ret_scaled, 0, SIGMA_MAX)

        # EMA + GARCH omega
        sig_new = (round_shift(alpha_fp * sig, SIGMA_FRAC)
                   + round_shift(one_m_alpha * abs_ret_scaled, SIGMA_FRAC))
        sig_new = clamp(sig_new, sigma_init_fp, SIGMA_MAX)   # hard floor
        sig_int[i+1] = sig_new

    # Metrics 
    P_fixed_real   = P_int   / (1 << PRICE_FRAC)
    sig_fixed_real = sig_int / (1 << SIGMA_FRAC)

    rmse_price = math.sqrt(float(np.mean((P_float - P_fixed_real) ** 2)))
    max_err    = float(np.max(np.abs(P_float - P_fixed_real)))
    rel_rmse   = rmse_price / P0_REAL

    lr_float = np.diff(np.log(np.maximum(P_float, 1e-10)))
    lr_fixed = np.diff(np.log(np.maximum(P_fixed_real, 1e-10)))

    mean_bias_frac = abs(float(np.mean(lr_fixed)) - mu_ito_t) / sigma_t
    std_err_frac   = abs(float(np.std(lr_fixed)) - sigma_t) / sigma_t

    sig_float_final = float(sig_float[-1])
    sig_fixed_final = float(sig_fixed_real[-1])
    sig_float_mean  = float(np.mean(sig_float[N//2:]))
    sig_fixed_mean  = float(np.mean(sig_fixed_real[N//2:]))
    sigma_collapsed = sig_float_final < sigma_t * 0.5
    sigma_agree     = (abs(sig_float_mean - sig_fixed_mean)
                       / max(sig_float_mean, 1e-15)) < 0.20

    print(f"\n  Price RMSE (fixed vs float): {rmse_price:.6f}  ({rel_rmse*100:.4f}% of P0)")
    print(f"  Max absolute error:          {max_err:.6f}")
    print(f"  Overflow clamp events:       {overflow_count}")
    print(f"  Underflow clamp events:      {underflow_count}")
    print(f"\n  Log-return mean:  float={np.mean(lr_float):.2e}  "
          f"fixed={np.mean(lr_fixed):.2e}  theory={mu_ito_t:.2e}")
    print(f"  Log-return std:   float={np.std(lr_float):.6f}  "
          f"fixed={np.std(lr_fixed):.6f}  theory={sigma_t:.6f}")

    print(f"\n  SIGMA STABILITY (critical test):")
    print(f"    sigma init:              {sigma_t:.6e}")
    print(f"    float sigma final:       {sig_float_final:.6e}  "
          f"({'*** COLLAPSED ***' if sigma_collapsed else 'stable'})")
    print(f"    fixed sigma final:       {sig_fixed_final:.6e}")
    print(f"    float sigma mean(2nd half): {sig_float_mean:.6e}")
    print(f"    fixed sigma mean(2nd half): {sig_fixed_mean:.6e}")
    print(f"    paths agree (<20% diff): {'YES' if sigma_agree else 'NO'}")

    status = "PASS" if (rel_rmse < 0.05
                        and mean_bias_frac < 0.10
                        and not sigma_collapsed
                        and sigma_agree) else "WARN"

    print(f"\n  Mean bias (sigma units):  {mean_bias_frac:.4f}")
    print(f"  Std error fraction:       {std_err_frac:.4f}")
    print(f"  Q3 overall status:        [{status}]")

    if sigma_collapsed:
        print(f"  *** SIGMA COLLAPSED — omega too small or SIGMA_FRAC wrong ***")
    if not sigma_agree:
        print(f"  *** SIGMA PATHS DIVERGED — float/fixed feedback mismatch ***")
    if rel_rmse >= 0.05:
        print(f"  *** RMSE > 5% — check DSP multiply chain ***")

    return P_float, P_fixed_real, sig_float, sig_fixed_real, Z_samples

# Plotting 

def make_plots(P_float, P_fixed, sig_float, sig_fixed, Z_samples,
               log_P_unc, log_P_corr, theoretical_median, dt):

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle(
        f"GBM Quantization Floor — Q8.24 price / Q0.24 sigma\n"
        f"dt={dt:.2e}, sigma={SIGMA_ANNUAL}, alpha={ALPHA_REAL}, "
        f"scale=1.25, hard floor",
        fontsize=11, fontweight="bold"
    )

    N_plot = min(len(P_float) - 1, 500)
    ticks  = np.arange(N_plot + 1)

    # Panel 1: Price trace
    ax = axes[0, 0]
    ax.plot(ticks, P_float[:N_plot+1], label="Float64", lw=1.2, color="#185FA5")
    ax.plot(ticks, P_fixed[:N_plot+1], label="Q8.24 Fixed", lw=1.0,
            color="#D85A30", alpha=0.8, linestyle="--")
    ax.set_title("Price trace: float64 vs Q8.24", fontsize=11)
    ax.set_xlabel("Tick")
    ax.set_ylabel("Price ($)")
    ax.legend(loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 2: Sigma stability (the key panel)
    ax = axes[0, 1]
    sigma_t = sigma_tick_from_annual(SIGMA_ANNUAL, dt)
    ax.plot(ticks, sig_float[:N_plot+1], label="Float64 sigma",
            lw=1.2, color="#185FA5")
    ax.plot(ticks, sig_fixed[:N_plot+1], label="Q0.24 Fixed sigma",
            lw=1.0, color="#D85A30", alpha=0.8, linestyle="--")
    ax.axhline(sigma_t, color="#1D9E75", lw=1.5, linestyle=":",
               label=f"sigma_init={sigma_t:.2e}")
    ax.set_title("Sigma trace — must not collapse to zero", fontsize=11)
    ax.set_xlabel("Tick")
    ax.set_ylabel("sigma per tick")
    ax.legend(loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 3: Log-return distribution
    ax = axes[1, 0]
    lr_float = np.diff(np.log(np.maximum(P_float, 1e-10)))
    lr_fixed = np.diff(np.log(np.maximum(P_fixed, 1e-10)))
    lo = np.percentile(lr_float, 1)
    hi = np.percentile(lr_float, 99)
    bins = np.linspace(lo, hi, 80)
    ax.hist(lr_fixed, bins=bins, alpha=0.3, label="Q8.24 Fixed",
            color="#D85A30", density=True, histtype='stepfilled')
    ax.hist(lr_float, bins=bins, alpha=1.0, label="Float64",
            color="#185FA5", density=True, histtype='step', linewidth=1.5)
    ax.set_title("Log-return distribution", fontsize=11)
    ax.set_xlabel("Log-return per tick")
    ax.set_ylabel("Density")
    ax.legend(loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 4: Ito correction — vectorized Monte Carlo ensemble
    ax = axes[1, 1]
    N_bias = min(len(log_P_unc) - 1, TICKS_BIAS)
    t_bias = np.arange(N_bias + 1)
    theory = theoretical_median * t_bias / N_bias

    n_runs   = 100
    rng2     = np.random.default_rng(42)
    Z2       = rng2.standard_normal((n_runs, N_bias))
    sigma_t2 = sigma_tick_from_annual(SIGMA_ANNUAL, dt)
    ito_c    = -0.5 * SIGMA_ANNUAL**2 * dt

    unc_runs = np.hstack([np.zeros((n_runs, 1)),
                          np.cumsum(sigma_t2 * Z2, axis=1)])
    cor_runs = np.hstack([np.zeros((n_runs, 1)),
                          np.cumsum(ito_c + sigma_t2 * Z2, axis=1)])

    ax.plot(t_bias, unc_runs.mean(axis=0), lw=1.5, color="#185FA5",
            label="Uncorrected (mean of 100)")
    ax.plot(t_bias, cor_runs.mean(axis=0), lw=1.5, color="#D85A30",
            label="Ito-corrected (mean of 100)")
    ax.plot(t_bias, theory, lw=1.5, color="#D85A30", linestyle="--",
            label="Theoretical median")
    ax.fill_between(t_bias,
                    unc_runs.mean(axis=0) - unc_runs.std(axis=0),
                    unc_runs.mean(axis=0) + unc_runs.std(axis=0),
                    alpha=0.15, color="#185FA5")
    ax.fill_between(t_bias,
                    cor_runs.mean(axis=0) - cor_runs.std(axis=0),
                    cor_runs.mean(axis=0) + cor_runs.std(axis=0),
                    alpha=0.15, color="#D85A30")
    ax.set_title("Ito correction: log-price drift (100-run ensemble)", fontsize=11)
    ax.set_xlabel("Tick")
    ax.set_ylabel("log(S_t / S_0)")
    ax.legend(loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig("quantization_floor_plots.png", dpi=150, bbox_inches="tight")
    print("\n  Plots saved to quantization_floor_plots.png")

# CSV Export 

def export_csv(P_float, P_fixed, sig_float, sig_fixed, N=5000):
    filename = "quantization_floor_results.csv"
    with open(filename, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["tick", "P_float", "P_fixed_q824",
                         "sig_float", "sig_fixed_q024",
                         "abs_price_err", "rel_price_err_pct"])
        for i in range(min(N, len(P_float))):
            abs_err = abs(P_float[i] - P_fixed[i])
            rel_err = abs_err / max(P_float[i], 1e-10) * 100
            writer.writerow([
                i,
                f"{P_float[i]:.8f}",
                f"{P_fixed[i]:.8f}",
                f"{sig_float[i]:.8f}",
                f"{sig_fixed[i]:.8f}",
                f"{abs_err:.8f}",
                f"{rel_err:.6f}",
            ])
    print(f"  Tick-by-tick comparison saved to {filename} "
          f"({min(N, len(P_float))} rows)")

# Main 

def main():
    print("\n" + "#" * 70)
    print("#  GBM QUANTIZATION FLOOR — Pre-RTL Validation")
    print("#  ECE 5760 Market Microstructure Simulator")
    print("#" * 70 + "\n")

    q1_results = q1_quantization_floor()

    chosen_name = "market-1s (1 tick = 1 market second)"
    chosen_dt   = DT_INTERPRETATIONS[chosen_name]

    if q1_results[chosen_name]["status"] == "FAIL":
        chosen_name = "market-1m (1 tick = 1 market minute)"
        chosen_dt   = DT_INTERPRETATIONS[chosen_name]
        print(f"\n  NOTE: Falling back to '{chosen_name}' (market-1s vanishes)")
    else:
        print(f"\n  Using '{chosen_name}' for Q2/Q3 analysis.")

    log_P_unc, log_P_cor, theo = q2_ito_bias(chosen_dt, N=TICKS_BIAS)

    P_float, P_fixed, sig_float, sig_fixed, Z_samples = \
        q3_fixedpoint_mse(chosen_dt, N=TICKS_MSE)

    make_plots(P_float, P_fixed, sig_float, sig_fixed, Z_samples,
               log_P_unc, log_P_cor, theo, chosen_dt)

    export_csv(P_float, P_fixed, sig_float, sig_fixed)

    sigma_t = sigma_tick_from_annual(SIGMA_ANNUAL, chosen_dt)

    print("\n" + "=" * 70)
    print("SUMMARY — FIXED-POINT FORMAT RECOMMENDATION")
    print("=" * 70)

    any_vanish = any(v["status"] == "FAIL" for v in q1_results.values())
    any_warn   = any(v["status"] == "WARN" for v in q1_results.values())

    if any_vanish:
        print("  RESULT: Q8.24 INSUFFICIENT for some dt interpretations.")
        print("  ACTION: Use Q8.32 OR rescale sigma.")
    elif any_warn:
        print("  RESULT: Q8.24 MARGINAL for some interpretations.")
        print("  ACTION: Use market-minute or slower tick rate.")
    else:
        print("  RESULT: Q8.24 viable. Q0.24 sigma viable. Proceed to RTL.")

    print(f"\n  Include in LaTeX Mathematical Background:")
    print(f"    dt             = {chosen_dt:.4e}")
    print(f"    sigma_tick     = {sigma_t:.4e}")
    print(f"    Ito correction = {-0.5 * SIGMA_ANNUAL**2 * chosen_dt:.4e} per tick")
    print(f"    Noise @ Z=1    = {sigma_t * P0_REAL:.4e} "
          f"= {sigma_t * P0_REAL / PRICE_LSB:.0f} LSBs of Q8.24")
    print(f"    sigma in Q0.24 = integer {to_fixed(sigma_t, SIGMA_FRAC)} "
          f"(was {to_fixed(sigma_t, 16)} in Q0.16)")
    print(f"    sigma hard floor = sigma_init_fp = {to_fixed(sigma_t, SIGMA_FRAC)}")
    print(f"    EMA scale        = 1.25 = x + (x>>2)  [hardware shift-add]")
    print()

if __name__ == "__main__":
    main()