"""Provides a Python golden model for the price_level_store Verilog module.

Replicates the exact insert, consume, and cancel logic of the hardware implementation using
integer tick prices, sorted price level arrays, and linked-list FIFO ordering within each level.
Generates deterministic command sequences and expected responses for cross-verification against
the Verilog testbench CSV output.
"""

from __future__ import annotations

import csv
import json
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path

from ...utilities import console, LogLevel


# Maximum number of distinct price levels per book side.
_DEFAULT_DEPTH: int = 16

# Maximum number of individual orders stored per book side.
_DEFAULT_MAX_ORDERS: int = 256

# Number of addressable price ticks (must match kPriceRange in the Verilog DUT).
_DEFAULT_PRICE_RANGE: int = 2048

# Command codes matching the Verilog localparam encoding.
_COMMAND_NOP: int = 0
_COMMAND_INSERT: int = 1
_COMMAND_CONSUME: int = 2
_COMMAND_CANCEL: int = 3


@dataclass
class Order:
    """Represents a single order stored in the book's FIFO.

    Attributes:
        order_id: The unique identifier assigned to this order.
        quantity: The number of shares in this order.
    """

    order_id: int
    """The unique identifier assigned to this order."""
    quantity: int
    """The number of shares in this order."""


@dataclass
class PriceLevel:
    """Represents a single price level in the sorted book array.

    Attributes:
        price: The tick price for this level.
        orders: The FIFO queue of individual orders at this price.
    """

    price: int
    """The tick price for this level."""
    orders: list[Order] = field(default_factory=list)
    """The FIFO queue of individual orders at this price."""

    @property
    def total_quantity(self) -> int:
        """Returns the aggregate share count across all orders at this level."""
        return sum(order.quantity for order in self.orders)


@dataclass
class CommandResponse:
    """Captures the expected response from a single book command.

    Attributes:
        order_id: The affected order's identifier (zero when not applicable).
        quantity: The actual quantity consumed, inserted, or cancelled.
        found: Determines whether the target was found (relevant for cancel operations).
        best_price: The best price after this command completes.
        best_quantity: The aggregate quantity at the best price after this command completes.
        best_valid: Determines whether the book has at least one active level.
    """

    order_id: int
    """The affected order's identifier (zero when not applicable)."""
    quantity: int
    """The actual quantity consumed, inserted, or cancelled."""
    found: bool
    """Determines whether the target was found (relevant for cancel operations)."""
    best_price: int
    """The best price after this command completes."""
    best_quantity: int
    """The aggregate quantity at the best price after this command completes."""
    best_valid: bool
    """Determines whether the book has at least one active level."""


class PriceLevelStore:
    """Replicates the price_level_store Verilog module's sorted register-array order book.

    Maintains a sorted array of price levels (index 0 holds the best price) with FIFO order
    queues at each level. Supports insert, consume-from-best, and cancel-by-order-id operations
    with identical semantics to the hardware implementation.

    Args:
        depth: The maximum number of distinct price levels.
        max_orders: The maximum number of individual orders stored.
        is_bid: Determines whether this store holds bids (descending) or asks (ascending).
        price_range: The number of addressable price ticks; prices >= price_range are rejected.

    Attributes:
        _depth: Cached maximum price level count.
        _max_orders: Cached maximum order count.
        _is_bid: Cached side indicator.
        _price_range: Cached addressable price range; inserts at or above this are rejected.
        _levels: The sorted array of active price levels.
        _order_count: Tracks the number of orders currently stored.
    """

    def __init__(self, depth: int = _DEFAULT_DEPTH, max_orders: int = _DEFAULT_MAX_ORDERS,
                 is_bid: bool = True, price_range: int = _DEFAULT_PRICE_RANGE) -> None:
        self._depth: int = depth
        self._max_orders: int = max_orders
        self._is_bid: bool = is_bid
        self._price_range: int = price_range
        self._levels: list[PriceLevel] = []
        self._order_count: int = 0

    def __repr__(self) -> str:
        """Returns a string representation of the PriceLevelStore instance."""
        side = "bid" if self._is_bid else "ask"
        return (
            f"PriceLevelStore(side={side}, levels={len(self._levels)}, "
            f"orders={self._order_count})"
        )

    @property
    def best_price(self) -> int:
        """Returns the best (top) price, or zero when the book is empty."""
        if self._levels:
            return self._levels[0].price
        return 0

    @property
    def best_quantity(self) -> int:
        """Returns the aggregate quantity at the best price, or zero when empty."""
        if self._levels:
            return self._levels[0].total_quantity
        return 0

    @property
    def best_valid(self) -> bool:
        """Determines whether the book has at least one active price level."""
        return len(self._levels) > 0

    @property
    def is_full(self) -> bool:
        """Determines whether the order store is at capacity."""
        return self._order_count >= self._max_orders

    def _is_better_price(self, price_a: int, price_b: int) -> bool:
        """Compares two prices and determines whether the first is more competitive.

        For bids, a higher price is more competitive. For asks, a lower price is more
        competitive.

        Args:
            price_a: The candidate price to evaluate.
            price_b: The reference price to compare against.

        Returns:
            True when price_a is more competitive than price_b.
        """
        if self._is_bid:
            return price_a > price_b
        return price_a < price_b

    def _find_level_index(self, price: int) -> tuple[int | None, int]:
        """Locates an existing level with the given price or computes the insertion position.

        Args:
            price: The tick price to search for.

        Returns:
            A tuple of (matched_index, insert_position). matched_index is the index of an
            existing level with the exact price, or None if no match exists. insert_position
            is the index where a new level should be inserted to maintain sort order.
        """
        insert_position = len(self._levels)

        for index, level in enumerate(self._levels):
            if level.price == price:
                return index, index

        for index, level in enumerate(self._levels):
            if self._is_better_price(price, level.price):
                insert_position = index
                break

        return None, insert_position

    def insert(self, price: int, quantity: int, order_id: int) -> CommandResponse:
        """Inserts a new order into the book at the specified price.

        Locates or creates the appropriate price level, then appends the order to that level's
        FIFO tail. Rejects the insertion when the price is outside the addressable range, the
        order store is full, or all price level slots are occupied.

        Args:
            price: The limit price in integer ticks.
            quantity: The number of shares.
            order_id: The unique order identifier.

        Returns:
            The expected response including the inserted quantity and updated book state.
        """
        if price >= self._price_range or self._order_count >= self._max_orders:
            return CommandResponse(
                order_id=0, quantity=0, found=False,
                best_price=self.best_price, best_quantity=self.best_quantity,
                best_valid=self.best_valid,
            )

        matched_index, insert_position = self._find_level_index(price=price)

        if matched_index is not None:
            self._levels[matched_index].orders.append(Order(order_id=order_id, quantity=quantity))
            self._order_count += 1
        elif len(self._levels) < self._depth:
            new_level = PriceLevel(price=price, orders=[Order(order_id=order_id, quantity=quantity)])
            self._levels.insert(insert_position, new_level)
            self._order_count += 1
        else:
            return CommandResponse(
                order_id=0, quantity=0, found=False,
                best_price=self.best_price, best_quantity=self.best_quantity,
                best_valid=self.best_valid,
            )

        return CommandResponse(
            order_id=order_id, quantity=quantity, found=True,
            best_price=self.best_price, best_quantity=self.best_quantity,
            best_valid=self.best_valid,
        )

    def consume(self, quantity: int) -> list[CommandResponse]:
        """Removes up to the specified quantity from the best price level.

        Pops orders from the FIFO head of the best level. When a level becomes empty, removes
        it and continues consuming from the next best level. Generates one response per
        individual order fill (partial or full).

        Args:
            quantity: The total number of shares to consume from the best price.

        Returns:
            A list of fill responses, one per individual order touched. Returns a single
            response with quantity zero when the book is empty.
        """
        responses: list[CommandResponse] = []
        remaining = quantity

        while remaining > 0 and self._levels:
            level = self._levels[0]
            if not level.orders:
                self._levels.pop(0)
                continue

            head_order = level.orders[0]

            if remaining >= head_order.quantity:
                filled_quantity = head_order.quantity
                remaining -= filled_quantity
                level.orders.pop(0)
                self._order_count -= 1

                responses.append(CommandResponse(
                    order_id=head_order.order_id, quantity=filled_quantity, found=True,
                    best_price=self.best_price, best_quantity=self.best_quantity,
                    best_valid=self.best_valid,
                ))

                if not level.orders:
                    self._levels.pop(0)
            else:
                head_order.quantity -= remaining
                filled_quantity = remaining
                remaining = 0

                responses.append(CommandResponse(
                    order_id=head_order.order_id, quantity=filled_quantity, found=True,
                    best_price=self.best_price, best_quantity=self.best_quantity,
                    best_valid=self.best_valid,
                ))

        if not responses:
            responses.append(CommandResponse(
                order_id=0, quantity=0, found=False,
                best_price=self.best_price, best_quantity=self.best_quantity,
                best_valid=self.best_valid,
            ))

        return responses

    def cancel(self, order_id: int) -> CommandResponse:
        """Cancels the order with the specified identifier and removes it from the book.

        Performs a linear scan through all levels and their FIFO queues to locate the target
        order. When found, unlinks the order and removes the price level if it becomes empty.

        Args:
            order_id: The unique identifier of the order to cancel.

        Returns:
            The expected response indicating whether the order was found and the cancelled
            quantity.
        """
        for level_index, level in enumerate(self._levels):
            for order_index, order in enumerate(level.orders):
                if order.order_id == order_id:
                    cancelled_quantity = order.quantity
                    level.orders.pop(order_index)
                    self._order_count -= 1

                    if not level.orders:
                        self._levels.pop(level_index)

                    return CommandResponse(
                        order_id=order_id, quantity=cancelled_quantity, found=True,
                        best_price=self.best_price, best_quantity=self.best_quantity,
                        best_valid=self.best_valid,
                    )

        return CommandResponse(
            order_id=order_id, quantity=0, found=False,
            best_price=self.best_price, best_quantity=self.best_quantity,
            best_valid=self.best_valid,
        )


def generate_deterministic_sweep(depth: int = 8, max_orders: int = 16,
                                 seed: int = 42) -> list[dict[str, int]]:
    """Generates a deterministic sequence of commands that exercises all code paths.

    Produces insert, consume, and cancel commands covering: sorted insertion at better, worse,
    and equal prices; FIFO ordering within a level; partial and full consumption across levels;
    cancellation of head, middle, tail, and nonexistent orders; and full-book rejection.

    Prices are scaled as multiples of 10 within kPriceRange=2048 (valid range 10..2040).
    Quantities are scaled down proportionally to match the smaller price increments.

    Args:
        depth: The maximum number of price levels for the store under test.
        max_orders: The maximum number of orders for the store under test.
        seed: The random seed for reproducible command generation.

    Returns:
        A list of command dictionaries with keys: command, price, quantity, order_id.
    """
    rng = random.Random(seed)
    commands: list[dict[str, int]] = []
    next_order_id = 1
    issued_order_ids: list[int] = []

    # Phase 1: Fills the book with orders at distinct price levels (prices 100..800, step 100)
    for level_index in range(depth):
        price = (level_index + 1) * 100
        quantity = rng.randint(1, 8)
        commands.append({
            "command": _COMMAND_INSERT,
            "price": price,
            "quantity": quantity,
            "order_id": next_order_id,
        })
        issued_order_ids.append(next_order_id)
        next_order_id += 1

    # Phase 2: Inserts duplicate orders at existing price levels (tests FIFO aggregation)
    for _ in range(4):
        price = rng.choice([(i + 1) * 100 for i in range(depth)])
        quantity = rng.randint(1, 5)
        commands.append({
            "command": _COMMAND_INSERT,
            "price": price,
            "quantity": quantity,
            "order_id": next_order_id,
        })
        issued_order_ids.append(next_order_id)
        next_order_id += 1

    # Phase 3: Attempts to insert at a price outside kPriceRange=2048 (tests out-of-range rejection)
    commands.append({
        "command": _COMMAND_INSERT,
        "price": 3000,
        "quantity": 5,
        "order_id": next_order_id,
    })
    next_order_id += 1

    # Phase 4: Partial consume from the best level
    commands.append({
        "command": _COMMAND_CONSUME,
        "price": 0,
        "quantity": 3,
        "order_id": 0,
    })

    # Phase 5: Full consume that sweeps an entire level
    commands.append({
        "command": _COMMAND_CONSUME,
        "price": 0,
        "quantity": 30,
        "order_id": 0,
    })

    # Phase 6: Cancels a known order from the middle of the book
    if len(issued_order_ids) > 3:
        cancel_target = issued_order_ids[3]
        commands.append({
            "command": _COMMAND_CANCEL,
            "price": 0,
            "quantity": 0,
            "order_id": cancel_target,
        })

    # Phase 7: Cancels a nonexistent order
    commands.append({
        "command": _COMMAND_CANCEL,
        "price": 0,
        "quantity": 0,
        "order_id": 65535,
    })

    # Phase 8: Randomly interleaved insert, consume, and cancel operations
    for _ in range(20):
        action = rng.choice(["insert", "consume", "cancel"])

        if action == "insert":
            price = rng.randint(1, 25) * 10
            quantity = rng.randint(1, 8)
            commands.append({
                "command": _COMMAND_INSERT,
                "price": price,
                "quantity": quantity,
                "order_id": next_order_id,
            })
            issued_order_ids.append(next_order_id)
            next_order_id += 1
        elif action == "consume":
            quantity = rng.randint(1, 10)
            commands.append({
                "command": _COMMAND_CONSUME,
                "price": 0,
                "quantity": quantity,
                "order_id": 0,
            })
        else:
            target = rng.choice(issued_order_ids) if issued_order_ids else 65535
            commands.append({
                "command": _COMMAND_CANCEL,
                "price": 0,
                "quantity": 0,
                "order_id": target,
            })

    # Phase 9: Drains the book completely
    for _ in range(5):
        commands.append({
            "command": _COMMAND_CONSUME,
            "price": 0,
            "quantity": 50,
            "order_id": 0,
        })

    # Phase 10: Consumes from an empty book
    commands.append({
        "command": _COMMAND_CONSUME,
        "price": 0,
        "quantity": 10,
        "order_id": 0,
    })

    return commands


def run_golden_model(commands: list[dict[str, int]], depth: int = 8, max_orders: int = 16,
                     is_bid: bool = True,
                     price_range: int = _DEFAULT_PRICE_RANGE) -> list[dict[str, int | bool]]:
    """Executes a command sequence against the golden model and records all responses.

    Args:
        commands: The list of command dictionaries to execute.
        depth: The maximum number of price levels.
        max_orders: The maximum number of orders.
        is_bid: Determines whether the store holds bids (descending) or asks (ascending).
        price_range: The number of addressable price ticks; prices >= price_range are rejected.

    Returns:
        A list of response dictionaries with keys: command, price, quantity, order_id,
        response_order_id, response_quantity, response_found, best_price, best_quantity,
        best_valid.
    """
    store = PriceLevelStore(depth=depth, max_orders=max_orders, is_bid=is_bid,
                            price_range=price_range)
    results: list[dict[str, int | bool]] = []

    for command_entry in commands:
        command_code = command_entry["command"]
        price = command_entry["price"]
        quantity = command_entry["quantity"]
        order_id = command_entry["order_id"]

        if command_code == _COMMAND_INSERT:
            response = store.insert(price=price, quantity=quantity, order_id=order_id)
            results.append({
                "command": command_code,
                "price": price,
                "quantity": quantity,
                "order_id": order_id,
                "response_order_id": response.order_id,
                "response_quantity": response.quantity,
                "response_found": int(response.found),
                "best_price": response.best_price,
                "best_quantity": response.best_quantity,
                "best_valid": int(response.best_valid),
            })
        elif command_code == _COMMAND_CONSUME:
            responses = store.consume(quantity=quantity)
            # Records the last order touched and the total quantity consumed. The book-state
            # fields are read from the store after the full consume completes so that any
            # emptied levels have already been removed, matching the Verilog testbench that
            # samples best_price after the FSM returns to idle.
            final_response = responses[-1]
            total_consumed = sum(response.quantity for response in responses)
            results.append({
                "command": command_code,
                "price": price,
                "quantity": quantity,
                "order_id": order_id,
                "response_order_id": final_response.order_id,
                "response_quantity": total_consumed,
                "response_found": int(final_response.found),
                "best_price": store.best_price,
                "best_quantity": store.best_quantity,
                "best_valid": int(store.best_valid),
            })
        elif command_code == _COMMAND_CANCEL:
            response = store.cancel(order_id=order_id)
            results.append({
                "command": command_code,
                "price": price,
                "quantity": quantity,
                "order_id": order_id,
                "response_order_id": response.order_id,
                "response_quantity": response.quantity,
                "response_found": int(response.found),
                "best_price": response.best_price,
                "best_quantity": response.best_quantity,
                "best_valid": int(response.best_valid),
            })

    return results


def write_commands_csv(commands: list[dict[str, int]], file_path: Path) -> None:
    """Writes the command sequence to a CSV file for Verilog testbench consumption.

    Args:
        commands: The command sequence to write.
        file_path: The output CSV file path.
    """
    with open(file_path, "w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=["command", "price", "quantity", "order_id"])
        writer.writeheader()
        for command_entry in commands:
            writer.writerow(command_entry)


def write_expected_csv(results: list[dict[str, int | bool]], file_path: Path) -> None:
    """Writes the expected responses to a CSV file for Verilog output comparison.

    Args:
        results: The golden model response records to write.
        file_path: The output CSV file path.
    """
    fieldnames = [
        "command", "price", "quantity", "order_id",
        "response_order_id", "response_quantity", "response_found",
        "best_price", "best_quantity", "best_valid",
    ]
    with open(file_path, "w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for result in results:
            writer.writerow(result)


def verify_against_verilog(expected_path: Path, actual_path: Path) -> dict[str, int | bool]:
    """Compares golden model expectations against Verilog simulation CSV output.

    Reads both CSV files row-by-row and reports the number of matches and mismatches. The
    actual CSV is produced by the Verilog testbench replaying the same command sequence.

    Args:
        expected_path: Path to the golden model expected output CSV.
        actual_path: Path to the Verilog simulation output CSV.

    Returns:
        A summary dictionary with total_commands, matches, mismatches, and pass status.
    """
    with open(expected_path, "r") as expected_file:
        expected_rows = list(csv.DictReader(expected_file))

    with open(actual_path, "r") as actual_file:
        actual_rows = list(csv.DictReader(actual_file))

    total = min(len(expected_rows), len(actual_rows))
    matches = 0
    mismatches = 0

    comparison_fields = [
        "response_order_id", "response_quantity", "response_found",
        "best_price", "best_quantity", "best_valid",
    ]

    command_names = {"0": "NOP", "1": "INSERT", "2": "CONSUME", "3": "CANCEL"}

    # Writes a detailed diff CSV beside the actual CSV for offline analysis
    diff_path = actual_path.parent / "lob_diff.csv"
    with open(diff_path, "w", newline="") as diff_file:
        diff_writer = csv.writer(diff_file)
        diff_writer.writerow([
            "row", "command", "price", "quantity", "order_id", "field",
            "expected", "actual",
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
                f"quantity={expected['quantity']} order_id={expected['order_id']}):"
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
                    expected["order_id"],
                    field_name,
                    expected[field_name],
                    actual[field_name],
                ])

    if mismatches > 0:
        console.log(message=f"Detailed diff written to {diff_path}")

    if len(expected_rows) != len(actual_rows):
        console.warning(
            f"Row count mismatch: expected={len(expected_rows)}, actual={len(actual_rows)}"
        )

    return {
        "total_commands": total,
        "matches": matches,
        "mismatches": mismatches,
        "all_passed": mismatches == 0 and len(expected_rows) == len(actual_rows),
    }


if __name__ == "__main__":
    # CSVs are written to the sim/ directory so ModelSim and Python share the same location.
    output_directory = Path(__file__).resolve().parent.parent / "sim"
    output_directory.mkdir(exist_ok=True)
    actual_path = output_directory / "lob_actual.csv"
    expected_path = output_directory / "lob_expected.csv"
    commands_path = output_directory / "lob_commands.csv"

    # When --verify is passed, skip generation and just compare expected vs actual.
    if len(sys.argv) > 1 and sys.argv[1] == "--verify":
        console.log("Comparing lob_expected.csv vs lob_actual.csv...")

        if not expected_path.exists():
            console.error(message="lob_expected.csv not found. Run without --verify first.", error=FileNotFoundError)
        if not actual_path.exists():
            console.error(message="lob_actual.csv not found. Run the Verilog CSV testbench first.", error=FileNotFoundError)

        summary = verify_against_verilog(expected_path=expected_path, actual_path=actual_path)
        console.log(
            f"  Total: {summary['total_commands']} commands, "
            f"{summary['matches']} matches, {summary['mismatches']} mismatches"
        )
        if summary["all_passed"]:
            console.success("All rows match -- hardware matches golden model")
        else:
            console.error("Mismatches detected between hardware and golden model", exit_code=0)

        sys.exit(0 if summary["all_passed"] else 1)

    # Default mode: generate CSVs and run self-verification.
    console.log("Generating deterministic command sweep...")
    commands = generate_deterministic_sweep(depth=8, max_orders=16, seed=42)
    console.log(f"  Generated {len(commands)} commands")

    console.log("Running golden model...")
    results = run_golden_model(commands=commands, depth=8, max_orders=16, is_bid=True,
                               price_range=_DEFAULT_PRICE_RANGE)
    console.log(f"  Processed {len(results)} responses")

    write_commands_csv(commands=commands, file_path=commands_path)
    write_expected_csv(results=results, file_path=expected_path)

    console.log(f"  Wrote {commands_path}")
    console.log(f"  Wrote {expected_path}")

    # Prints a summary of the book state at each step for manual inspection
    console.log("Command trace (first 20):", level=LogLevel.DEBUG)
    command_names = {0: "NOP", 1: "INSERT", 2: "CONSUME", 3: "CANCEL"}
    for index, result in enumerate(results[:20]):
        command_name = command_names.get(result["command"], "???")
        console.log(
            f"  [{index:3d}] {command_name:7s}  "
            f"price={result['price']:5d}  quantity={result['quantity']:3d}  "
            f"order_id={result['order_id']:3d}  ->  "
            f"rsp_found={result['response_found']}  "
            f"best={result['best_price']:5d}  "
            f"best_quantity={result['best_quantity']:3d}  "
            f"valid={result['best_valid']}",
            level=LogLevel.DEBUG,
        )

    # Self-verification: replays the same commands against a fresh store and checks invariants
    console.log("Running self-verification...")
    store = PriceLevelStore(depth=8, max_orders=16, is_bid=True, price_range=_DEFAULT_PRICE_RANGE)
    invariant_violations = 0

    for index, command_entry in enumerate(commands):
        command_code = command_entry["command"]

        if command_code == _COMMAND_INSERT:
            store.insert(
                price=command_entry["price"],
                quantity=command_entry["quantity"],
                order_id=command_entry["order_id"],
            )
        elif command_code == _COMMAND_CONSUME:
            store.consume(quantity=command_entry["quantity"])
        elif command_code == _COMMAND_CANCEL:
            store.cancel(order_id=command_entry["order_id"])

        # Checks sort invariant: prices must be in descending order for bids
        for level_index in range(len(store._levels) - 1):
            if store._levels[level_index].price <= store._levels[level_index + 1].price:
                console.error(
                    f"Sort violation at command {index}, levels {level_index}/{level_index + 1}",
                    exit_code=0,
                )
                invariant_violations += 1

        # Checks quantity invariant: aggregate must equal sum of individual orders
        for level in store._levels:
            computed_total = sum(order.quantity for order in level.orders)
            if computed_total != level.total_quantity:
                console.error(
                    f"Quantity mismatch at command {index}, price={level.price}",
                    exit_code=0,
                )
                invariant_violations += 1

    if invariant_violations == 0:
        console.success("All invariants passed")
    else:
        console.error(f"{invariant_violations} invariant violations detected", exit_code=0)

    # Writes a JSON summary for downstream analysis
    summary = {
        "total_commands": len(commands),
        "total_responses": len(results),
        "invariant_violations": invariant_violations,
        "depth": 8,
        "max_orders": 16,
        "is_bid": True,
        "price_range": _DEFAULT_PRICE_RANGE,
        "seed": 42,
    }
    summary_path = output_directory / "lob_golden_summary.json"
    with open(summary_path, "w") as summary_file:
        json.dump(summary, summary_file, indent=2)
    console.success(f"Saved {summary_path}")
    