"""Provides a Python golden model for the price_level_store_no_cancellation Verilog module."""

from __future__ import annotations

import csv
import random
import sys
from dataclasses import dataclass
from pathlib import Path

import click

from ...utilities import console


# Number of addressable price ticks (must match kPriceRange in the Verilog DUT).
_DEFAULT_PRICE_RANGE: int = 480

# Command codes matching the Verilog localparam encoding for the no-cancellation variant.
_COMMAND_NOP: int = 0
_COMMAND_INSERT: int = 1
_COMMAND_CONSUME: int = 2

# Default seed for deterministic stimulus generation.
_DEFAULT_SEED: int = 42


@dataclass
class CommandResponse:
    """Captures the expected response from a single book command.

    Attributes:
        quantity: The actual quantity inserted or consumed this command.
        best_price: The best price after the command completes.
        best_quantity: The aggregate quantity at the best price after the command completes.
        best_valid: Determines whether at least one price level holds resting shares.
    """

    quantity: int
    """The actual quantity inserted or consumed this command."""
    best_price: int
    """The best price after the command completes."""
    best_quantity: int
    """The aggregate quantity at the best price after the command completes."""
    best_valid: bool
    """Determines whether at least one price level holds resting shares."""


class PriceLevelStoreNoCancellation:
    """Replicates the price_level_store_no_cancellation Verilog module's aggregate-only book.

    Stores a single quantity per price tick in a direct-mapped array indexed by price. Lookups
    for the best price scan the populated levels using price priority (max for bids, min for
    asks). Does not track individual orders and does not support cancellation.

    Args:
        is_bid: Determines whether this store holds bids (highest price is best) or asks.
        price_range: The number of addressable price ticks. Prices at or above this are
            rejected on insert and produce a zero-quantity response.

    Attributes:
        is_bid: Cached side indicator.
        price_range: Cached addressable tick range.
        _level_quantity: The direct-mapped array of aggregate quantities by price.
    """

    def __init__(
        self,
        is_bid: bool = True,
        price_range: int = _DEFAULT_PRICE_RANGE,
    ) -> None:
        self.is_bid: bool = is_bid
        self.price_range: int = price_range
        self._level_quantity: list[int] = [0] * price_range

    def __repr__(self) -> str:
        """Returns a string representation of the PriceLevelStoreNoCancellation instance."""
        side = "bid" if self.is_bid else "ask"
        populated = sum(1 for quantity in self._level_quantity if quantity > 0)
        return f"PriceLevelStoreNoCancellation(side={side}, populated_levels={populated})"

    @property
    def best_price(self) -> int:
        """Returns the best (top) price, or zero when the book is empty."""
        populated = [
            price for price, quantity in enumerate(self._level_quantity) if quantity > 0
        ]
        if not populated:
            return 0
        return max(populated) if self.is_bid else min(populated)

    @property
    def best_quantity(self) -> int:
        """Returns the aggregate quantity at the best price, or zero when the book is empty."""
        if not self.best_valid:
            return 0
        return self._level_quantity[self.best_price]

    @property
    def best_valid(self) -> bool:
        """Determines whether at least one price level holds resting shares."""
        return any(quantity > 0 for quantity in self._level_quantity)

    def insert(self, price: int, quantity: int) -> CommandResponse:
        """Adds the given quantity to the resting shares at the specified price.

        Rejects the insertion when the price is outside the addressable range and returns a
        zero-quantity response without modifying the book.

        Args:
            price: The limit price in integer ticks.
            quantity: The number of shares to add.

        Returns:
            The expected response including the inserted quantity and post-command book state.
        """
        if price >= self.price_range or price < 0:
            return CommandResponse(
                quantity=0,
                best_price=self.best_price,
                best_quantity=self.best_quantity,
                best_valid=self.best_valid,
            )

        self._level_quantity[price] += quantity
        return CommandResponse(
            quantity=quantity,
            best_price=self.best_price,
            best_quantity=self.best_quantity,
            best_valid=self.best_valid,
        )

    def consume(self, quantity: int) -> CommandResponse:
        """Removes up to the specified quantity from the best price level.

        Subtracts from the best level, saturating at zero. When the level is fully consumed it
        becomes inactive and the next call resolves to the next-best price. Returns a
        zero-quantity response when the book is empty.

        Args:
            quantity: The maximum number of shares to consume from the best price.

        Returns:
            The expected response including the actual amount consumed and the post-command
            book state.
        """
        if not self.best_valid:
            return CommandResponse(
                quantity=0,
                best_price=self.best_price,
                best_quantity=self.best_quantity,
                best_valid=self.best_valid,
            )

        target_price = self.best_price
        available = self._level_quantity[target_price]
        consumed = min(quantity, available)
        self._level_quantity[target_price] = available - consumed

        return CommandResponse(
            quantity=consumed,
            best_price=self.best_price,
            best_quantity=self.best_quantity,
            best_valid=self.best_valid,
        )


def generate_deterministic_sweep(
    price_range: int = _DEFAULT_PRICE_RANGE,
    seed: int = _DEFAULT_SEED,
) -> list[dict[str, int]]:
    """Generates a deterministic command sequence exercising all no-cancellation code paths.

    Covers: inserts at distinct prices, inserts at an existing price (aggregation), an insert
    outside the addressable range (rejection), partial consume from the best level, a full
    consume that empties the best level and forces rollover to the next-best price, a consume
    larger than the available quantity (saturation), and a consume against an empty book.

    Args:
        price_range: The addressable tick range; used to parameterize the out-of-range insert.
        seed: The random seed for reproducible sampling in the interleaved phase.

    Returns:
        A list of command dictionaries with keys: command, price, quantity.
    """
    rng = random.Random(seed)
    commands: list[dict[str, int]] = []
    # Price tick step kept small enough that eight distinct levels fit under kPriceRange=480.
    price_step = 50

    # Phase 1: eight distinct price levels.
    for level_index in range(8):
        commands.append({
            "command": _COMMAND_INSERT,
            "price": (level_index + 1) * price_step,
            "quantity": rng.randint(3, 8),
        })

    # Phase 2: four aggregations onto existing levels.
    for _ in range(4):
        commands.append({
            "command": _COMMAND_INSERT,
            "price": rng.choice([(i + 1) * price_step for i in range(8)]),
            "quantity": rng.randint(1, 5),
        })

    # Phase 3: out-of-range insert (rejected).
    commands.append({
        "command": _COMMAND_INSERT,
        "price": price_range + 100,
        "quantity": 5,
    })

    # Phase 4: partial consume from the best level.
    commands.append({"command": _COMMAND_CONSUME, "price": 0, "quantity": 3})

    # Phase 5: large consume that fully drains the best level and rolls over to the next.
    commands.append({"command": _COMMAND_CONSUME, "price": 0, "quantity": 50})

    # Phase 6: randomly interleaved inserts and consumes.
    for _ in range(20):
        if rng.random() < 0.6:
            commands.append({
                "command": _COMMAND_INSERT,
                "price": rng.randint(1, 30) * 10,
                "quantity": rng.randint(1, 8),
            })
        else:
            commands.append({
                "command": _COMMAND_CONSUME,
                "price": 0,
                "quantity": rng.randint(1, 10),
            })

    # Phase 7: drain the book completely.
    for _ in range(10):
        commands.append({"command": _COMMAND_CONSUME, "price": 0, "quantity": 50})

    # Phase 8: consume from an empty book.
    commands.append({"command": _COMMAND_CONSUME, "price": 0, "quantity": 10})

    return commands


def run_golden_model(
    commands: list[dict[str, int]],
    is_bid: bool = True,
    price_range: int = _DEFAULT_PRICE_RANGE,
) -> list[dict[str, int]]:
    """Executes a command sequence against the golden model and records all responses.

    Args:
        commands: The list of command dictionaries to execute.
        is_bid: Determines whether the store holds bids (descending) or asks (ascending).
        price_range: The number of addressable price ticks.

    Returns:
        A list of response dictionaries with keys: command, price, quantity, response_quantity,
        best_price, best_quantity, best_valid.
    """
    store = PriceLevelStoreNoCancellation(is_bid=is_bid, price_range=price_range)
    results: list[dict[str, int]] = []

    for command_entry in commands:
        command_code = command_entry["command"]
        price = command_entry["price"]
        quantity = command_entry["quantity"]

        if command_code == _COMMAND_INSERT:
            response = store.insert(price=price, quantity=quantity)
        elif command_code == _COMMAND_CONSUME:
            response = store.consume(quantity=quantity)
        else:
            response = CommandResponse(
                quantity=0,
                best_price=store.best_price,
                best_quantity=store.best_quantity,
                best_valid=store.best_valid,
            )

        results.append({
            "command": command_code,
            "price": price,
            "quantity": quantity,
            "response_quantity": response.quantity,
            "best_price": response.best_price,
            "best_quantity": response.best_quantity,
            "best_valid": int(response.best_valid),
        })

    return results


def write_commands_csv(commands: list[dict[str, int]], file_path: Path) -> None:
    """Writes the command sequence to a CSV file for the Verilog testbench to consume."""
    with file_path.open(mode="w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=["command", "price", "quantity"])
        writer.writeheader()
        for command_entry in commands:
            writer.writerow(command_entry)


def write_expected_csv(results: list[dict[str, int]], file_path: Path) -> None:
    """Writes the golden model's expected responses to a CSV for offline comparison."""
    fieldnames = [
        "command", "price", "quantity",
        "response_quantity", "best_price", "best_quantity", "best_valid",
    ]
    with file_path.open(mode="w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for result in results:
            writer.writerow(result)


def verify_against_verilog(expected_path: Path, actual_path: Path) -> dict[str, int | bool]:
    """Compares golden model expectations against Verilog simulation CSV output.

    Reads both CSV files row-by-row and reports matches, mismatches, and a detailed diff written
    alongside the actual CSV for offline analysis.

    Args:
        expected_path: Path to the golden model expected output CSV.
        actual_path: Path to the Verilog simulation output CSV.

    Returns:
        A summary dictionary with total_commands, matches, mismatches, and pass status.
    """
    with expected_path.open(mode="r") as expected_file:
        expected_rows = list(csv.DictReader(expected_file))
    with actual_path.open(mode="r") as actual_file:
        actual_rows = list(csv.DictReader(actual_file))

    total = min(len(expected_rows), len(actual_rows))
    matches = 0
    mismatches = 0

    comparison_fields = [
        "response_quantity", "best_price", "best_quantity", "best_valid",
    ]
    command_names = {"0": "NOP", "1": "INSERT", "2": "CONSUME"}

    diff_path = actual_path.parent / "lob_no_cancellation_diff.csv"
    with diff_path.open(mode="w", newline="") as diff_file:
        diff_writer = csv.writer(diff_file)
        diff_writer.writerow([
            "row", "command", "price", "quantity", "field", "expected", "actual",
        ])

        for index in range(total):
            expected = expected_rows[index]
            actual = actual_rows[index]
            mismatched_fields = [
                field_name for field_name in comparison_fields
                if str(expected[field_name]) != str(actual[field_name])
            ]

            if not mismatched_fields:
                matches += 1
                continue

            mismatches += 1
            command_name = command_names.get(expected["command"], "???")
            header = (
                f"Row {index} ({command_name} price={expected['price']} "
                f"quantity={expected['quantity']}):"
            )
            console.warning(message=header)
            for field_name in mismatched_fields:
                console.warning(
                    message=(
                        f"  {field_name}: expected={expected[field_name]}, "
                        f"actual={actual[field_name]}"
                    ),
                )
                diff_writer.writerow([
                    index,
                    expected["command"],
                    expected["price"],
                    expected["quantity"],
                    field_name,
                    expected[field_name],
                    actual[field_name],
                ])

    if mismatches > 0:
        console.log(message=f"Detailed diff written to {diff_path}")

    if len(expected_rows) != len(actual_rows):
        console.warning(
            message=(
                f"Row count mismatch: expected={len(expected_rows)}, "
                f"actual={len(actual_rows)}"
            ),
        )

    return {
        "total_commands": total,
        "matches": matches,
        "mismatches": mismatches,
        "all_passed": mismatches == 0 and len(expected_rows) == len(actual_rows),
    }


@click.command()
@click.option("--verify", is_flag=True, default=False,
              help="Skip generation; diff existing expected vs actual CSVs.")
@click.option("--price-range", type=int, default=_DEFAULT_PRICE_RANGE, show_default=True,
              help="Number of addressable price ticks.")
def main(verify: bool, price_range: int) -> None:
    """Generate CSVs or diff existing Verilog output against the golden model.

    Default mode runs the golden model against the deterministic sweep and writes
    lob_no_cancellation_commands.csv and lob_no_cancellation_expected.csv into sim/.
    With --verify, diffs lob_no_cancellation_expected.csv against lob_no_cancellation_actual.csv.
    """
    output_directory = Path(__file__).resolve().parent.parent / "sim"
    output_directory.mkdir(exist_ok=True)
    commands_path = output_directory / "lob_no_cancellation_commands.csv"
    expected_path = output_directory / "lob_no_cancellation_expected.csv"
    actual_path = output_directory / "lob_no_cancellation_actual.csv"

    if verify:
        console.log(
            message="Comparing lob_no_cancellation_expected.csv vs lob_no_cancellation_actual.csv",
        )
        if not expected_path.exists():
            console.error(
                message="lob_no_cancellation_expected.csv not found. Run without --verify first.",
                error=FileNotFoundError,
            )
        if not actual_path.exists():
            console.error(
                message="lob_no_cancellation_actual.csv not found. Run the CSV testbench first.",
                error=FileNotFoundError,
            )

        summary = verify_against_verilog(expected_path=expected_path, actual_path=actual_path)
        console.log(
            message=(
                f"  Total: {summary['total_commands']} commands, "
                f"{summary['matches']} matches, {summary['mismatches']} mismatches"
            ),
        )
        if summary["all_passed"]:
            console.success(message="All rows match -- hardware matches the golden model.")
            sys.exit(0)
        else:
            console.error(
                message="Mismatches detected between hardware and golden model.",
                exit_code=0,
            )
            sys.exit(1)

    console.log(message="Generating deterministic command sweep...")
    commands = generate_deterministic_sweep(price_range=price_range, seed=_DEFAULT_SEED)
    console.log(message=f"  Generated {len(commands)} commands")

    console.log(message="Running golden model...")
    results = run_golden_model(commands=commands, is_bid=True, price_range=price_range)
    console.log(message=f"  Processed {len(results)} responses")

    write_commands_csv(commands=commands, file_path=commands_path)
    write_expected_csv(results=results, file_path=expected_path)

    console.success(message=f"Wrote {commands_path}")
    console.success(message=f"Wrote {expected_path}")


if __name__ == "__main__":
    main()
