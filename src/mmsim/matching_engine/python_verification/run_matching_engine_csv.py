"""Orchestrates the full CSV verification pipeline for the matching_engine module."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import click

from ...utilities import console


def run_stage(description: str, command: list[str], working_directory: Path) -> bool:
    """Executes a subprocess and reports success or failure.

    Args:
        description: A short label identifying the stage being run.
        command: The command and arguments to execute.
        working_directory: The directory to run the command in.

    Returns:
        True when the subprocess exits with code 0, False otherwise.
    """
    console.log(message=f"Stage: {description}")
    console.log(message=f"  Command: {' '.join(command)}")
    console.log(message=f"  Working directory: {working_directory}")

    result = subprocess.run(
        args=command,
        cwd=working_directory,
        capture_output=True,
        text=True,
    )

    if result.stdout.strip():
        print(result.stdout.rstrip())  # noqa: T201

    if result.returncode != 0:
        console.error(message=f"Stage failed with exit code {result.returncode}", exit_code=0)
        if result.stderr.strip():
            print(result.stderr.rstrip())  # noqa: T201
        return False

    console.success(message=f"  {description} complete")
    return True


@click.command()
@click.option("--stress", type=int, default=0, show_default=True,
              help="Forward to the golden model: when >0, generate N back-to-back random "
                   "packets instead of the deterministic regression sweep.")
@click.option("--edge-cases", is_flag=True, default=False,
              help="Forward to the golden model: in stress mode, prepend boundary and "
                   "saturation packets.")
@click.option("--price-distribution", type=click.Choice(["uniform", "gaussian"]),
              default="uniform", show_default=True,
              help="Forward to the golden model: distribution used to sample stress price "
                   "ticks.")
@click.option("--price-mean", type=float, default=None,
              help="Forward to the golden model: Gaussian mean tick.")
@click.option("--price-stddev", type=float, default=None,
              help="Forward to the golden model: Gaussian standard deviation in ticks.")
def main(
    stress: int,
    edge_cases: bool,
    price_distribution: str,
    price_mean: float | None,
    price_stddev: float | None,
) -> None:
    """Run the three-stage CSV verification pipeline for the matching engine."""
    matching_engine_directory = Path(__file__).resolve().parent.parent
    simulation_directory = matching_engine_directory / "sim"
    project_root = matching_engine_directory.parent.parent.parent

    console.log(message="Matching Engine CSV Verification Pipeline", prefix=False)

    golden_command = [
        sys.executable,
        "-m",
        "mmsim.matching_engine.python_verification.matching_engine_golden",
    ]
    if stress > 0:
        golden_command += ["--stress", str(stress)]
        if edge_cases:
            golden_command.append("--edge-cases")
        golden_command += ["--price-distribution", price_distribution]
        if price_mean is not None:
            golden_command += ["--price-mean", str(price_mean)]
        if price_stddev is not None:
            golden_command += ["--price-stddev", str(price_stddev)]

    stage_one_pass = run_stage(
        description="Generate golden model CSVs",
        command=golden_command,
        working_directory=project_root,
    )
    if not stage_one_pass:
        console.error(
            message="Unable to run the verification pipeline. Golden model generation failed.",
            error=RuntimeError,
        )

    packets_csv_path = simulation_directory / "matching_engine_packets.csv"
    expected_csv_path = simulation_directory / "matching_engine_expected.csv"
    if not packets_csv_path.exists() or not expected_csv_path.exists():
        console.error(
            message=(
                f"Golden model did not produce matching_engine_packets.csv and "
                f"matching_engine_expected.csv in {simulation_directory}."
            ),
            error=FileNotFoundError,
        )

    console.log(message=f"  matching_engine_packets.csv: {packets_csv_path.stat().st_size} bytes")
    console.log(
        message=f"  matching_engine_expected.csv: {expected_csv_path.stat().st_size} bytes",
    )

    stage_two_pass = run_stage(
        description="Run Verilog CSV testbench (ModelSim)",
        command=["vsim", "-c", "-do", "do run_matching_engine_csv.tcl; quit -f"],
        working_directory=simulation_directory,
    )
    if not stage_two_pass:
        console.error(
            message=(
                "Unable to run the verification pipeline. ModelSim invocation failed. "
                "Verify that vsim is installed and available on PATH."
            ),
            error=RuntimeError,
        )

    actual_csv_path = simulation_directory / "matching_engine_actual.csv"
    if not actual_csv_path.exists():
        console.error(
            message=(
                f"ModelSim did not produce matching_engine_actual.csv in {simulation_directory}."
            ),
            error=FileNotFoundError,
        )
    console.log(message=f"  matching_engine_actual.csv: {actual_csv_path.stat().st_size} bytes")

    throughput_csv_path = simulation_directory / "matching_engine_throughput.csv"
    if throughput_csv_path.exists():
        console.log(message="Throughput metrics:")
        for line in throughput_csv_path.read_text().splitlines()[1:]:
            metric, _, value = line.partition(",")
            console.log(message=f"  {metric}: {value}")

    stage_three_pass = run_stage(
        description="Compare golden model vs Verilog output",
        command=[
            sys.executable,
            "-m",
            "mmsim.matching_engine.python_verification.matching_engine_golden",
            "--verify",
        ],
        working_directory=project_root,
    )

    if stage_one_pass and stage_two_pass and stage_three_pass:
        console.success(message="All stages passed. The hardware matches the golden model.")
        sys.exit(0)
    console.error(
        message="Pipeline failed. One or more stages did not pass.", exit_code=0,
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
