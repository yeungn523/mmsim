"""Python golden model for the CLT-12 and Ziggurat hardware Gaussian generators.

Produces bit-exact reference streams in Q1.15 fixed point, runs statistical analysis against a
clean reference Gaussian, and emits the consolidated `results.json` consumed by downstream
visualization and reporting tools.
"""

import json
from pathlib import Path

import numpy as np
from numpy.typing import NDArray
from scipy import stats as scipy_stats

from ziggurat_tables_golden import LAYER_VOLUME_V, TAIL_START_R

_Q15_SCALE: int = 1 << 15           # Q1.15 scale factor (32768)
_Q15_MAX: int = 32767
_Q15_MIN: int = -32768
_WORD_MASK: int = 0xFFFFFFFF
_WORD_SPACE: float = 2.0 ** 32
_POLYNOMIALS: list[int] = [0xB4BCD35C, 0xD4E63F5B, 0xA3E1B2C4, 0xF12A4C3D]
_DEFAULT_SEEDS: list[int] = [0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0xABCDEF01]
_SAMPLE_COUNT: int = 100_000
_CLT_DIVISOR: float = 16.0
_ZIGGURAT_DIVISOR: float = 4.0
_REFERENCE_SIGMA: float = 0.25
_HISTOGRAM_BINS: int = 80
_HISTOGRAM_RANGE: tuple[float, float] = (-1.5, 1.5)
_QQ_POINT_COUNT: int = 200
_TAIL_POINT_COUNT: int = 50
_TAIL_SIGMA_MIN: float = 0.5
_TAIL_SIGMA_MAX: float = 4.5
_TAIL_FLOOR: float = 1e-9
_SAMPLE_WINDOW_SIZE: int = 500
_CLT_STREAM_COUNT: int = 12
_SIGN_BIT_MASK: int = 0x100
_LAYER_INDEX_MASK: int = 0xFF
_XI_FRACTION_MASK: int = 0x7FFFFF
_XI_FRACTION_BITS: int = 23
_RESULTS_OUTPUT_PATH: Path = Path(__file__).resolve().parent / "results.json"


def to_q1_15(value: float) -> int:
    """Converts a floating-point value to its Q1.15 signed 16-bit representation.

    Args:
        value: The floating-point value to quantize.

    Returns:
        The Q1.15 integer saturated to the signed 16-bit range.
    """
    scaled = int(round(value * _Q15_SCALE))
    return max(_Q15_MIN, min(_Q15_MAX, scaled))


def from_q1_15(value: int) -> float:
    """Converts a Q1.15 signed integer back to its floating-point representation.

    Args:
        value: The Q1.15 integer to dequantize.

    Returns:
        The dequantized floating-point value.
    """
    return value / _Q15_SCALE


def galois_lfsr(state: int, polynomial: int) -> int:
    """Advances a 32-bit Galois LFSR by one step.

    Args:
        state: The current 32-bit LFSR state.
        polynomial: The feedback polynomial applied when the least significant bit is set.

    Returns:
        The next 32-bit LFSR state, masked to 32 bits.
    """
    least_significant_bit = state & 1
    state >>= 1
    if least_significant_bit:
        state ^= polynomial
    return state & _WORD_MASK


def lfsr_to_uniform(state: int) -> float:
    """Maps a 32-bit LFSR state to a uniform sample in [0, 1).

    Args:
        state: The 32-bit LFSR state.

    Returns:
        The uniform sample with resolution 2**-32.
    """
    return (state & _WORD_MASK) / _WORD_SPACE


class CLT12Generator:
    """Reference implementation of the CLT-12 Gaussian generator.

    Sums twelve independent Uniform[0, 1) samples drawn from a bank of four Galois LFSRs and
    subtracts the mean to approximate a unit-variance Gaussian sample per draw.

    Args:
        seeds: The initial 32-bit LFSR states. Exactly four seeds are expected, matching the
            hardware polynomial bank.

    Attributes:
        _states: The mutable list of current LFSR states, one per stream.
    """

    def __init__(self, seeds: list[int]) -> None:
        self._states: list[int] = list(seeds)

    def next_raw(self) -> float:
        """Draws a single centered CLT-12 sample in native float units.

        Returns:
            The sum of twelve uniform draws recentered to zero mean.
        """
        total = 0.0
        for index in range(_CLT_STREAM_COUNT):
            stream_index = index % len(_POLYNOMIALS)
            self._states[stream_index] = galois_lfsr(
                state=self._states[stream_index],
                polynomial=_POLYNOMIALS[stream_index],
            )
            total += lfsr_to_uniform(state=self._states[stream_index])
        return total - 6.0

    def generate(self, sample_count: int) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
        """Generates a stream of CLT-12 samples in both float and quantized form.

        Args:
            sample_count: The number of samples to draw.

        Returns:
            A tuple containing the unscaled float samples and the Q1.15-round-tripped samples.
        """
        floats: list[float] = []
        quantized: list[float] = []
        for _ in range(sample_count):
            raw = self.next_raw()
            scaled = raw / _CLT_DIVISOR
            floats.append(scaled)
            quantized.append(from_q1_15(value=to_q1_15(value=scaled)))
        return (
            np.array(floats, dtype=np.float64),
            np.array(quantized, dtype=np.float64),
        )


def build_ziggurat_tables(layer_count: int = 256) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """Builds the in-memory Ziggurat layer tables used by the golden model.

    Notes:
        Uses the tail-start and layer-volume constants emitted by `gen_ziggurat_tables.py`
        (`TAIL_START_R` and `LAYER_VOLUME_V`) so that the golden model agrees with the
        quantized hardware tables.

    Args:
        layer_count: The number of Ziggurat layers.

    Returns:
        A tuple containing the x-coordinate table and the y-coordinate table, each of length
        `layer_count + 1`.
    """
    tail_start = TAIL_START_R
    layer_volume = LAYER_VOLUME_V
    x_table = np.zeros(layer_count + 1, dtype=np.float64)
    y_table = np.zeros(layer_count + 1, dtype=np.float64)
    x_table[layer_count] = layer_volume / np.exp(-0.5 * tail_start * tail_start)
    x_table[layer_count - 1] = tail_start
    y_table[layer_count - 1] = np.exp(-0.5 * tail_start * tail_start)
    for index in range(layer_count - 2, 0, -1):
        x_table[index] = np.sqrt(
            -2.0 * np.log(layer_volume / x_table[index + 1] + np.exp(-0.5 * x_table[index + 1] ** 2))
        )
        y_table[index] = np.exp(-0.5 * x_table[index] ** 2)
    x_table[0] = 0.0
    y_table[0] = 1.0
    return x_table, y_table


class ZigguratGenerator:
    """Reference implementation of the Ziggurat Gaussian generator.

    Uses the Marsaglia and Tsang (2000) construction with a 256-layer tiling and a
    log-uniform fallback for the tail.

    Args:
        seeds: The initial 32-bit LFSR states. Exactly four seeds are expected.
        layer_count: The number of Ziggurat layers.

    Attributes:
        _states: The mutable list of current LFSR states, one per stream.
        _layer_count: The number of Ziggurat layers.
        _x_table: The x-coordinate table produced by `build_ziggurat_tables`.
        _y_table: The y-coordinate table produced by `build_ziggurat_tables`.
    """

    def __init__(self, seeds: list[int], layer_count: int = 256) -> None:
        self._states: list[int] = list(seeds)
        self._layer_count: int = layer_count
        self._x_table, self._y_table = build_ziggurat_tables(layer_count=layer_count)

    def _tick(self, stream_index: int) -> int:
        """Advances the selected LFSR stream by one step and returns the new state.

        Args:
            stream_index: The index of the LFSR stream to advance.

        Returns:
            The updated 32-bit LFSR state.
        """
        self._states[stream_index] = galois_lfsr(
            state=self._states[stream_index],
            polynomial=_POLYNOMIALS[stream_index],
        )
        return self._states[stream_index]

    def next_raw(self) -> float:
        """Draws a single Ziggurat sample in native float units.

        Returns:
            A signed Gaussian sample in native float units.
        """
        while True:
            fast_state = self._tick(stream_index=0)
            wedge_state = self._tick(stream_index=1)
            layer = fast_state & _LAYER_INDEX_MASK
            sign = 1 if (fast_state & _SIGN_BIT_MASK) else -1
            xi_fraction = (fast_state >> 9) & _XI_FRACTION_MASK
            x_value = (xi_fraction / (1 << _XI_FRACTION_BITS)) * self._x_table[layer]

            if layer > 0 and x_value < self._x_table[layer - 1]:
                return sign * x_value

            if layer == 0:
                while True:
                    exponent1 = -np.log((self._tick(stream_index=2) + 0.5) / _WORD_SPACE)
                    exponent2 = -np.log((self._tick(stream_index=3) + 0.5) / _WORD_SPACE)
                    if 2 * exponent2 >= exponent1 * exponent1:
                        return sign * (self._x_table[1] + exponent1)

            y_value = self._y_table[layer] + (wedge_state / _WORD_SPACE) * (
                self._y_table[layer - 1] - self._y_table[layer]
            )
            if y_value < np.exp(-0.5 * x_value * x_value):
                return sign * x_value

    def generate(self, sample_count: int) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
        """Generates a stream of Ziggurat samples in both float and quantized form.

        Args:
            sample_count: The number of samples to draw.

        Returns:
            A tuple containing the unscaled float samples and the Q1.15-round-tripped samples.
        """
        floats: list[float] = []
        quantized: list[float] = []
        for _ in range(sample_count):
            raw = self.next_raw()
            scaled = raw / _ZIGGURAT_DIVISOR
            floats.append(scaled)
            quantized.append(from_q1_15(value=to_q1_15(value=scaled)))
        return (
            np.array(floats, dtype=np.float64),
            np.array(quantized, dtype=np.float64),
        )


def analyze(name: str, samples: NDArray[np.float64]) -> dict[str, float | int | str]:
    """Computes summary statistics and a KS normality check for the provided samples.

    Notes:
        The CLT-12 distribution has a known theoretical excess kurtosis of -0.6, which shows up
        as a persistent deviation from zero in the returned statistics.

    Args:
        name: The generator label used in the returned dictionary and downstream reports.
        samples: The sample stream to analyze in native float units.

    Returns:
        A mapping of statistic name to value, including mean, standard deviation, skewness,
        excess kurtosis, KS statistic and p-value, and empirical and theoretical tail
        probabilities at the 2- and 3-sigma cutoffs.
    """
    sample_std = float(np.std(samples))
    ks_statistic, ks_p_value = scipy_stats.kstest(samples, "norm", args=(0, sample_std))
    tail_two_sigma_actual = float(np.mean(np.abs(samples) > 2 * sample_std))
    tail_three_sigma_actual = float(np.mean(np.abs(samples) > 3 * sample_std))
    tail_two_sigma_theory = float(2 * (1 - scipy_stats.norm.cdf(2)))
    tail_three_sigma_theory = float(2 * (1 - scipy_stats.norm.cdf(3)))

    return {
        "name": name,
        "n": int(samples.size),
        "mean": float(np.mean(samples)),
        "std": sample_std,
        "skewness": float(scipy_stats.skew(samples)),
        "excess_kurtosis": float(scipy_stats.kurtosis(samples)),
        "ks_statistic": float(ks_statistic),
        "ks_p_value": float(ks_p_value),
        "tail_2sigma_actual": tail_two_sigma_actual,
        "tail_2sigma_theory": tail_two_sigma_theory,
        "tail_2sigma_error_pct": abs(tail_two_sigma_actual - tail_two_sigma_theory) / tail_two_sigma_theory * 100,
        "tail_3sigma_actual": tail_three_sigma_actual,
        "tail_3sigma_theory": tail_three_sigma_theory,
        "tail_3sigma_error_pct": abs(tail_three_sigma_actual - tail_three_sigma_theory) / tail_three_sigma_theory * 100,
    }


def make_histogram(
    samples: NDArray[np.float64],
    bin_count: int = _HISTOGRAM_BINS,
    histogram_range: tuple[float, float] = _HISTOGRAM_RANGE,
) -> dict[str, list[float]]:
    """Builds a density-normalized histogram of the samples.

    Args:
        samples: The sample stream to histogram.
        bin_count: The number of histogram bins.
        histogram_range: The (lower, upper) histogram range.

    Returns:
        A mapping with the bin centers and density counts.
    """
    counts, edges = np.histogram(samples, bins=bin_count, range=histogram_range, density=True)
    centers = [(edges[index] + edges[index + 1]) / 2 for index in range(len(edges) - 1)]
    return {
        "centers": [round(center, 5) for center in centers],
        "counts": [round(float(count), 5) for count in counts],
    }


def make_qq(samples: NDArray[np.float64], point_count: int = _QQ_POINT_COUNT) -> dict[str, list[float]]:
    """Builds theoretical vs empirical quantile pairs for a Q-Q plot.

    Args:
        samples: The sample stream.
        point_count: The number of Q-Q points to emit.

    Returns:
        A mapping with the theoretical and empirical quantiles.
    """
    sorted_samples = np.sort(samples)
    sample_count = len(sorted_samples)
    selection = np.linspace(0, sample_count - 1, point_count, dtype=int)
    empirical = sorted_samples[selection]
    theoretical = scipy_stats.norm.ppf(np.linspace(0.5 / sample_count, 1 - 0.5 / sample_count, sample_count)[selection])
    return {
        "theoretical": [round(float(value), 5) for value in theoretical],
        "empirical": [round(float(value), 5) for value in empirical],
    }


def make_tail_data(samples: NDArray[np.float64], point_count: int = _TAIL_POINT_COUNT) -> dict[str, list[float]]:
    """Builds empirical and theoretical tail-probability curves versus sigma cutoff.

    Args:
        samples: The sample stream.
        point_count: The number of sigma cutoff points.

    Returns:
        A mapping with the sigma cutoffs, empirical tail probabilities, and theoretical
        tail probabilities.
    """
    sample_std = np.std(samples)
    sigma_axis = np.linspace(_TAIL_SIGMA_MIN, _TAIL_SIGMA_MAX, point_count)
    empirical = [max(float(np.mean(np.abs(samples) > sigma * sample_std)), _TAIL_FLOOR) for sigma in sigma_axis]
    theoretical = [float(2 * (1 - scipy_stats.norm.cdf(sigma))) for sigma in sigma_axis]
    return {
        "k_values": [round(float(sigma), 3) for sigma in sigma_axis],
        "empirical": empirical,
        "theoretical": theoretical,
    }


def _print_analysis(statistics: dict[str, float | int | str]) -> None:
    """Prints the per-generator analysis block in the expected layout.

    Args:
        statistics: The mapping returned by `analyze`.
    """
    print(f"\n{statistics['name']}")
    print(f"  Mean:            {float(statistics['mean']):+.6f}")
    print(f"  Std:             {float(statistics['std']):.6f}")
    print(f"  Skewness:        {float(statistics['skewness']):+.6f}")
    print(f"  Excess Kurtosis: {float(statistics['excess_kurtosis']):+.6f}  (CLT-12 theoretical: -0.6)")
    print(f"  KS statistic:    {float(statistics['ks_statistic']):.6f}")
    print(f"  KS p-value:      {float(statistics['ks_p_value']):.4f}")
    print(f"  2sigma tail err: {float(statistics['tail_2sigma_error_pct']):.2f}%")
    print(f"  3sigma tail err: {float(statistics['tail_3sigma_error_pct']):.2f}%")


def main() -> None:
    """Generates reference sample streams, runs statistical analysis, and writes results.json."""
    print(f"Generating {_SAMPLE_COUNT:,} samples from each generator...")
    clt = CLT12Generator(seeds=_DEFAULT_SEEDS[:])
    ziggurat = ZigguratGenerator(seeds=_DEFAULT_SEEDS[:])

    _, clt_quantized = clt.generate(sample_count=_SAMPLE_COUNT)
    print("  CLT-12 done")
    _, ziggurat_quantized = ziggurat.generate(sample_count=_SAMPLE_COUNT)
    print("  Ziggurat done")

    rng = np.random.default_rng(seed=42)
    reference_samples = rng.normal(loc=0.0, scale=_REFERENCE_SIGMA, size=_SAMPLE_COUNT)
    print("  Reference Gaussian done")

    print("Running statistical analysis...")
    clt_stats = analyze(name="CLT-12", samples=clt_quantized)
    ziggurat_stats = analyze(name="Ziggurat", samples=ziggurat_quantized)
    reference_stats = analyze(name="Reference", samples=reference_samples)

    for statistics in (clt_stats, ziggurat_stats, reference_stats):
        _print_analysis(statistics=statistics)

    output = {
        "metadata": {
            "n_samples": _SAMPLE_COUNT,
            "seeds": [hex(seed) for seed in _DEFAULT_SEEDS],
            "q_format": "Q1.15",
            "scale_factor": "div4",
        },
        "stats": {
            "clt12": clt_stats,
            "ziggurat": ziggurat_stats,
            "reference": reference_stats,
        },
        "histograms": {
            "clt12": make_histogram(samples=clt_quantized),
            "ziggurat": make_histogram(samples=ziggurat_quantized),
            "reference": make_histogram(samples=reference_samples),
        },
        "qq_plots": {
            "clt12": make_qq(samples=clt_quantized),
            "ziggurat": make_qq(samples=ziggurat_quantized),
        },
        "tail_analysis": {
            "clt12": make_tail_data(samples=clt_quantized),
            "ziggurat": make_tail_data(samples=ziggurat_quantized),
            "reference": make_tail_data(samples=reference_samples),
        },
        "sample_window": {
            "clt12": [round(float(value), 6) for value in clt_quantized[:_SAMPLE_WINDOW_SIZE]],
            "ziggurat": [round(float(value), 6) for value in ziggurat_quantized[:_SAMPLE_WINDOW_SIZE]],
        },
    }

    _RESULTS_OUTPUT_PATH.write_text(json.dumps(output, indent=2))
    print(f"\nSaved {_RESULTS_OUTPUT_PATH}")


if __name__ == "__main__":
    main()
