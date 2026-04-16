"""Provides an HTML visualization of the price_level_store's internal state over time.

Reads the golden model's command trace and renders an interactive HTML page showing the sorted
price level array, FIFO order queues with pointer arrows, and free-list state at each step.
Useful for debugging insertion sort order, FIFO linking, and level removal behavior.
"""

from __future__ import annotations

import html
from dataclasses import dataclass, field
from pathlib import Path

from ...utilities import console, LogLevel
from .price_level_store_golden import PriceLevelStore, generate_deterministic_sweep


@dataclass
class VisualizerOrder:
    """Represents a single order node for visualization.

    Attributes:
        order_id: The unique identifier for this order.
        quantity: The number of shares in this order.
    """

    order_id: int
    """The unique identifier for this order."""
    quantity: int
    """The number of shares in this order."""


@dataclass
class VisualizerLevel:
    """Represents a single price level snapshot for visualization.

    Attributes:
        price: The tick price for this level.
        orders: The FIFO queue of orders at this level.
    """

    price: int
    """The tick price for this level."""
    orders: list[VisualizerOrder] = field(default_factory=list)

    @property
    def total_quantity(self) -> int:
        """Returns the aggregate share count across all orders at this level."""
        return sum(order.quantity for order in self.orders)


@dataclass
class BookSnapshot:
    """Captures the complete book state at a single point in time.

    Attributes:
        step: The command index that produced this snapshot.
        command_name: The human-readable command name.
        command_detail: A short description of the command parameters.
        levels: The sorted array of active price levels.
        total_orders: The number of orders currently stored.
        max_orders: The maximum order capacity.
        response_found: Determines whether the command's target was found.
        response_quantity: The quantity reported in the response.
    """

    step: int
    """The command index that produced this snapshot."""
    command_name: str
    """The human-readable command name."""
    command_detail: str
    """A short description of the command parameters."""
    levels: list[VisualizerLevel]
    """The sorted array of active price levels."""
    total_orders: int
    """The number of orders currently stored."""
    max_orders: int
    """The maximum order capacity."""
    response_found: bool
    """Determines whether the command's target was found."""
    response_quantity: int
    """The quantity reported in the response."""


# Command codes matching the price_level_store module.
_COMMAND_INSERT: int = 1
_COMMAND_CONSUME: int = 2
_COMMAND_CANCEL: int = 3

_COMMAND_NAMES: dict[int, str] = {
    0: "NOP",
    1: "INSERT",
    2: "CONSUME",
    3: "CANCEL",
}


def generate_snapshots(
    commands: list[dict[str, int]],
    depth: int = 8,
    max_orders: int = 16,
    is_bid: bool = True,
) -> list[BookSnapshot]:
    """Replays a command sequence and captures a book snapshot after each step.

    Args:
        commands: The list of command dictionaries with keys: command, price, quantity, order_id.
        depth: The maximum number of price levels.
        max_orders: The maximum number of orders.
        is_bid: Determines whether the store holds bids (descending) or asks (ascending).

    Returns:
        A list of BookSnapshot instances, one per command executed.
    """
    store = PriceLevelStore(depth=depth, max_orders=max_orders, is_bid=is_bid)
    snapshots: list[BookSnapshot] = []

    for step, command_entry in enumerate(commands):
        command_code = command_entry["command"]
        price = command_entry["price"]
        quantity = command_entry["quantity"]
        order_id = command_entry["order_id"]

        command_name = _COMMAND_NAMES.get(command_code, "???")

        if command_code == _COMMAND_INSERT:
            detail = f"price={price} quantity={quantity} order_id={order_id}"
            response = store.insert(price=price, quantity=quantity, order_id=order_id)
            response_found = response.found
            response_quantity = response.quantity
        elif command_code == _COMMAND_CONSUME:
            detail = f"quantity={quantity}"
            responses = store.consume(quantity=quantity)
            response_found = any(response.found for response in responses)
            response_quantity = sum(response.quantity for response in responses)
        elif command_code == _COMMAND_CANCEL:
            detail = f"order_id={order_id}"
            response = store.cancel(order_id=order_id)
            response_found = response.found
            response_quantity = response.quantity
        else:
            detail = ""
            response_found = False
            response_quantity = 0

        # Captures the current book state as a deep copy
        level_snapshots = [
            VisualizerLevel(
                price=level.price,
                orders=[
                    VisualizerOrder(order_id=order.order_id, quantity=order.quantity)
                    for order in level.orders
                ],
            )
            for level in store._levels
        ]

        snapshots.append(BookSnapshot(
            step=step,
            command_name=command_name,
            command_detail=detail,
            levels=level_snapshots,
            total_orders=store._order_count,
            max_orders=max_orders,
            response_found=response_found,
            response_quantity=response_quantity,
        ))

    return snapshots


def _render_level_html(level: VisualizerLevel, index: int) -> str:
    """Renders a single price level as an HTML table row with its FIFO chain.

    Args:
        level: The price level to render.
        index: The array index of this level (0 = best).

    Returns:
        An HTML string for the level row.
    """
    best_marker = ' <span class="best-tag">BEST</span>' if index == 0 else ""

    order_cells = ""
    for order_index, order in enumerate(level.orders):
        arrow = ' <span class="arrow">&rarr;</span> ' if order_index < len(level.orders) - 1 else ""
        head_class = " head" if order_index == 0 else ""
        tail_class = " tail" if order_index == len(level.orders) - 1 else ""
        order_cells += (
            f'<span class="order-node{head_class}{tail_class}">'
            f"id={order.order_id} qty={order.quantity}"
            f"</span>{arrow}"
        )

    if not level.orders:
        order_cells = "<span class='empty-fifo'>empty</span>"

    return (
        f'<tr class="level-row">'
        f'<td class="index-cell">[{index}]</td>'
        f'<td class="price-cell">{level.price}{best_marker}</td>'
        f'<td class="qty-cell">{level.total_quantity}</td>'
        f'<td class="fifo-cell">{order_cells}</td>'
        f"</tr>"
    )


def _render_snapshot_html(snapshot: BookSnapshot) -> str:
    """Renders a single book snapshot as an HTML section.

    Args:
        snapshot: The book state to render.

    Returns:
        An HTML string for the snapshot section.
    """
    found_class = "found" if snapshot.response_found else "not-found"
    found_text = "found" if snapshot.response_found else "not found"

    header = (
        f'<div class="snapshot" id="step-{snapshot.step}">'
        f'<div class="step-header">'
        f'<span class="step-num">Step {snapshot.step}</span> '
        f'<span class="cmd-name">{html.escape(snapshot.command_name)}</span> '
        f'<span class="cmd-detail">{html.escape(snapshot.command_detail)}</span> '
        f'<span class="response {found_class}">{found_text}, qty={snapshot.response_quantity}</span>'
        f"</div>"
    )

    free_slots = snapshot.max_orders - snapshot.total_orders
    status_bar = (
        f'<div class="status-bar">'
        f"Levels: {len(snapshot.levels)} | "
        f"Orders: {snapshot.total_orders}/{snapshot.max_orders} | "
        f"Free slots: {free_slots}"
        f"</div>"
    )

    if snapshot.levels:
        rows = "".join(
            _render_level_html(level=level, index=index)
            for index, level in enumerate(snapshot.levels)
        )
        table = (
            f'<table class="book-table">'
            f"<tr><th>Index</th><th>Price</th><th>Total Qty</th><th>FIFO Chain (head &rarr; tail)</th></tr>"
            f"{rows}</table>"
        )
    else:
        table = "<div class='empty-book'>Book is empty</div>"

    return f"{header}{status_bar}{table}</div>"


_CSS: str = """
body { font-family: 'Consolas', 'Courier New', monospace; background: #1a1a2e; color: #e0e0e0;
       margin: 20px; font-size: 14px; }
h1 { color: #00d4ff; border-bottom: 2px solid #00d4ff; padding-bottom: 8px; }
.snapshot { margin: 16px 0; padding: 12px; background: #16213e; border-radius: 8px;
            border-left: 4px solid #0f3460; }
.step-header { margin-bottom: 8px; }
.step-num { color: #00d4ff; font-weight: bold; }
.cmd-name { color: #e94560; font-weight: bold; padding: 2px 6px; background: #0f3460;
            border-radius: 4px; }
.cmd-detail { color: #a0a0a0; }
.response { padding: 2px 6px; border-radius: 4px; font-size: 12px; }
.response.found { background: #1b4332; color: #52b788; }
.response.not-found { background: #3d0000; color: #e94560; }
.status-bar { color: #888; font-size: 12px; margin-bottom: 6px; }
.book-table { border-collapse: collapse; width: 100%; }
.book-table th { background: #0f3460; color: #00d4ff; padding: 4px 8px; text-align: left;
                 font-size: 12px; }
.book-table td { padding: 4px 8px; border-bottom: 1px solid #1a1a2e; }
.level-row:hover { background: #1f3a5f; }
.index-cell { color: #666; width: 50px; }
.price-cell { color: #ffd700; font-weight: bold; width: 100px; }
.qty-cell { color: #52b788; width: 80px; }
.fifo-cell { color: #ccc; }
.order-node { display: inline-block; padding: 2px 6px; background: #0f3460; border-radius: 4px;
              margin: 1px; font-size: 12px; }
.order-node.head { border-left: 3px solid #00d4ff; }
.order-node.tail { border-right: 3px solid #e94560; }
.arrow { color: #555; }
.best-tag { color: #ffd700; font-size: 10px; font-weight: bold; }
.empty-fifo { color: #555; font-style: italic; }
.empty-book { color: #555; font-style: italic; padding: 8px; }
.nav { position: sticky; top: 0; background: #1a1a2e; padding: 8px 0; z-index: 10;
       border-bottom: 1px solid #333; }
.nav a { color: #00d4ff; text-decoration: none; margin: 0 4px; }
.nav a:hover { text-decoration: underline; }
"""


def render_html(snapshots: list[BookSnapshot], title: str = "Price Level Store Visualization") -> str:
    """Renders the complete HTML page from a list of book snapshots.

    Args:
        snapshots: The sequence of book state snapshots to visualize.
        title: The page title.

    Returns:
        A complete HTML document string.
    """
    snapshot_sections = "\n".join(
        _render_snapshot_html(snapshot=snapshot) for snapshot in snapshots
    )

    nav_links = " ".join(
        f'<a href="#step-{snapshot.step}">{snapshot.step}</a>' for snapshot in snapshots
    )

    return (
        f"<!DOCTYPE html><html><head><meta charset='utf-8'>"
        f"<title>{html.escape(title)}</title>"
        f"<style>{_CSS}</style></head><body>"
        f"<h1>{html.escape(title)}</h1>"
        f'<div class="nav">Jump to step: {nav_links}</div>'
        f"{snapshot_sections}"
        f"</body></html>"
    )


def write_visualization(
    commands: list[dict[str, int]],
    output_path: Path,
    depth: int = 8,
    max_orders: int = 16,
    is_bid: bool = True,
) -> None:
    """Generates and writes the HTML visualization to a file.

    Args:
        commands: The command sequence to replay.
        output_path: The output HTML file path.
        depth: The maximum number of price levels.
        max_orders: The maximum number of orders.
        is_bid: Determines whether the store holds bids or asks.
    """
    snapshots = generate_snapshots(
        commands=commands, depth=depth, max_orders=max_orders, is_bid=is_bid,
    )

    side_label = "Bid" if is_bid else "Ask"
    title = f"Price Level Store ({side_label} Side) -- {len(commands)} Commands"
    html_content = render_html(snapshots=snapshots, title=title)

    with open(output_path, "w", encoding="utf-8") as html_file:
        html_file.write(html_content)

    console.success(f"Wrote visualization to {output_path} ({len(snapshots)} steps)")


if __name__ == "__main__":
    output_directory = Path(__file__).parent

    console.log("Generating command sweep for visualization...")
    commands = generate_deterministic_sweep(depth=8, max_orders=16, seed=42)

    write_visualization(
        commands=commands,
        output_path=output_directory / "book_visualization.html",
        depth=8,
        max_orders=16,
        is_bid=True,
    )
