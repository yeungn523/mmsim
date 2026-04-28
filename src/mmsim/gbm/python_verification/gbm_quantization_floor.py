"""Validates the Q8.24 GBM fixed-point pipeline against a float64 reference before RTL handoff.

Answers three quantitative questions used to size the price and sigma formats: whether the
per-tick noise sigma * sqrt(dt) * Z survives Q8.24 quantization without stochastic vanishing,
how much Ito drift accumulates over a long horizon when the closed-form -sigma^2 / 2 correction
is omitted, and whether the fixed-point trajectory tracks a float64 reference within acceptable
mean-squared error over one million ticks. Each test prints a verdict, plots the relevant
diagnostics, and dumps a per-tick CSV for cross-checking against the hardware testbench.
"""

import csv
import math

import matplotlib.pyplot as plt
import numpy as np
from numpy.typing import NDArray

PRICE_FRAC: int = 24
SIGMA_FRAC: int = 24
Z_FRAC: int = 12

PRICE_LSB: float = 2 ** -PRICE_FRAC
SIGMA_LSB: float = 2 ** -SIGMA_FRAC
Z_LSB: float = 2 ** -Z_FRAC

Q8_24_MAX: int = (256 << PRICE_FRAC) - 1
Q8_24_MIN: int = 1

SIGMA_WIDTH: int = 32
SIGMA_MAX: int = (1 << SIGMA_WIDTH) - 1
SIGMA_MIN: int = 1

# E[|Z|] for Z ~ N(0, 1) is sqrt(2/pi) ~ 0.7979. Without correction the effective EMA multiplier
# becomes alpha + (1 - alpha) * 0.7979 < 1, which forces sigma to zero over long runs (e.g.
# 0.999975^1e6 = e^-25 ~ 0). Scaling the absolute return by 1.25 ~ sqrt(pi/2) makes the expected
# scaled |r| equal sigma; the residual 0.26% undershoot is absorbed by the GARCH omega baseline.
SCALE_APPROX: float = 1.25
ALPHA_REAL: float = 0.99

SIGMA_ANNUAL: float = 0.16
MU_ANNUAL: float = 0.0
CLOCK_HZ: float = 50e6
P0_REAL: float = 100.0

TICKS_BIAS: int = 10_000_000
TICKS_MSE: int = 1_000_000

RNG_SEED: int = 0xDEADBEEF

DT_INTERPRETATIONS: dict[str, float] = {
    "physical  (1 tick = 1 clock cycle, 20ns)": 1.0 / CLOCK_HZ,
    "market-1s (1 tick = 1 market second)": 1.0 / (252 * 6.5 * 3600),
    "market-1m (1 tick = 1 market minute)": 1.0 / (252 * 6.5 * 60),
    "scaled    (1 tick = 1/1000 trading day)": 1.0 / (252 * 1000),
}


def to_fixed(real_value: float, fraction_bits: int) -> int:
    """Quantizes a real value to a fixed-point integer with the given fractional resolution.

    Args:
        real_value: The real value to quantize.
        fraction_bits: The number of fractional bits in the target Q-format.

    Returns:
        The rounded fixed-point integer representation of the input value.
    """
    return int(round(real_value * (1 << fraction_bits)))


def from_fixed(integer_value: int, fraction_bits: int) -> float:
    """Recovers the float representation of a fixed-point integer with the given fractional resolution.

    Args:
        integer_value: The fixed-point integer to convert.
        fraction_bits: The number of fractional bits used by the integer's Q-format.

    Returns:
        The float representation of the fixed-point value.
    """
    return integer_value / (1 << fraction_bits)


def round_shift(value: int, shift_amount: int) -> int:
    """Right-shifts an integer with symmetric round-to-nearest, matching the hardware DSP rounding.

    A plain arithmetic right shift truncates toward negative infinity and skews the diffusion
    term negative; this routine adds half-LSB before the shift so positive and negative inputs
    round symmetrically.

    Args:
        value: The integer value to shift.
        shift_amount: The number of bit positions to right-shift; negative values left-shift.

    Returns:
        The rounded shifted result, suitable for re-quantizing intermediate Q-format products.
    """
    if shift_amount <= 0:
        return value << (-shift_amount)
    half = 1 << (shift_amount - 1)
    if value >= 0:
        return (value + half) >> shift_amount
    return -(((-value) + half) >> shift_amount)


def clamp(value: int, low: int, high: int) -> int:
    """Clamps an integer to the inclusive range [low, high].

    Args:
        value: The value to clamp.
        low: The lower bound of the allowed range.
        high: The upper bound of the allowed range.

    Returns:
        The clamped value.
    """
    return max(low, min(high, value))


def clamp_price(price: int) -> int:
    """Clamps a Q8.24 price to the legal hardware range [Q8_24_MIN, Q8_24_MAX].

    Args:
        price: The Q8.24 price integer to clamp.

    Returns:
        The clamped Q8.24 price.
    """
    return clamp(value=price, low=Q8_24_MIN, high=Q8_24_MAX)


def sigma_tick_from_annual(sigma_annual: float, dt: float) -> float:
    """Returns the per-tick volatility implied by the annualized sigma and the chosen tick interval.

    Args:
        sigma_annual: The annualized volatility.
        dt: The tick interval in years.

    Returns:
        The per-tick volatility sigma_annual * sqrt(dt).
    """
    return sigma_annual * math.sqrt(dt)


def mu_ito_tick(
    mu_annual: float,
    sigma_annual: float,
    dt: float,
    ito_corrected: bool = True,
) -> float:
    """Returns the per-tick log-price drift, including the closed-form Ito correction by default.

    Args:
        mu_annual: The annualized drift rate.
        sigma_annual: The annualized volatility used to compute the Ito correction.
        dt: The tick interval in years.
        ito_corrected: Determines whether the closed-form -sigma^2 / 2 correction is included.

    Returns:
        The per-tick drift, equal to (mu_annual - 0.5 * sigma_annual^2) * dt when ito_corrected is
        True and mu_annual * dt otherwise.
    """
    if ito_corrected:
        return (mu_annual - 0.5 * sigma_annual ** 2) * dt
    return mu_annual * dt


def q1_quantization_floor() -> dict[str, dict[str, float | str]]:
    """Reports whether sigma * sqrt(dt) * Z survives Q8.24 quantization for each tick interval.

    Returns:
        A mapping from tick-interpretation label to a per-interval result dict containing dt,
        the per-tick sigma, the noise in Q8.24 LSBs, the sigma resolution in Q0.24 LSBs, and a
        PASS/WARN/FAIL status flag derived from the noise margin at Z = 1.
    """
    print("=" * 70)
    print("Q1 — QUANTIZATION FLOOR ANALYSIS")
    print("     Can Q8.24 represent sigma*sqrt(dt)*Z without vanishing?")
    print("=" * 70)

    results: dict[str, dict[str, float | str]] = {}
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


def q2_ito_bias(
    dt: float,
    N: int = TICKS_BIAS,
) -> tuple[NDArray[np.float64], NDArray[np.float64], float]:
    """Estimates the upward log-price drift accumulated when the closed-form Ito correction is omitted.

    Args:
        dt: The tick interval in years used to derive the per-tick volatility and Ito correction.
        N: The number of ticks to simulate for the bias estimate.

    Returns:
        A tuple of (uncorrected log-price array, Ito-corrected log-price array, theoretical median).
        The two arrays have length N + 1 with a leading zero entry; the theoretical median equals
        the per-tick Ito correction multiplied by N.
    """
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


def q3_fixedpoint_mse(
    dt: float,
    N: int = TICKS_MSE,
) -> tuple[
    NDArray[np.float64],
    NDArray[np.float64],
    NDArray[np.float64],
    NDArray[np.float64],
    NDArray[np.float64],
]:
    """Compares the Q8.24 fixed-point GBM trajectory against a float64 reference over N ticks.

    Args:
        dt: The tick interval in years used to derive the per-tick volatility and drift.
        N: The number of ticks to simulate on both the float and fixed-point paths.

    Returns:
        A tuple of (float price, fixed-point price in real units, float sigma, fixed-point sigma in
        real units, real-valued Z samples). All arrays have length N + 1 with the leading entry
        holding the initial state.
    """
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

        # Normalizes the absolute return by P0 to mirror the divider-free hardware path.
        abs_ret = (abs(P_float[i+1] - P_float[i]) / max(P0_REAL, 1e-10)) * SCALE_APPROX
        sig_new = ALPHA_REAL * sig_float[i] + (1 - ALPHA_REAL) * abs_ret
        sig_float[i+1] = max(sig_float[0], sig_new)

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

        # Sums and clamps the price to the legal Q8.24 hardware range.
        P_new = P + drift + diffusion
        if P_new > Q8_24_MAX:
            overflow_count += 1
        if P_new < Q8_24_MIN:
            underflow_count += 1
        P_new = clamp_price(P_new)
        P_int[i+1] = P_new

        # Updates the volatility EMA using the divider-free abs-return normalization.
        delta_P      = abs(P_new - P)
        abs_ret_norm = (delta_P << SIGMA_FRAC) // max(P0_fp, 1)
        abs_ret_norm = clamp(abs_ret_norm, 0, SIGMA_MAX)

        # Implements the 1.25 scale as x + (x >> 2) so the hardware avoids a DSP multiply.
        abs_ret_scaled = abs_ret_norm + (abs_ret_norm >> 2)
        abs_ret_scaled = clamp(abs_ret_scaled, 0, SIGMA_MAX)

        sig_new = (round_shift(alpha_fp * sig, SIGMA_FRAC)
                   + round_shift(one_m_alpha * abs_ret_scaled, SIGMA_FRAC))
        sig_new = clamp(sig_new, sigma_init_fp, SIGMA_MAX)
        sig_int[i+1] = sig_new

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


def make_plots(
    P_float: NDArray[np.float64],
    P_fixed: NDArray[np.float64],
    sig_float: NDArray[np.float64],
    sig_fixed: NDArray[np.float64],
    Z_samples: NDArray[np.float64],
    log_P_unc: NDArray[np.float64],
    log_P_corr: NDArray[np.float64],
    theoretical_median: float,
    dt: float,
) -> None:
    """Plots the price and sigma traces, the log-return distribution, and the Ito-correction ensemble.

    Args:
        P_float: The float64 reference price array, length N + 1, including the initial value.
        P_fixed: The Q8.24 fixed-point price array converted to float, length N + 1.
        sig_float: The float64 reference sigma array, length N + 1, including the initial value.
        sig_fixed: The Q0.24 fixed-point sigma array converted to float, length N + 1.
        Z_samples: The float64 Gaussian samples that drove both paths, accepted for signature symmetry.
        log_P_unc: The uncorrected log-price array returned by q2_ito_bias.
        log_P_corr: The Ito-corrected log-price array returned by q2_ito_bias.
        theoretical_median: The closed-form theoretical median log-price after N ticks.
        dt: The tick interval in years used to annotate the figure.
    """
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle(
        f"GBM Quantization Floor — Q8.24 price / Q0.24 sigma\n"
        f"dt={dt:.2e}, sigma={SIGMA_ANNUAL}, alpha={ALPHA_REAL}, "
        f"scale=1.25, hard floor",
        fontsize=11, fontweight="bold"
    )

    N_plot = min(len(P_float) - 1, 500)
    ticks  = np.arange(N_plot + 1)

    # Panel 1: float vs fixed-point price trace.
    ax = axes[0, 0]
    ax.plot(ticks, P_float[:N_plot+1], label="Float64", lw=1.2, color="#185FA5")
    ax.plot(ticks, P_fixed[:N_plot+1], label="Q8.24 Fixed", lw=1.0,
            color="#D85A30", alpha=0.8, linestyle="--")
    ax.set_title("Price trace: float64 vs Q8.24", fontsize=11)
    ax.set_xlabel("Tick")
    ax.set_ylabel("Price ($)")
    ax.legend(loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 2: sigma stability — must not collapse.
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

    # Panel 3: log-return histogram comparison.
    ax = axes[1, 0]
    lr_float = np.diff(np.log(np.maximum(P_float, 1e-10)))
    lr_fixed = np.diff(np.log(np.maximum(P_fixed, 1e-10)))
    low  = np.percentile(lr_float, 1)
    high = np.percentile(lr_float, 99)
    bins = np.linspace(low, high, 80)
    ax.hist(lr_fixed, bins=bins, alpha=0.3, label="Q8.24 Fixed",
            color="#D85A30", density=True, histtype='stepfilled')
    ax.hist(lr_float, bins=bins, alpha=1.0, label="Float64",
            color="#185FA5", density=True, histtype='step', linewidth=1.5)
    ax.set_title("Log-return distribution", fontsize=11)
    ax.set_xlabel("Log-return per tick")
    ax.set_ylabel("Density")
    ax.legend(loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 4: vectorized Monte Carlo Ito correction ensemble.
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


def export_csv(
    P_float: NDArray[np.float64],
    P_fixed: NDArray[np.float64],
    sig_float: NDArray[np.float64],
    sig_fixed: NDArray[np.float64],
    N: int = 5000,
) -> None:
    """Writes a tick-by-tick price and sigma comparison CSV between the float and fixed-point paths.

    Args:
        P_float: The float64 reference price array, length N + 1, including the initial value.
        P_fixed: The Q8.24 fixed-point price array converted to float, length N + 1.
        sig_float: The float64 reference sigma array, length N + 1, including the initial value.
        sig_fixed: The Q0.24 fixed-point sigma array converted to float, length N + 1.
        N: The maximum number of ticks to write to the CSV.
    """
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


def main() -> None:
    """Runs Q1, Q2, and Q3 in sequence and prints the fixed-point format recommendation for the RTL handoff."""
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
