"""Orchestrates the full CSV verification pipeline for the price_level_store module.

Runs three stages in sequence. First, generates lob_commands.csv and lob_expected.csv from the
Python golden model. Second, invokes ModelSim to replay the commands against the Verilog DUT,
producing lob_actual.csv. Third, compares the expected and actual CSVs row-by-row and reports
the result.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

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
        for line in result.stdout.strip().splitlines():
            console.log(message=f"  {line}")

    if result.returncode != 0:
        console.error(message=f"Stage failed with exit code {result.returncode}", exit_code=0)
        if result.stderr.strip():
            for line in result.stderr.strip().splitlines():
                console.warning(message=f"  {line}")
        return False

    console.success(message=f"  {description} complete")
    return True


if __name__ == "__main__":
    matching_engine_directory = Path(__file__).resolve().parent.parent
    simulation_directory = matching_engine_directory / "sim"
    project_root = matching_engine_directory.parent.parent.parent

    console.log(message="Price Level Store CSV Verification Pipeline", prefix=False)

    stage_one_pass = run_stage(
        description="Generate golden model CSVs",
        command=[
            sys.executable,
            "-m",
            "mmsim.matching_engine.python_verification.price_level_store_golden",
        ],
        working_directory=project_root,
    )
    if not stage_one_pass:
        message = "Unable to run the verification pipeline. The golden model CSV generation failed."
        console.error(message=message, error=RuntimeError)

    commands_csv_path = simulation_directory / "lob_commands.csv"
    expected_csv_path = simulation_directory / "lob_expected.csv"
    if not commands_csv_path.exists() or not expected_csv_path.exists():
        message = (
            f"Unable to run the verification pipeline. The golden model did not produce both "
            f"lob_commands.csv and lob_expected.csv in {simulation_directory}."
        )
        console.error(message=message, error=FileNotFoundError)

    console.log(message=f"  lob_commands.csv: {commands_csv_path.stat().st_size} bytes")
    console.log(message=f"  lob_expected.csv: {expected_csv_path.stat().st_size} bytes")

    stage_two_pass = run_stage(
        description="Run Verilog CSV testbench (ModelSim)",
        command=["vsim", "-c", "-do", "do run_price_level_store_csv.tcl; quit -f"],
        working_directory=simulation_directory,
    )
    if not stage_two_pass:
        message = (
            "Unable to run the verification pipeline. The ModelSim invocation failed. "
            "Verify that vsim is installed and available on the PATH."
        )
        console.error(message=message, error=RuntimeError)

    actual_csv_path = simulation_directory / "lob_actual.csv"
    if not actual_csv_path.exists():
        message = (
            f"Unable to run the verification pipeline. ModelSim did not produce lob_actual.csv "
            f"in {simulation_directory}."
        )
        console.error(message=message, error=FileNotFoundError)

    console.log(message=f"  lob_actual.csv: {actual_csv_path.stat().st_size} bytes")

    stage_three_pass = run_stage(
        description="Compare golden model vs Verilog output",
        command=[
            sys.executable,
            "-m",
            "mmsim.matching_engine.python_verification.price_level_store_golden",
            "--verify",
        ],
        working_directory=project_root,
    )

    if stage_one_pass and stage_two_pass and stage_three_pass:
        console.success(message="All stages passed. The hardware matches the golden model.")
        sys.exit(0)
    else:
        console.error(message="Pipeline failed. One or more stages did not pass.", exit_code=0)
        sys.exit(1)
