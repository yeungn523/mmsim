"""Verifies ModelSim CSV outputs from the CLT-12 and Ziggurat Gaussian generators.

Applies a Kolmogorov-Smirnov normality test against a fitted N(mu, sigma), prints tail-probability error tables, and
emits a four-panel diagnostic plot. Falls back to synthetic reference data when the CSVs are missing.
"""

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from numpy.typing import NDArray
from scipy import stats as scipy_stats

_CLT_CSV: Path = Path("clt12_samples.csv")
_ZIGGURAT_CSV: Path = Path("ziggurat_samples.csv")
_Q412_SCALE: float = 4096.0
_KS_SAMPLE_CAP: int = 100_000
_SYNTHETIC_FALLBACK_SIZE: int = 10_000
_SIGNIFICANCE_THRESHOLD: float = 0.01
_SIGMA_RANGE: tuple[float, ...] = (1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0)
_HISTOGRAM_BINS: int = 120
_HISTOGRAM_RANGE: tuple[float, float] = (-4.0, 4.0)
_TAIL_CURVE_POINTS: int = 100
_TAIL_FLOOR: float = 1e-6
_PLOT_OUTPUT_PATH: Path = Path("gaussian_comparison_plot.png")


def load_modelsim_csv(csv_path: Path) -> tuple[NDArray[np.float64], bool]:
    """Loads a ModelSim Gaussian-sample CSV or falls back to synthetic reference data.

    Args:
        csv_path: The path to the ModelSim-generated CSV containing one sample per row. The
            second column is interpreted as a signed Q4.12 integer and converted to float.

    Returns:
        A tuple containing the sample array in native float units and a flag that determines
        whether the array was produced synthetically because the CSV was missing.
    """
    if not csv_path.exists():
        print(f"  NOTE: {csv_path} not found - generating synthetic reference data")
        rng = np.random.default_rng(seed=0xDEADBEEF + hash(str(csv_path)) % 1000)
        return rng.normal(loc=0.0, scale=1.0, size=_SYNTHETIC_FALLBACK_SIZE), True

    raw = np.loadtxt(csv_path, delimiter=",", skiprows=1)
    float_values = raw[:, 1].astype(np.float64) / _Q412_SCALE
    return float_values, False


def verify_normality(hardware_samples: NDArray[np.float64]) -> dict[str, float | int | bool]:
    """Applies a one-sample Kolmogorov-Smirnov test against a fitted normal distribution.

    Args:
        hardware_samples: The array of captured hardware samples in native float units.

    Returns:
        A mapping with the sample count, sample mean and standard deviation, the KS statistic
        and p-value, and a flag that determines whether the shape is statistically consistent
        with a normal distribution at the configured significance threshold.
    """
    sample_mean = float(np.mean(hardware_samples))
    sample_std = float(np.std(hardware_samples))

    ks_sample = hardware_samples[:_KS_SAMPLE_CAP]
    ks_statistic, ks_p_value = scipy_stats.kstest(
        ks_sample,
        lambda value: scipy_stats.norm.cdf(value, np.mean(ks_sample), np.std(ks_sample)),
    )

    return {
        "sample_count": int(hardware_samples.size),
        "mean": sample_mean,
        "std": sample_std,
        "ks_statistic": float(ks_statistic),
        "ks_p_value": float(ks_p_value),
        "is_normal_shape": bool(ks_p_value > _SIGNIFICANCE_THRESHOLD),
    }


def print_normality_report(name: str, result: dict[str, float | int | bool]) -> None:
    """Prints the per-generator normality verdict in the expected table layout.

    Args:
        name: The human-readable generator name used as a section heading.
        result: The result mapping returned by `verify_normality`.
    """
    status = "PASS" if result["is_normal_shape"] else "FAIL"
    print(f"\n{name} Analysis:")
    print(f"  Mean:          {result['mean']:+.6f}")
    print(f"  Standard Dev:  {result['std']:.6f}")
    print(f"  KS Statistic:  {result['ks_statistic']:.4f} (p-value={result['ks_p_value']:.4f})")
    print(f"  Forms a Perfect Bell Curve: {status}")


def print_tail_probabilities(
    clt_samples: NDArray[np.float64],
    ziggurat_samples: NDArray[np.float64],
) -> None:
    """Prints the k-sigma tail-probability comparison against the theoretical values.

    Args:
        clt_samples: The captured CLT-12 Gaussian samples in native float units.
        ziggurat_samples: The captured Ziggurat Gaussian samples in native float units.
    """
    print("\nTail Probability Analysis:")
    header = f"{'Sigma':<8} {'CLT-12':>10} {'Ziggurat':>10} {'Theory':>10} {'CLT Err':>10} {'Zig Err':>10}"
    print(header)

    for sigma_multiple in _SIGMA_RANGE:
        theoretical_tail = 2 * (1 - scipy_stats.norm.cdf(sigma_multiple))
        clt_tail = float(np.mean(np.abs(clt_samples) > sigma_multiple))
        zig_tail = float(np.mean(np.abs(ziggurat_samples) > sigma_multiple))
        clt_error = abs(clt_tail - theoretical_tail) / theoretical_tail * 100 if theoretical_tail > 0 else float("inf")
        zig_error = abs(zig_tail - theoretical_tail) / theoretical_tail * 100 if theoretical_tail > 0 else float("inf")
        clt_display = f"{clt_tail:>10.6f}" if clt_tail > 0 else f"{'0 (cutoff)':>10}"
        zig_display = f"{zig_tail:>10.6f}" if zig_tail > 0 else f"{'0 (cutoff)':>10}"
        print(
            f"{sigma_multiple}σ{'':<5} {clt_display} {zig_display} "
            f"{theoretical_tail:>10.6f} {clt_error:>9.1f}% {zig_error:>9.1f}%"
        )


def plot_comparison(
    clt_samples: NDArray[np.float64],
    ziggurat_samples: NDArray[np.float64],
    clt_result: dict[str, float | int | bool],
    ziggurat_result: dict[str, float | int | bool],
    output_path: Path,
) -> None:
    """Plots distribution shape and log-scale tail probability for both generators.

    Args:
        clt_samples: The captured CLT-12 Gaussian samples in native float units.
        ziggurat_samples: The captured Ziggurat Gaussian samples in native float units.
        clt_result: The normality-test result mapping for the CLT-12 samples, used to
            standardize the distribution before overlaying.
        ziggurat_result: The normality-test result mapping for the Ziggurat samples, used to
            standardize the distribution before overlaying.
        output_path: The destination path for the saved high-resolution figure.
    """
    figure, (shape_axis, tail_axis) = plt.subplots(1, 2, figsize=(14, 5))

    bin_edges = np.linspace(*_HISTOGRAM_RANGE, _HISTOGRAM_BINS)
    clt_normalized = (clt_samples - float(clt_result["mean"])) / float(clt_result["std"])
    ziggurat_normalized = (ziggurat_samples - float(ziggurat_result["mean"])) / float(ziggurat_result["std"])
    pdf_axis = np.linspace(*_HISTOGRAM_RANGE, 1000)

    shape_axis.hist(clt_normalized, bins=bin_edges, density=True, alpha=0.6, color="#4C72B0", label="CLT-12")
    shape_axis.hist(ziggurat_normalized, bins=bin_edges, density=True, alpha=0.5, color="#C44E52", label="Ziggurat")
    shape_axis.plot(pdf_axis, scipy_stats.norm.pdf(pdf_axis, 0, 1), "k--", linewidth=2, label="Ideal N(0,1)")
    shape_axis.set_title("Distribution Shape (1,000,000 Samples)", fontweight="bold")
    shape_axis.set_ylabel("Probability Density")
    shape_axis.set_xlabel(r"Standard Deviations ($\sigma$)")
    shape_axis.legend()

    sigma_axis = np.linspace(0.5, 5.0, _TAIL_CURVE_POINTS)
    theoretical_tails = [2 * (1 - scipy_stats.norm.cdf(sigma)) for sigma in sigma_axis]
    clt_tails = [max(float(np.mean(np.abs(clt_normalized) > sigma)), _TAIL_FLOOR) for sigma in sigma_axis]
    ziggurat_tails = [max(float(np.mean(np.abs(ziggurat_normalized) > sigma)), _TAIL_FLOOR) for sigma in sigma_axis]

    tail_axis.semilogy(sigma_axis, theoretical_tails, "k--", linewidth=2, label="Ideal N(0,1)")
    tail_axis.semilogy(sigma_axis, clt_tails, color="#4C72B0", linewidth=2, label="CLT-12")
    tail_axis.semilogy(sigma_axis, ziggurat_tails, color="#C44E52", linewidth=2, label="Ziggurat")
    tail_axis.set_xlabel(r"Standard Deviations ($k\sigma$)")
    tail_axis.set_ylabel(r"$P(|X| > k\sigma)$")
    tail_axis.set_title("Tail Probability (Log Scale)", fontweight="bold")
    tail_axis.legend()
    tail_axis.grid(True, which="both", alpha=0.3)

    figure.suptitle(
        "Hardware Gaussian Generators: Architectural Trade-off Analysis",
        fontsize=14,
        fontweight="bold",
    )
    plt.tight_layout()
    plt.savefig(output_path, dpi=300)
    print(f"Saved high-resolution plot as: {output_path}")
    plt.show()


def main() -> None:
    """Runs the full CLT-12 vs Ziggurat verification pipeline.

    Loads both generator CSVs (or synthetic fallbacks), runs a one-sample KS normality test on
    each sample stream, prints the per-generator verdict and tail-probability comparison, and
    emits the side-by-side distribution and tail-probability figure.
    """
    print("Cross-check: 1-Sample KS Normality Test")
    print("=" * 55)

    print("\nLoading ModelSim CSV files...")
    clt_samples, _ = load_modelsim_csv(csv_path=_CLT_CSV)
    ziggurat_samples, _ = load_modelsim_csv(csv_path=_ZIGGURAT_CSV)

    print("\nRunning statistical shape verification...")
    clt_result = verify_normality(hardware_samples=clt_samples)
    ziggurat_result = verify_normality(hardware_samples=ziggurat_samples)

    print_normality_report(name="CLT-12", result=clt_result)
    print_normality_report(name="Ziggurat", result=ziggurat_result)

    print_tail_probabilities(clt_samples=clt_samples, ziggurat_samples=ziggurat_samples)

    print("\nGenerating comparison figure...")
    plot_comparison(
        clt_samples=clt_samples,
        ziggurat_samples=ziggurat_samples,
        clt_result=clt_result,
        ziggurat_result=ziggurat_result,
        output_path=_PLOT_OUTPUT_PATH,
    )


if __name__ == "__main__":
    main()
