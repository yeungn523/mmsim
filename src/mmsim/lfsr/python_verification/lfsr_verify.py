"""Verifies the Galois LFSR ModelSim output against a Python golden model."""

import csv
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from numpy.typing import NDArray

_DEFAULT_SEED: int = 0xDEADBEEF
_DEFAULT_POLY: int = 0xB4BCD35C
_WORD_MASK: int = 0xFFFFFFFF
_BITS_PER_WORD: int = 32
_SAMPLES_CSV: Path = Path("lfsr_samples.csv")
_HISTOGRAM_BIN_COUNT: int = 100
_UNIFORMITY_TOLERANCE: float = 0.01
_PREVIEW_VALUE_COUNT: int = 8
_PLOT_OUTPUT_PATH: Path = Path("lfsr_uniform_distribution.png")


def galois_lfsr_step(state: int, polynomial: int = _DEFAULT_POLY) -> int:
    """Advances the 32-bit Galois LFSR by one step.

    Args:
        state: The current 32-bit LFSR state interpreted as an unsigned integer.
        polynomial: The Galois feedback polynomial applied when the least significant bit of
            the current state is set.

    Returns:
        The next 32-bit LFSR state, masked to 32 bits.
    """
    least_significant_bit = state & 1
    state >>= 1
    if least_significant_bit:
        state ^= polynomial
    return state & _WORD_MASK


def generate_reference_sequence(seed: int, polynomial: int, length: int) -> list[int]:
    """Generates a reference LFSR sequence produced by the Python golden model.

    Args:
        seed: The initial 32-bit state seeded into the LFSR before the first step.
        polynomial: The Galois feedback polynomial applied at every step.
        length: The number of successive states to produce.

    Returns:
        The list of successive LFSR states, ordered from the first step to the last.
    """
    state = seed
    sequence: list[int] = []
    for _ in range(length):
        state = galois_lfsr_step(state=state, polynomial=polynomial)
        sequence.append(state)
    return sequence


def load_samples(csv_path: Path) -> NDArray[np.uint32]:
    """Loads the LFSR samples emitted by the ModelSim testbench CSV.

    Args:
        csv_path: The path to the CSV file written by the testbench, containing a `value` column
            with one unsigned 32-bit sample per row.

    Returns:
        A one-dimensional array of the hardware samples in capture order.
    """
    samples: list[int] = []
    with csv_path.open(newline="") as csv_file:
        reader = csv.DictReader(csv_file)
        for row in reader:
            samples.append(int(row["value"]))
    return np.array(samples, dtype=np.uint32)


def print_expected_values(seed: int, polynomial: int, count: int) -> None:
    """Prints the first LFSR outputs in the Verilog literal format expected by the testbench.

    Args:
        seed: The initial 32-bit state seeded into the golden LFSR model.
        polynomial: The Galois feedback polynomial used by the golden LFSR model.
        count: The number of successive outputs to print, intended to match the size of the
            testbench's `expected[]` array.
    """
    print(f"First {count} LFSR values (paste into Test 10 expected[]):")
    state = seed
    for index in range(count):
        state = galois_lfsr_step(state=state, polynomial=polynomial)
        print(f"  expected[{index}] = 32'h{state:08X};")


def evaluate_bit_uniformity(samples: NDArray[np.uint32]) -> float:
    """Evaluates the fraction of set bits across the concatenated sample stream.

    Args:
        samples: The array of hardware LFSR samples.

    Returns:
        The ratio of set bits to total bits across the full stream. An ideal primitive LFSR
        produces a ratio very close to 0.5.
    """
    total_bits = samples.size * _BITS_PER_WORD
    ones = int(sum(bin(int(value) & _WORD_MASK).count("1") for value in samples))
    return ones / total_bits


def count_zero_states(samples: NDArray[np.uint32]) -> int:
    """Counts the number of zero-valued samples in the stream.

    Args:
        samples: The array of hardware LFSR samples.

    Returns:
        The number of samples equal to zero. A primitive-polynomial LFSR must never produce
        zero, so a non-zero result indicates a hardware defect.
    """
    return int(np.sum(samples == 0))


def count_sequence_mismatches(samples: NDArray[np.uint32], reference: list[int]) -> int:
    """Counts positions where the hardware samples differ from the golden reference.

    Args:
        samples: The array of hardware LFSR samples in capture order.
        reference: The golden reference sequence of the same length as the samples.

    Returns:
        The number of positions at which the hardware and reference sequences disagree.
    """
    return int(sum(1 for actual, expected in zip(samples.tolist(), reference) if actual != expected))


def plot_uniform_distribution(samples: NDArray[np.uint32], output_path: Path) -> None:
    """Plots a histogram of the LFSR samples against the ideal uniform count.

    Args:
        samples: The array of hardware LFSR samples to histogram.
        output_path: The destination path for the saved high-resolution image.
    """
    expected_count = samples.size / _HISTOGRAM_BIN_COUNT

    plt.figure(figsize=(10, 6))
    plt.hist(
        samples,
        bins=_HISTOGRAM_BIN_COUNT,
        range=(0, _WORD_MASK),
        color="#4C72B0",
        edgecolor="black",
        linewidth=0.5,
        alpha=0.8,
    )
    plt.axhline(
        expected_count,
        color="#C44E52",
        linestyle="--",
        linewidth=2,
        label=f"Ideal uniform count ({expected_count:,.0f})",
    )
    plt.title(f"Galois LFSR output distribution ({samples.size:,} samples)", fontsize=14, pad=15)
    plt.xlabel("32-bit output value", fontsize=12)
    plt.ylabel("Frequency", fontsize=12)
    plt.ticklabel_format(style="sci", axis="x", scilimits=(0, 0))
    plt.xlim(0, _WORD_MASK)
    plt.legend(fontsize=11)
    plt.grid(axis="y", linestyle="--", alpha=0.7)
    plt.tight_layout()
    plt.savefig(output_path, dpi=300)
    print(f"Saved high-resolution plot for the lab report as: {output_path}")
    plt.show()


def main() -> None:
    """Runs the LFSR verification pipeline.

    Prints the reference sequence expected by the testbench, cross-checks the captured
    ModelSim samples for bit uniformity, zero-state freedom, and sequence equivalence, and
    emits a uniform-distribution histogram. Exits early with a notice if the sample CSV is
    missing.
    """
    print_expected_values(
        seed=_DEFAULT_SEED,
        polynomial=_DEFAULT_POLY,
        count=_PREVIEW_VALUE_COUNT,
    )

    if not _SAMPLES_CSV.exists():
        print(f"\n{_SAMPLES_CSV} not found - run ModelSim first")
        return

    samples = load_samples(csv_path=_SAMPLES_CSV)
    print(f"\nCross-check: {samples.size} samples from ModelSim CSV")

    ones_ratio = evaluate_bit_uniformity(samples=samples)
    uniformity_passes = abs(ones_ratio - 0.5) < _UNIFORMITY_TOLERANCE
    print(f"  Ones ratio:    {ones_ratio:.5f}  (ideal 0.50000)")
    print(f"  Uniformity:    {'PASS' if uniformity_passes else 'FAIL'}")

    zero_count = count_zero_states(samples=samples)
    print(f"  Zero states:   {zero_count}  (should be 0)")

    reference = generate_reference_sequence(
        seed=_DEFAULT_SEED,
        polynomial=_DEFAULT_POLY,
        length=samples.size,
    )
    mismatches = count_sequence_mismatches(samples=samples, reference=reference)
    match_count = samples.size - mismatches
    mismatch_summary = "PASS" if mismatches == 0 else f"FAIL ({mismatches} mismatches)"
    print(f"  Sequence match: {match_count}/{samples.size} correct")
    print(f"  Result:         {mismatch_summary}")

    print("\nGenerating uniform distribution histogram...")
    plot_uniform_distribution(samples=samples, output_path=_PLOT_OUTPUT_PATH)


if __name__ == "__main__":
    main()
