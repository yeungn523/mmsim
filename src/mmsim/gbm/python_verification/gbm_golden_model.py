"""Provides the integer-only fixed-point GBM golden model for the Euler and log-space hardware variants."""

import argparse
import csv
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from numpy.typing import NDArray
from scipy import stats

from exp_lut_golden import EXP_LUT, L_FRAC, L_MAX, L_MIN_FIXED, L_STEP_RECIP, N_ENTRIES, l_to_price


INITIAL_LOG_PRICE_FIXED: int = 0x049AEC6F

# Directory that ModelSim runs from; .hex outputs consumed by $readmemh are written here so the testbench can find
# them regardless of the Python script's working directory.
SIMULATION_DIRECTORY: Path = Path(__file__).resolve().parent.parent / "sim"

PRICE_FRACTION_BITS: int = 24
SIGMA_FRACTION_BITS: int = 24
GAUSSIAN_FRACTION_BITS: int = 12
PRICE_WIDTH_BITS: int = 32
SIGMA_WIDTH_BITS: int = 32
GAUSSIAN_WIDTH_BITS: int = 16

PRICE_MAX_INT: int = (1 << PRICE_WIDTH_BITS) - 1
PRICE_MIN_INT: int = 1
SIGMA_MAX_INT: int = (1 << SIGMA_WIDTH_BITS) - 1
SIGMA_MIN_INT: int = 1

SIGMA_ANNUAL: float = 0.16
MU_ANNUAL: float = 0.0
INITIAL_PRICE_REAL: float = 100.0
EMA_ALPHA_REAL: float = 0.99
FEEDBACK_ENABLED: bool = True
TICK_INTERVAL_YEARS: float = 1.0 / (252 * 6.5 * 3600)

VALIDATE_TICK_COUNT: int = 1_000_000
GENERATE_TICK_COUNT: int = 1_000_000
BIT_EXACT_TICK_COUNT: int = 500
RNG_SEED: int = 0xDEADBEEF


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
    """Right-shifts an integer with round-to-nearest, mirroring the hardware DSP rounding behavior.

    Args:
        value: The integer value to shift.
        shift_amount: The number of bit positions to right-shift; negative values left-shift.

    Returns:
        The rounded shifted result, suitable for re-quantizing intermediate Q-format products.
    """
    if shift_amount <= 0:
        return value << (-shift_amount)
    return (value + (1 << (shift_amount - 1))) >> shift_amount


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


def quantize_gaussian(gaussian_real: float) -> int:
    """Quantizes a Gaussian sample to a saturating Q4.12 integer matching the Ziggurat hardware output.

    Args:
        gaussian_real: The real-valued Gaussian sample to quantize.

    Returns:
        The Q4.12 integer representation of the sample, clipped to the legal hardware range.
    """
    gaussian_fixed = int(round(gaussian_real * (1 << GAUSSIAN_FRACTION_BITS)))
    return clamp(gaussian_fixed, -(8 << GAUSSIAN_FRACTION_BITS), (8 << GAUSSIAN_FRACTION_BITS) - 1)


def sigma_tick_from_annual(sigma_annual: float, tick_interval_years: float) -> float:
    """Returns the per-tick volatility implied by the annualized sigma and tick interval.

    Args:
        sigma_annual: The annualized volatility.
        tick_interval_years: The tick interval in years.

    Returns:
        The per-tick volatility sigma_annual * sqrt(tick_interval_years).
    """
    return sigma_annual * np.sqrt(tick_interval_years)


def mu_ito_tick(mu_annual: float, sigma_annual: float, tick_interval_years: float) -> float:
    """Returns the Ito-corrected per-tick log-price drift used by both Euler and log-space ticks.

    Args:
        mu_annual: The annualized drift rate.
        sigma_annual: The annualized volatility used to compute the Ito correction.
        tick_interval_years: The tick interval in years.

    Returns:
        The per-tick drift (mu_annual - 0.5 * sigma_annual^2) * tick_interval_years.
    """
    return (mu_annual - 0.5 * sigma_annual**2) * tick_interval_years


def build_constants(tick_interval_years: float = TICK_INTERVAL_YEARS) -> dict[str, float | int]:
    """Builds the per-tick fixed-point constants shared by the Euler and log-space tick functions.

    Args:
        tick_interval_years: The tick interval in years used to derive the per-tick volatility and drift.

    Returns:
        A mapping from constant name to value, including the float and Q-format representations of the tick
        interval, sigma_per_tick, mu_ito_per_tick, alpha, one minus alpha, the initial price, and the reciprocal
        of the initial price used by the sigma feedback loop.
    """
    sigma_per_tick = sigma_tick_from_annual(SIGMA_ANNUAL, tick_interval_years)
    mu_ito_per_tick = mu_ito_tick(MU_ANNUAL, SIGMA_ANNUAL, tick_interval_years)

    mu_ito_fixed = to_fixed(mu_ito_per_tick, PRICE_FRACTION_BITS)
    sigma_initial_fixed = clamp(to_fixed(sigma_per_tick, SIGMA_FRACTION_BITS), SIGMA_MIN_INT, SIGMA_MAX_INT)
    alpha_fixed = clamp(to_fixed(EMA_ALPHA_REAL, SIGMA_FRACTION_BITS), 0, (1 << SIGMA_FRACTION_BITS) - 1)
    one_minus_alpha_fixed = (1 << SIGMA_FRACTION_BITS) - alpha_fixed

    initial_price_fixed = clamp(to_fixed(INITIAL_PRICE_REAL, PRICE_FRACTION_BITS), PRICE_MIN_INT, PRICE_MAX_INT)
    initial_price_reciprocal_fixed = int(round((1 << PRICE_FRACTION_BITS) / INITIAL_PRICE_REAL))

    return {
        "tick_interval_years":            tick_interval_years,
        "sigma_per_tick":                 sigma_per_tick,
        "mu_ito_per_tick":                mu_ito_per_tick,
        "mu_ito_fixed":                   mu_ito_fixed,
        "sigma_initial_fixed":            sigma_initial_fixed,
        "alpha_fixed":                    alpha_fixed,
        "one_minus_alpha_fixed":          one_minus_alpha_fixed,
        "initial_price_fixed":            initial_price_fixed,
        "initial_price_reciprocal_fixed": initial_price_reciprocal_fixed,
    }


def sigma_feedback(
    price_new: int,
    price_previous: int,
    sigma: int,
    constants: dict[str, float | int],
) -> int:
    """Updates sigma with the EMA plus GARCH-style feedback shared by the Euler and log-space ticks.

    Args:
        price_new: The Q8.24 price at the current tick.
        price_previous: The Q8.24 price at the previous tick.
        sigma: The Q8.24 sigma at the previous tick.
        constants: The per-tick constants mapping returned by build_constants.

    Returns:
        The updated Q8.24 sigma, clamped to [sigma_initial_fixed, SIGMA_MAX_INT].
    """
    price_delta = abs(price_new - price_previous)

    # price_delta (Q8.24) * initial_price_reciprocal_fixed (Q8.24) = Q16.48; right-shifts back to Q8.24.
    absolute_return_normalized = round_shift(
        price_delta * constants["initial_price_reciprocal_fixed"],
        PRICE_FRACTION_BITS,
    )
    absolute_return_normalized = clamp(absolute_return_normalized, 0, SIGMA_MAX_INT)
    absolute_return_scaled = clamp(
        absolute_return_normalized + (absolute_return_normalized >> 2),
        0,
        SIGMA_MAX_INT,
    )

    sigma_new = (
        round_shift(constants["alpha_fixed"]           * sigma,                  SIGMA_FRACTION_BITS)
        + round_shift(constants["one_minus_alpha_fixed"] * absolute_return_scaled, SIGMA_FRACTION_BITS)
    )

    return clamp(sigma_new, constants["sigma_initial_fixed"], SIGMA_MAX_INT)


def gbm_tick_euler(
    price: int,
    sigma: int,
    gaussian_fixed: int,
    constants: dict[str, float | int],
    feedback_enabled: bool = True,
) -> tuple[int, int]:
    """Advances the Euler-Maruyama path by one Q8.24 tick using the discretized SDE update.

    Args:
        price: The Q8.24 price at the current tick.
        sigma: The Q8.24 sigma at the current tick.
        gaussian_fixed: The Q4.12 Gaussian sample driving the diffusion term.
        constants: The per-tick constants mapping returned by build_constants.
        feedback_enabled: Determines whether sigma is updated by the EMA feedback this tick.

    Returns:
        A tuple of (price, sigma) for the next tick, both as Q8.24 integers.
    """
    drift = round_shift(price * constants["mu_ito_fixed"], PRICE_FRACTION_BITS)
    price_times_sigma = round_shift(price * sigma, SIGMA_FRACTION_BITS)
    diffusion = round_shift(price_times_sigma * gaussian_fixed, GAUSSIAN_FRACTION_BITS)

    price_new = clamp(price + drift + diffusion, PRICE_MIN_INT, PRICE_MAX_INT)
    sigma_new = sigma_feedback(price_new, price, sigma, constants) if feedback_enabled else sigma

    return int(price_new), int(sigma_new)


def gbm_tick_logspace(
    log_price: int,
    price: int,
    sigma: int,
    gaussian_fixed: int,
    constants: dict[str, float | int],
    feedback_enabled: bool = True,
) -> tuple[int, int, int]:
    """Advances the log-space path by one Q8.24 tick by updating L and recovering the price through the LUT.

    Args:
        log_price: The Q8.24 log-price at the current tick.
        price: The Q8.24 price at the current tick.
        sigma: The Q8.24 sigma at the current tick.
        gaussian_fixed: The Q4.12 Gaussian sample driving the diffusion term.
        constants: The per-tick constants mapping returned by build_constants.
        feedback_enabled: Determines whether sigma is updated by the EMA feedback this tick.

    Returns:
        A tuple of (log-price, price, sigma) for the next tick, all as Q8.24 integers.
    """
    log_price_min_fixed = L_MIN_FIXED
    log_price_max_fixed = int(round(L_MAX * (1 << L_FRAC)))

    diffusion = round_shift(constants["sigma_initial_fixed"] * gaussian_fixed, GAUSSIAN_FRACTION_BITS)
    log_price_new = clamp(
        log_price + constants["mu_ito_fixed"] + diffusion,
        log_price_min_fixed,
        log_price_max_fixed,
    )

    price_new = l_to_price(log_price_new)
    sigma_new = sigma_feedback(price_new, price, sigma, constants) if feedback_enabled else sigma

    return int(log_price_new), int(price_new), int(sigma_new)


def run_simulation(
    gaussian_samples_fixed: NDArray[np.int64],
    constants: dict[str, float | int],
    feedback_enabled: bool = True,
    dut: str = "euler",
) -> tuple[NDArray[np.int64], NDArray[np.int64]]:
    """Runs the Q8.24 fixed-point simulation across N ticks and returns the per-tick price and sigma arrays.

    Args:
        gaussian_samples_fixed: The Q4.12 Gaussian samples driving the simulation.
        constants: The per-tick constants mapping returned by build_constants.
        feedback_enabled: Determines whether the sigma EMA feedback is enabled each tick.
        dut: The architecture under test, either "euler" or "logspace".

    Returns:
        A tuple of (price_array, sigma_array) of length N + 1, both Q8.24 integers, where the zeroth entry
        stores the initial state and entries 1..N store the post-tick values.
    """
    tick_count = len(gaussian_samples_fixed)

    price_array = np.zeros(tick_count + 1, dtype=np.int64)
    sigma_array = np.zeros(tick_count + 1, dtype=np.int64)
    price_array[0] = constants["initial_price_fixed"]
    sigma_array[0] = constants["sigma_initial_fixed"]

    if dut == "euler":
        for tick_index in range(tick_count):
            price_array[tick_index + 1], sigma_array[tick_index + 1] = gbm_tick_euler(
                int(price_array[tick_index]),
                int(sigma_array[tick_index]),
                int(gaussian_samples_fixed[tick_index]),
                constants,
                feedback_enabled,
            )
    else:
        log_price_array = np.zeros(tick_count + 1, dtype=np.int64)
        log_price_array[0] = INITIAL_LOG_PRICE_FIXED

        for tick_index in range(tick_count):
            (
                log_price_array[tick_index + 1],
                price_array[tick_index + 1],
                sigma_array[tick_index + 1],
            ) = gbm_tick_logspace(
                int(log_price_array[tick_index]),
                int(price_array[tick_index]),
                int(sigma_array[tick_index]),
                int(gaussian_samples_fixed[tick_index]),
                constants,
                feedback_enabled,
            )

    return price_array, sigma_array


def run_float_reference(
    gaussian_samples_real: NDArray[np.float64],
    constants: dict[str, float | int],
) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """Runs the float64 reference path with hardware-matched approximations for use as the ground truth.

    Args:
        gaussian_samples_real: The real-valued Gaussian samples driving the reference simulation.
        constants: The per-tick constants mapping returned by build_constants.

    Returns:
        A tuple of (price_array, sigma_array) of length N + 1, in native float units, where the zeroth entry
        stores the initial state and entries 1..N store the post-tick values.
    """
    tick_count = len(gaussian_samples_real)
    sigma_per_tick = constants["sigma_per_tick"]
    mu_per_tick = constants["mu_ito_per_tick"]

    price_float = np.zeros(tick_count + 1)
    sigma_float = np.zeros(tick_count + 1)
    price_float[0] = INITIAL_PRICE_REAL
    sigma_float[0] = sigma_per_tick

    for tick_index in range(tick_count):
        drift = price_float[tick_index] * mu_per_tick
        diffusion = price_float[tick_index] * sigma_per_tick * gaussian_samples_real[tick_index]

        price_new = max(INITIAL_PRICE_REAL * 1e-6, price_float[tick_index] + drift + diffusion)
        price_float[tick_index + 1] = price_new

        absolute_return = (
            abs(price_float[tick_index + 1] - price_float[tick_index]) / max(INITIAL_PRICE_REAL, 1e-10)
        ) * 1.25
        sigma_float[tick_index + 1] = max(
            sigma_float[0],
            EMA_ALPHA_REAL * sigma_float[tick_index] + (1 - EMA_ALPHA_REAL) * absolute_return,
        )

    return price_float, sigma_float


def run_statistical_tests(
    price_array: NDArray[np.int64],
    constants: dict[str, float | int],
    label: str = "Golden Model",
) -> dict[str, float | int | bool | str]:
    """Runs Kolmogorov-Smirnov, ACF, and mean-bias tests on a captured trajectory and returns the verdict mapping.

    Args:
        price_array: The captured Q8.24 price array, length N + 1, including the initial value.
        constants: The per-tick constants mapping returned by build_constants.
        label: The human-readable label used in plots and console output.

    Returns:
        A mapping holding the per-test statistics, the pass/fail verdicts, and the label, ready to be persisted
        as JSON or printed by print_test_results.
    """
    price_real = price_array / (1 << PRICE_FRACTION_BITS)
    tick_count = len(price_real) - 1

    log_returns = np.diff(np.log(np.maximum(price_real, 1e-10)))
    theoretical_mean = constants["mu_ito_per_tick"]
    theoretical_std = constants["sigma_per_tick"]

    log_returns_sample = log_returns[:100_000] if tick_count > 100_000 else log_returns
    log_returns_normalized = (log_returns_sample - theoretical_mean) / theoretical_std
    ks_stat, ks_pval = stats.kstest(log_returns_normalized, "norm")

    log_returns_mean = float(np.mean(log_returns))
    log_returns_std = float(np.std(log_returns))
    mean_bias_sigma = abs(log_returns_mean - theoretical_mean) / theoretical_std
    std_error_fraction = abs(log_returns_std - theoretical_std) / theoretical_std

    autocorrelation_returns = [
        float(np.corrcoef(log_returns[:-lag], log_returns[lag:])[0, 1]) for lag in range(1, 11)
    ]
    max_autocorrelation_returns = max(abs(value) for value in autocorrelation_returns)

    absolute_returns = np.abs(log_returns)
    autocorrelation_absolute_returns = [
        float(np.corrcoef(absolute_returns[:-lag], absolute_returns[lag:])[0, 1]) for lag in range(1, 21)
    ]

    negative_price_count = int(np.sum(price_real <= 0))
    clamp_count_low = int(np.sum(price_array == PRICE_MIN_INT))
    clamp_count_high = int(np.sum(price_array == PRICE_MAX_INT))

    return {
        "label":                label,
        "tick_count":           tick_count,
        "tick_interval_years":  constants["tick_interval_years"],
        "log_returns_mean":     log_returns_mean,
        "log_returns_std":      log_returns_std,
        "theoretical_mean":     theoretical_mean,
        "theoretical_std":      theoretical_std,
        "mean_bias_sigma":      mean_bias_sigma,
        "std_error_fraction":   std_error_fraction,
        "ks_stat":              float(ks_stat),
        "ks_pval":              float(ks_pval),
        "ks_pass":              bool(ks_pval > 0.01),
        "acf_returns_lag1":     autocorrelation_returns[0],
        "acf_returns_max":      max_autocorrelation_returns,
        "acf_abs_lag1":         autocorrelation_absolute_returns[0],
        "negative_price_count": negative_price_count,
        "clamp_low_count":      clamp_count_low,
        "clamp_high_count":     clamp_count_high,
        "G_KS_PASS":            bool(ks_pval > 0.01),
        "G_ACF_PASS":           bool(max_autocorrelation_returns < 0.05),
        "G_SAFE_PASS":          bool(negative_price_count == 0),
        "G_BIAS_PASS":          bool(mean_bias_sigma < 0.10),
    }


def print_test_results(results: dict[str, float | int | bool | str]) -> None:
    """Prints the formatted statistical-test verdict produced by run_statistical_tests.

    Args:
        results: The result mapping returned by run_statistical_tests.
    """
    print(f"\n  {'─' * 60}")
    print(f"  Statistical Test Results: {results['label']}")
    print(f"  {'─' * 60}")
    print(f"  N = {results['tick_count']:,}  dt = {results['tick_interval_years']:.4e}")

    print(
        f"\n  Log-return mean:  {results['log_returns_mean']:.4e}  "
        f"(theory: {results['theoretical_mean']:.4e})  "
        f"bias = {results['mean_bias_sigma']:.4f} sigma"
    )
    print(
        f"  Log-return std:   {results['log_returns_std']:.6f}  "
        f"(theory: {results['theoretical_std']:.6f})  "
        f"err = {results['std_error_fraction'] * 100:.3f}%"
    )

    print(
        f"\n  KS test:          stat={results['ks_stat']:.4f}  p={results['ks_pval']:.4f}  "
        f"[{'PASS' if results['G_KS_PASS'] else 'FAIL'}]"
    )
    print(
        f"  Max |ACF| ret:    {results['acf_returns_max']:.4f}  "
        f"[{'PASS' if results['G_ACF_PASS'] else 'FAIL'}]"
    )
    print(f"  ACF |ret| lag-1:  {results['acf_abs_lag1']:.4f}")
    print(
        f"  Negative prices:  {results['negative_price_count']}  "
        f"[{'PASS' if results['G_SAFE_PASS'] else 'FAIL'}]"
    )
    print(f"  Clamp-low:        {results['clamp_low_count']}")
    print(f"  Clamp-high:       {results['clamp_high_count']}")

    overall_pass = all(
        [results["G_KS_PASS"], results["G_ACF_PASS"], results["G_SAFE_PASS"], results["G_BIAS_PASS"]]
    )
    print(f"\n  OVERALL: {'PASS' if overall_pass else 'REVIEW REQUIRED'}")


def compare_with_modelsim(
    sim_csv_path: str,
    gaussian_samples_fixed: NDArray[np.int64],
    constants: dict[str, float | int],
    dut: str = "euler",
) -> bool:
    """Loads a ModelSim CSV and reports bit-exact price and sigma agreement against the golden trajectory.

    Args:
        sim_csv_path: The path to the ModelSim-emitted CSV containing price_out_hex and sigma_out_hex columns.
        gaussian_samples_fixed: The Q4.12 Gaussian samples that drove the ModelSim run; must align tick-for-tick.
        constants: The per-tick constants mapping returned by build_constants.
        dut: The architecture under test, either "euler" or "logspace".

    Returns:
        True when the first BIT_EXACT_TICK_COUNT ticks of price and sigma match exactly, otherwise False.
    """
    print(f"\n  Loading ModelSim output: {sim_csv_path}")
    sim_prices: list[int] = []
    sim_sigmas: list[int] = []

    with open(sim_csv_path, "r") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            sim_prices.append(int(row["price_out_hex"], 16))
            sim_sigmas.append(int(row["sigma_out_hex"], 16))

    sim_tick_count = len(sim_prices)
    print(f"  Loaded {sim_tick_count} ticks. DUT={dut}")

    price_golden, sigma_golden = run_simulation(
        gaussian_samples_fixed[:sim_tick_count], constants, FEEDBACK_ENABLED, dut=dut
    )

    price_match_count = 0
    sigma_match_count = 0
    first_price_mismatch: tuple[int, int, int] | None = None
    first_sigma_mismatch: tuple[int, int, int] | None = None

    for tick_index in range(sim_tick_count):
        golden_price = int(price_golden[tick_index + 1])
        golden_sigma = int(sigma_golden[tick_index + 1])
        sim_price = sim_prices[tick_index]
        sim_sigma = sim_sigmas[tick_index]

        if golden_price == sim_price:
            price_match_count += 1
        elif first_price_mismatch is None:
            first_price_mismatch = (tick_index + 1, golden_price, sim_price)

        if golden_sigma == sim_sigma:
            sigma_match_count += 1
        elif first_sigma_mismatch is None:
            first_sigma_mismatch = (tick_index + 1, golden_sigma, sim_sigma)

    for tick_index in range(sim_tick_count):
        golden_sigma = int(sigma_golden[tick_index + 1])
        sim_sigma = sim_sigmas[tick_index]
        if golden_sigma != sim_sigma:
            print(
                f"\n  First sigma divergence tick {tick_index + 1}: "
                f"golden={golden_sigma:#010x} sim={sim_sigma:#010x}  delta={golden_sigma - sim_sigma}"
            )
            for neighbor_index in range(max(0, tick_index - 2), min(sim_tick_count, tick_index + 3)):
                print(
                    f"    tick {neighbor_index + 1}: "
                    f"gold_sigma={int(sigma_golden[neighbor_index + 1]):#010x} "
                    f"sim_sigma={sim_sigmas[neighbor_index]:#010x} "
                    f"gold_P={int(price_golden[neighbor_index + 1]):#010x} "
                    f"sim_P={sim_prices[neighbor_index]:#010x}"
                )
            break

    print(f"\n  Price bit-exact: {price_match_count}/{sim_tick_count}")
    print(f"  Sigma bit-exact: {sigma_match_count}/{sim_tick_count}")

    if first_price_mismatch:
        tick, golden, sim = first_price_mismatch
        print(
            f"  First price mismatch tick {tick}: "
            f"golden=0x{golden:08X} ({from_fixed(golden, PRICE_FRACTION_BITS):.4f}), "
            f"sim=0x{sim:08X} ({from_fixed(sim, PRICE_FRACTION_BITS):.4f})"
        )
    if first_sigma_mismatch:
        tick, golden, sim = first_sigma_mismatch
        print(f"  First sigma mismatch tick {tick}: golden=0x{golden:08X}, sim=0x{sim:08X}")

    bit_exact_window = min(BIT_EXACT_TICK_COUNT, sim_tick_count)
    price_exact = all(
        int(price_golden[tick_index + 1]) == sim_prices[tick_index] for tick_index in range(bit_exact_window)
    )
    sigma_exact = all(
        int(sigma_golden[tick_index + 1]) == sim_sigmas[tick_index] for tick_index in range(bit_exact_window)
    )
    print(
        f"\n  Bit-exact first {bit_exact_window} ticks — "
        f"Price: {'PASS' if price_exact else 'FAIL'}  "
        f"Sigma: {'PASS' if sigma_exact else 'FAIL'}"
    )

    return price_exact and sigma_exact


def export_reference_csv(
    price_array: NDArray[np.int64],
    sigma_array: NDArray[np.int64],
    gaussian_samples_fixed: NDArray[np.int64],
    filename: str = "gbm_golden_reference.csv",
) -> None:
    """Writes the per-tick price, sigma, and Z reference CSV used for archival cross-runs and external scoring.

    Args:
        price_array: The captured Q8.24 price array, length N + 1, including the initial value.
        sigma_array: The captured Q8.24 sigma array, length N + 1, including the initial value.
        gaussian_samples_fixed: The Q4.12 Gaussian samples consumed during the run.
        filename: The destination CSV path; relative paths resolve to the current working directory.
    """
    tick_count = min(len(price_array) - 1, GENERATE_TICK_COUNT)
    print(f"\n  Exporting reference CSV: {filename} ({tick_count} ticks)")

    with open(filename, "w", newline="") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            ["tick", "z_int_q412", "price_int_q824", "sigma_int_q824", "price_real", "sigma_real"]
        )
        for tick_index in range(tick_count):
            writer.writerow([
                tick_index + 1,
                int(gaussian_samples_fixed[tick_index]),
                int(price_array[tick_index + 1]),
                int(sigma_array[tick_index + 1]),
                f"{from_fixed(int(price_array[tick_index + 1]), PRICE_FRACTION_BITS):.8f}",
                f"{from_fixed(int(sigma_array[tick_index + 1]), SIGMA_FRACTION_BITS):.8f}",
            ])


def export_gaussian_samples_hex(
    gaussian_samples_fixed: NDArray[np.int64],
    filename: str | None = None,
) -> None:
    """Writes the Q4.12 Gaussian samples as $readmemh-compatible 4-digit hex into the simulation directory.

    Args:
        gaussian_samples_fixed: The Q4.12 Gaussian samples to export.
        filename: The destination hex path. Defaults to SIMULATION_DIRECTORY / "z_samples.hex" when omitted.
    """
    if filename is None:
        filename = str(SIMULATION_DIRECTORY / "z_samples.hex")

    print(f"  Exporting Z samples for $readmemh: {filename}")
    with open(filename, "w") as hex_file:
        for gaussian_sample in gaussian_samples_fixed:
            hex_file.write(f"{int(gaussian_sample) & 0xFFFF:04X}\n")
    print(f"  Written {len(gaussian_samples_fixed)} samples.")


def make_plots(
    price_array: NDArray[np.int64],
    sigma_array: NDArray[np.int64],
    gaussian_samples_fixed: NDArray[np.int64],
    constants: dict[str, float | int],
    price_float: NDArray[np.float64] | None = None,
    sigma_float: NDArray[np.float64] | None = None,
    label: str = "Golden Model",
) -> None:
    """Plots the price and sigma traces, log-return distribution, autocorrelation, and tail diagnostics.

    Args:
        price_array: The captured Q8.24 price array, length N + 1, including the initial value.
        sigma_array: The captured Q8.24 sigma array, length N + 1, including the initial value.
        gaussian_samples_fixed: The Q4.12 Gaussian samples consumed during the run.
        constants: The per-tick constants mapping returned by build_constants.
        price_float: The optional float64 reference price array overlaid on the price trace panel.
        sigma_float: The optional float64 reference sigma array, accepted for signature symmetry.
        label: The human-readable label used in the figure title and output filename.
    """
    price_real = price_array / (1 << PRICE_FRACTION_BITS)
    sigma_real = sigma_array / (1 << SIGMA_FRACTION_BITS)
    tick_count = len(price_real) - 1
    plot_tick_count = min(tick_count, 20_000)
    ticks = np.arange(plot_tick_count + 1)

    log_returns = np.diff(np.log(np.maximum(price_real, 1e-10)))
    absolute_returns = np.abs(log_returns)

    figure, axes = plt.subplots(3, 2, figsize=(14, 15))
    figure.suptitle(
        f"GBM Golden Model - {label}\n"
        f"Q8.24 price, Q8.24 sigma, Q4.12 Z, dt={constants['tick_interval_years']:.2e}",
        fontsize=12,
        fontweight="bold",
    )

    axis = axes[0, 0]
    axis.plot(ticks, price_real[:plot_tick_count + 1], lw=0.8, color="#185FA5")
    if price_float is not None:
        axis.plot(
            ticks,
            price_float[:plot_tick_count + 1],
            lw=0.8,
            color="#D85A30",
            alpha=0.7,
            linestyle="--",
            label="Float64",
        )
        axis.legend(fontsize=9)
    axis.set_title("Price trace (Q8.24)", fontsize=11)
    axis.set_xlabel("Tick")
    axis.set_ylabel("Price ($)")
    axis.grid(True, alpha=0.3)

    axis = axes[0, 1]
    axis.plot(ticks, sigma_real[:plot_tick_count + 1], lw=0.8, color="#1D9E75")
    axis.set_title("Volatility sigma (Q8.24 EMA)", fontsize=11)
    axis.set_xlabel("Tick")
    axis.set_ylabel("sigma per tick")
    axis.grid(True, alpha=0.3)

    axis = axes[1, 0]
    log_returns_sample = log_returns[:min(tick_count, 500_000)]
    bins = np.linspace(np.percentile(log_returns_sample, 0.1), np.percentile(log_returns_sample, 99.9), 100)
    axis.hist(log_returns_sample, bins=bins, density=True, color="#185FA5", alpha=0.7, label="Empirical")
    grid = np.linspace(bins[0], bins[-1], 300)
    axis.plot(
        grid,
        stats.norm.pdf(grid, constants["mu_ito_per_tick"], constants["sigma_per_tick"]),
        lw=2,
        color="#D85A30",
        label="Theory",
    )
    axis.set_title("Log-return distribution", fontsize=11)
    axis.set_xlabel("Log-return per tick")
    axis.set_ylabel("Density")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3)

    axis = axes[1, 1]
    lags = range(1, 21)
    acf_returns = [np.corrcoef(log_returns[:-lag], log_returns[lag:])[0, 1] for lag in lags]
    acf_absolute_returns = [np.corrcoef(absolute_returns[:-lag], absolute_returns[lag:])[0, 1] for lag in lags]
    axis.bar(
        [lag - 0.2 for lag in lags], acf_returns, width=0.35, color="#185FA5", alpha=0.8, label="ACF returns"
    )
    axis.bar(
        [lag + 0.2 for lag in lags],
        acf_absolute_returns,
        width=0.35,
        color="#1D9E75",
        alpha=0.8,
        label="ACF |returns|",
    )
    axis.axhline(0, color="black", lw=0.8)
    axis.axhline(0.05, color="#D85A30", lw=1, linestyle="--", alpha=0.7)
    axis.axhline(-0.05, color="#D85A30", lw=1, linestyle="--", alpha=0.7)
    axis.set_title("Autocorrelation", fontsize=11)
    axis.set_xlabel("Lag (ticks)")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3)

    axis = axes[2, 0]
    sigma_per_tick = constants["sigma_per_tick"]
    thresholds = np.linspace(0.5, 5.0, 50)
    axis.semilogy(
        thresholds,
        [np.mean(np.abs(log_returns) > threshold * sigma_per_tick) for threshold in thresholds],
        lw=1.5,
        color="#185FA5",
        label="Empirical",
    )
    axis.semilogy(
        thresholds,
        [2 * (1 - stats.norm.cdf(threshold)) for threshold in thresholds],
        lw=1.5,
        color="#D85A30",
        linestyle="--",
        label="Theory",
    )
    axis.set_title("Tail probability (log scale)", fontsize=11)
    axis.set_xlabel("Threshold (sigma)")
    axis.set_ylabel("P(|Z| > k*sigma)")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3, which="both")

    axis = axes[2, 1]
    clustering_tick_count = min(tick_count, 5000)
    axis.plot(
        range(clustering_tick_count), log_returns[:clustering_tick_count], lw=0.5, color="#185FA5", alpha=0.8
    )
    axis.set_title("Log-returns (volatility clustering)", fontsize=11)
    axis.set_xlabel("Tick")
    axis.set_ylabel("Log-return")
    axis.grid(True, alpha=0.3)

    plt.tight_layout()
    output_filename = f"gbm_golden_plots_{label.replace(' ', '_')}.png"
    plt.savefig(output_filename, dpi=150, bbox_inches="tight")
    print(f"  Plots saved to {output_filename}")


def make_comparison_plots(
    price_euler: NDArray[np.int64],
    sigma_euler: NDArray[np.int64],
    price_logspace: NDArray[np.int64],
    sigma_logspace: NDArray[np.int64],
    price_float: NDArray[np.float64],
    sigma_float: NDArray[np.float64],
    gaussian_samples_fixed: NDArray[np.int64],
    constants: dict[str, float | int],
) -> None:
    """Plots a six-panel comparison of the Euler, log-space, and float64 trajectories on the same Z trace.

    Args:
        price_euler: The captured Q8.24 price array from the Euler architecture.
        sigma_euler: The captured Q8.24 sigma array from the Euler architecture.
        price_logspace: The captured Q8.24 price array from the log-space architecture.
        sigma_logspace: The captured Q8.24 sigma array from the log-space architecture.
        price_float: The float64 reference price array shared by both architectures.
        sigma_float: The float64 reference sigma array shared by both architectures.
        gaussian_samples_fixed: The Q4.12 Gaussian samples driving all three runs, accepted for signature symmetry.
        constants: The per-tick constants mapping returned by build_constants.
    """
    price_euler_real = price_euler / (1 << PRICE_FRACTION_BITS)
    price_logspace_real = price_logspace / (1 << PRICE_FRACTION_BITS)
    sigma_euler_real = sigma_euler / (1 << SIGMA_FRACTION_BITS)
    sigma_logspace_real = sigma_logspace / (1 << SIGMA_FRACTION_BITS)

    tick_count = len(price_euler_real) - 1
    macro_tick_count = min(tick_count, 1_000_000)
    micro_tick_count = min(tick_count, 50_000)
    volatility_tick_count = min(tick_count, 50_000)
    sigma_tick_count = min(tick_count, 5_000)

    ticks_macro = np.arange(macro_tick_count + 1)
    ticks_micro = np.arange(micro_tick_count + 1)
    ticks_volatility = np.arange(volatility_tick_count + 1)
    ticks_sigma = np.arange(sigma_tick_count + 1)

    figure, axes = plt.subplots(3, 2, figsize=(15, 16))
    figure.suptitle(
        "GBM Architecture Comparison: Euler-Maruyama vs Log-Space\n"
        "Q8.24 Fixed-Point, 1M ticks, Gaussian Z inputs",
        fontsize=14,
        fontweight="bold",
    )

    # Panel 1: full price trace.
    axis = axes[0, 0]
    axis.plot(
        ticks_macro,
        price_euler_real[:macro_tick_count + 1],
        lw=0.8,
        color="#D85A30",
        alpha=0.8,
        label="Euler-Maruyama",
    )
    axis.plot(
        ticks_macro,
        price_logspace_real[:macro_tick_count + 1],
        lw=0.8,
        color="#185FA5",
        alpha=0.8,
        label="Log-Space",
    )
    axis.plot(
        ticks_macro,
        price_float[:macro_tick_count + 1],
        lw=1.0,
        color="#2C2C2A",
        alpha=0.35,
        linestyle="--",
        label="Float64 ref",
    )
    axis.set_ylim(97, 108)
    axis.set_title("MACRO: Price Trace (Full 1M Ticks)", fontsize=11, fontweight="bold")
    axis.set_xlabel("Tick")
    axis.set_ylabel("Price ($)")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3)

    # Panel 2: cumulative price error against the float64 reference on a log scale.
    axis = axes[0, 1]
    cumulative_error_euler = np.abs(price_euler_real[:macro_tick_count + 1] - price_float[:macro_tick_count + 1])
    cumulative_error_logspace = np.abs(
        price_logspace_real[:macro_tick_count + 1] - price_float[:macro_tick_count + 1]
    )
    cumulative_error_euler = np.maximum(cumulative_error_euler, 1e-6)
    cumulative_error_logspace = np.maximum(cumulative_error_logspace, 1e-6)
    axis.plot(ticks_macro, cumulative_error_euler, lw=0.8, color="#D85A30", alpha=0.8, label="Euler-Maruyama")
    axis.plot(ticks_macro, cumulative_error_logspace, lw=0.8, color="#185FA5", alpha=0.8, label="Log-Space")
    axis.set_yscale("log")
    axis.set_title("MACRO: Absolute Price Error vs Float64 (Log Scale)", fontsize=11, fontweight="bold")
    axis.set_xlabel("Tick")
    axis.set_ylabel("Absolute Error ($) — Log Scale")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3, which="both")

    # Panel 3: micro price trace highlighting the LUT quantization grid in the log-space variant.
    axis = axes[1, 0]
    axis.plot(
        ticks_micro,
        price_euler_real[:micro_tick_count + 1],
        lw=0.8,
        color="#D85A30",
        alpha=0.8,
        label="Euler-Maruyama",
    )
    axis.plot(
        ticks_micro,
        price_logspace_real[:micro_tick_count + 1],
        lw=0.8,
        color="#185FA5",
        alpha=0.8,
        label="Log-Space",
    )
    axis.plot(
        ticks_micro,
        price_float[:micro_tick_count + 1],
        lw=1.0,
        color="#2C2C2A",
        alpha=0.35,
        linestyle="--",
        label="Float64 ref",
    )
    axis.set_title("MICRO: Price Trace (First 50k Ticks) — Note LUT Quantization", fontsize=11, fontweight="bold")
    axis.set_xlabel("Tick")
    axis.set_ylabel("Price ($)")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3)

    # Panel 4: volatility sigma showing the EMA sawtooth shape.
    axis = axes[1, 1]
    axis.plot(
        ticks_sigma,
        sigma_euler_real[:sigma_tick_count + 1],
        lw=0.5,
        color="#D85A30",
        alpha=0.6,
        label="Euler-Maruyama",
    )
    axis.plot(
        ticks_sigma,
        sigma_logspace_real[:sigma_tick_count + 1],
        lw=0.5,
        color="#185FA5",
        alpha=0.6,
        label="Log-Space",
    )
    axis.plot(
        ticks_sigma, sigma_float[:sigma_tick_count + 1], lw=2.0, color="#2C2C2A", alpha=1.0, label="Float64 ref"
    )
    axis.set_title("MICRO: Volatility Sigma (First 5k Ticks) — Note EMA Sawtooth", fontsize=11, fontweight="bold")
    axis.set_xlabel("Tick")
    axis.set_ylabel("Sigma per tick")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3)

    # Panel 5: short-term absolute deviation between each fixed-point variant and the float64 reference.
    axis = axes[2, 0]
    deviation_euler = np.abs(price_euler_real[:volatility_tick_count + 1] - price_float[:volatility_tick_count + 1])
    deviation_logspace = np.abs(
        price_logspace_real[:volatility_tick_count + 1] - price_float[:volatility_tick_count + 1]
    )
    axis.plot(ticks_volatility, deviation_euler, lw=0.5, color="#D85A30", alpha=0.6, label="Euler-Maruyama")
    axis.plot(ticks_volatility, deviation_logspace, lw=0.5, color="#185FA5", alpha=0.6, label="Log-Space")
    axis.set_title("MICRO: Absolute Deviation from Ref (First 50k Ticks)", fontsize=11, fontweight="bold")
    axis.set_xlabel("Tick")
    axis.set_ylabel("|P_fixed - P_float| ($)")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3)

    # Panel 6: zoomed price trace around the Euler divergence region.
    axis = axes[2, 1]
    zoom_tick_start = 150_000
    zoom_tick_end = min(tick_count, 170_000)
    ticks_zoom = np.arange(zoom_tick_start, zoom_tick_end + 1)
    axis.plot(
        ticks_zoom,
        price_euler_real[zoom_tick_start:zoom_tick_end + 1],
        lw=1.0,
        color="#D85A30",
        alpha=0.9,
        label="Euler-Maruyama",
    )
    axis.plot(
        ticks_zoom,
        price_logspace_real[zoom_tick_start:zoom_tick_end + 1],
        lw=1.0,
        color="#185FA5",
        alpha=0.9,
        label="Log-Space",
    )
    axis.plot(
        ticks_zoom,
        price_float[zoom_tick_start:zoom_tick_end + 1],
        lw=1.0,
        color="#2C2C2A",
        alpha=0.35,
        linestyle="--",
        label="Float64 ref",
    )
    axis.set_title("ZOOM: Euler Divergence Region (Ticks 150k–170k)", fontsize=11, fontweight="bold")
    axis.set_xlabel("Tick")
    axis.set_ylabel("Price ($)")
    axis.legend(fontsize=9)
    axis.grid(True, alpha=0.3)

    plt.tight_layout(rect=[0, 0.03, 1, 0.96])
    plt.savefig("gbm_architecture_comparison.png", dpi=150, bbox_inches="tight", facecolor="white")
    print("  Comparison plots saved to gbm_architecture_comparison.png")


def mode_validate(dut: str = "euler") -> None:
    """Runs a self-contained validation pass that simulates VALIDATE_TICK_COUNT ticks, scores them, and emits plots.

    Args:
        dut: The architecture under test, either "euler" or "logspace".
    """
    print("\n" + "#" * 70)
    print(f"#  GBM GOLDEN MODEL - Standalone Validation ({dut.upper()})")
    print("#" * 70)

    constants = build_constants(TICK_INTERVAL_YEARS)

    print(f"\n  Constants:")
    print(f"    dt           = {constants['tick_interval_years']:.4e}")
    print(f"    sigma_tick   = {constants['sigma_per_tick']:.4e}")
    print(f"    mu_ito_tick  = {constants['mu_ito_per_tick']:.4e}")
    print(f"    mu_ito_fp    = 0x{constants['mu_ito_fixed'] & 0xFFFFFFFF:08X}")
    print(
        f"    sigma_init   = 0x{constants['sigma_initial_fixed']:08X}  "
        f"({from_fixed(constants['sigma_initial_fixed'], SIGMA_FRACTION_BITS):.6f})"
    )
    print(
        f"    alpha_fp     = 0x{constants['alpha_fixed']:08X}  "
        f"({from_fixed(constants['alpha_fixed'], SIGMA_FRACTION_BITS):.6f})"
    )
    print(f"    P0_recip     = 0x{constants['initial_price_reciprocal_fixed']:08X}")

    rng = np.random.default_rng(RNG_SEED)
    gaussian_samples_real = rng.standard_normal(VALIDATE_TICK_COUNT)
    gaussian_samples_fixed = np.array(
        [quantize_gaussian(sample) for sample in gaussian_samples_real], dtype=np.int64
    )

    print(f"\n  Running fixed-point simulation ({VALIDATE_TICK_COUNT:,} ticks, dut={dut})...")
    price_array, sigma_array = run_simulation(gaussian_samples_fixed, constants, FEEDBACK_ENABLED, dut=dut)

    print(f"  Running float64 reference...")
    price_float, sigma_float = run_float_reference(gaussian_samples_real, constants)

    results = run_statistical_tests(price_array, constants, label=f"Q8.24 Fixed-Point ({dut})")
    print_test_results(results)

    price_real = price_array / (1 << PRICE_FRACTION_BITS)
    rmse = np.sqrt(np.mean((price_float - price_real) ** 2))
    print(f"\n  RMSE vs float64: {rmse:.6f}  ({rmse / INITIAL_PRICE_REAL * 100:.4f}% of P0)")

    with open(f"gbm_golden_stats_{dut}.json", "w") as stats_file:
        json.dump(results, stats_file, indent=2)
    print(f"  Stats saved to gbm_golden_stats_{dut}.json")

    make_plots(
        price_array,
        sigma_array,
        gaussian_samples_fixed,
        constants,
        price_float,
        sigma_float,
        label=f"Fixed-Point {dut}",
    )
    export_reference_csv(
        price_array, sigma_array, gaussian_samples_fixed, filename=f"gbm_golden_reference_{dut}.csv"
    )


def mode_generate(z_csv_path: str | None = None, dut: str = "euler") -> None:
    """Generates the reference CSV plus the $readmemh hex from either an external Z CSV or fresh samples.

    Args:
        z_csv_path: The optional path to a CSV holding pre-generated Q4.12 Z samples; fresh samples are drawn when
            omitted.
        dut: The architecture under test, either "euler" or "logspace".
    """
    print("\n" + "#" * 70)
    print(f"#  GBM GOLDEN MODEL - Reference CSV Generation ({dut.upper()})")
    print("#" * 70)

    constants = build_constants(TICK_INTERVAL_YEARS)

    if z_csv_path and Path(z_csv_path).exists():
        print(f"\n  Loading Z samples from: {z_csv_path}")
        z_values: list[int] = []
        with open(z_csv_path, "r") as csv_file:
            reader = csv.DictReader(csv_file)
            for row in reader:
                z_values.append(int(row.get("z_q412", row.get("sample", 0))))
        gaussian_samples_fixed = np.array(z_values[:GENERATE_TICK_COUNT], dtype=np.int64)
        print(f"  Loaded {len(gaussian_samples_fixed)} Z samples.")
    else:
        print(f"\n  Generating fresh Gaussian samples (seed=0x{RNG_SEED:08X})...")
        rng = np.random.default_rng(RNG_SEED)
        gaussian_samples_real = rng.standard_normal(GENERATE_TICK_COUNT)
        gaussian_samples_fixed = np.array(
            [quantize_gaussian(sample) for sample in gaussian_samples_real], dtype=np.int64
        )

    print(f"  Running simulation ({len(gaussian_samples_fixed):,} ticks, dut={dut})...")
    price_array, sigma_array = run_simulation(gaussian_samples_fixed, constants, FEEDBACK_ENABLED, dut=dut)

    export_reference_csv(
        price_array, sigma_array, gaussian_samples_fixed, filename=f"gbm_golden_reference_{dut}.csv"
    )
    export_gaussian_samples_hex(gaussian_samples_fixed)
    print(f"\n  Done. Use z_samples.hex with $readmemh in your testbench.")


def mode_compare(z_csv_path: str | None, sim_csv_path: str, dut: str = "euler") -> None:
    """Loads a Z CSV and a ModelSim CSV and exits with status zero when the runs agree bit-for-bit.

    Args:
        z_csv_path: The path to the Q4.12 Z-sample CSV that drove the ModelSim run.
        sim_csv_path: The path to the ModelSim-emitted price/sigma CSV.
        dut: The architecture under test, either "euler" or "logspace".
    """
    print("\n" + "#" * 70)
    print(f"#  GBM GOLDEN MODEL - Bit-Exact Comparison ({dut.upper()})")
    print("#" * 70)

    constants = build_constants(TICK_INTERVAL_YEARS)

    if not z_csv_path or not Path(z_csv_path).exists():
        print(f"ERROR: Z sample CSV not found: {z_csv_path}")
        sys.exit(1)

    z_values: list[int] = []
    with open(z_csv_path, "r") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            z_values.append(int(row.get("z_int_q412", row.get("z_q412", 0))))
    gaussian_samples_fixed = np.array(z_values, dtype=np.int64)

    passed = compare_with_modelsim(sim_csv_path, gaussian_samples_fixed, constants, dut=dut)
    sys.exit(0 if passed else 1)


def mode_compare_both(z_csv_path: str | None = None) -> None:
    """Runs both Euler and log-space architectures on the same Z trace and produces side-by-side comparison plots.

    Args:
        z_csv_path: The optional path to a Z CSV; falls back to gbm_golden_reference_euler.csv when omitted.
    """
    print("\n" + "#" * 70)
    print("#  GBM GOLDEN MODEL - Architecture Comparison")
    print("#" * 70)

    constants = build_constants(TICK_INTERVAL_YEARS)

    reference_csv_path = (
        z_csv_path if (z_csv_path and Path(z_csv_path).exists()) else "gbm_golden_reference_euler.csv"
    )
    print(f"  Loading Z samples from {reference_csv_path}...")

    z_values: list[int] = []
    with open(reference_csv_path, "r") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            z_values.append(int(row.get("z_int_q412", row.get("z_q412", 0))))
    gaussian_samples_fixed = np.array(z_values[:GENERATE_TICK_COUNT], dtype=np.int64)
    print(f"  Loaded {len(gaussian_samples_fixed)} Z samples.")

    print("  Running Euler simulation...")
    price_euler, sigma_euler = run_simulation(gaussian_samples_fixed, constants, FEEDBACK_ENABLED, dut="euler")

    print("  Running Log-Space simulation...")
    price_logspace, sigma_logspace = run_simulation(
        gaussian_samples_fixed, constants, FEEDBACK_ENABLED, dut="logspace"
    )

    print("  Running Float64 reference...")
    gaussian_samples_real_reference = np.array(
        [from_fixed(int(sample), GAUSSIAN_FRACTION_BITS) for sample in gaussian_samples_fixed]
    )
    price_float, sigma_float = run_float_reference(gaussian_samples_real_reference, constants)

    results_euler = run_statistical_tests(price_euler, constants, label="Euler-Maruyama Q8.24")
    results_logspace = run_statistical_tests(price_logspace, constants, label="Log-Space Q8.24")

    print("\n  ── Euler-Maruyama ──")
    print_test_results(results_euler)
    print("\n  ── Log-Space ──")
    print_test_results(results_logspace)

    with open("gbm_comparison_stats.json", "w", encoding="utf-8") as stats_file:
        json.dump({"euler": results_euler, "logspace": results_logspace}, stats_file, indent=2)
    print("\n  Stats saved to gbm_comparison_stats.json")

    make_comparison_plots(
        price_euler,
        sigma_euler,
        price_logspace,
        sigma_logspace,
        price_float,
        sigma_float,
        gaussian_samples_fixed,
        constants,
    )


def main() -> None:
    """Parses CLI flags and dispatches to the validate, generate, compare, or compare_both mode handler."""
    global TICK_INTERVAL_YEARS

    parser = argparse.ArgumentParser(description="GBM Fixed-Point Golden Model")
    parser.add_argument(
        "--mode", choices=["validate", "generate", "compare", "compare_both"], default="validate"
    )
    parser.add_argument(
        "--dut", choices=["euler", "logspace"], default="euler", help="Architecture: euler or logspace"
    )
    parser.add_argument("--z_csv", default=None)
    parser.add_argument("--sim_csv", default=None)
    parser.add_argument("--dt", type=float, default=None)
    args = parser.parse_args()

    if args.dt is not None:
        TICK_INTERVAL_YEARS = args.dt

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
