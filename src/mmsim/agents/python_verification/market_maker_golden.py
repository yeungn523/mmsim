"""Provides a Python golden model for the market_maker Verilog module.

Replicates the ten-state FSM, fair-price ladder, inventory skew arithmetic, and trade-snoop fill
attribution implemented in ``src/mmsim/agents/rtl/market_maker.v``. Emits at most one order per
tick to match the single-order-per-grant constraint of the shared order bus. Used by the
inventory study harness and (future) the CSV-based DUT verification pipeline.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum


# Order type codes matching the Verilog localparam encoding in matching_engine.v.
TYPE_LIMIT_BUY: int = 1
TYPE_LIMIT_SELL: int = 2
TYPE_MARKET_BUY: int = 3
TYPE_MARKET_SELL: int = 4
TYPE_CANCEL: int = 5


class State(IntEnum):
    """Defines the ten FSM states of the market maker, matching the Verilog kState* localparams."""

    INIT = 0
    """Post-reset placeholder; transitions to seeding on the next cycle."""
    SEED_BID = 1
    """Drives the initial bid to seed an empty book."""
    SEED_ASK = 2
    """Drives the initial ask to seed an empty book."""
    QUOTING = 3
    """Steady state that evaluates triggers each cycle to select the next action."""
    REPLENISH_BID = 4
    """Posts a single bid when the bid side has gone missing."""
    REPLENISH_ASK = 5
    """Posts a single ask when the ask side has gone missing."""
    CANCEL_BID = 6
    """First cycle of a requote sequence; cancels the currently resting bid."""
    CANCEL_ASK = 7
    """Second cycle of a requote sequence; cancels the currently resting ask."""
    POST_BID = 8
    """Third cycle of a requote sequence; posts the new bid at the updated fair price."""
    POST_ASK = 9
    """Fourth cycle of a requote sequence; posts the new ask at the updated fair price."""


@dataclass
class BookObservation:
    """Captures the per-cycle inputs the market maker samples from the matching engine.

    Attributes:
        best_bid_price: The highest resting bid price in the engine.
        best_bid_quantity: The aggregate quantity at the best bid.
        best_bid_valid: Determines whether the bid book is nonempty.
        best_ask_price: The lowest resting ask price in the engine.
        best_ask_quantity: The aggregate quantity at the best ask.
        best_ask_valid: Determines whether the ask book is nonempty.
        trade_valid: Determines whether a trade snoop event is present this cycle.
        trade_aggressor_id: The aggressive order's identifier for this trade event.
        trade_resting_id: The resting order's identifier for this trade event.
        trade_price: The execution price for this trade event.
        trade_quantity: The number of shares executed in this trade event.
    """

    best_bid_price: int = 0
    """The highest resting bid price in the engine."""
    best_bid_quantity: int = 0
    """The aggregate quantity at the best bid."""
    best_bid_valid: bool = False
    """Determines whether the bid book is nonempty."""
    best_ask_price: int = 0
    """The lowest resting ask price in the engine."""
    best_ask_quantity: int = 0
    """The aggregate quantity at the best ask."""
    best_ask_valid: bool = False
    """Determines whether the ask book is nonempty."""
    trade_valid: bool = False
    """Determines whether a trade snoop event is present this cycle."""
    trade_aggressor_id: int = 0
    """The aggressive order's identifier for this trade event."""
    trade_resting_id: int = 0
    """The resting order's identifier for this trade event."""
    trade_price: int = 0
    """The execution price for this trade event."""
    trade_quantity: int = 0
    """The number of shares executed in this trade event."""


@dataclass
class OrderCommand:
    """Captures a single order the market maker intends to submit to the matching engine.

    Attributes:
        order_type: The order type code (limit buy, limit sell, market buy, market sell, cancel).
        order_id: The order's unique identifier.
        order_price: The order's limit price in ticks (unused for market and cancel orders).
        order_quantity: The order's share count (unused for cancel orders).
    """

    order_type: int
    """The order type code (limit buy, limit sell, market buy, market sell, cancel)."""
    order_id: int
    """The order's unique identifier."""
    order_price: int
    """The order's limit price in ticks (unused for market and cancel orders)."""
    order_quantity: int
    """The order's share count (unused for cancel orders)."""


class MarketMakerGolden:
    """Replicates the market_maker Verilog module's FSM, fair-price ladder, and skew logic.

    Advances one cycle per tick call and emits at most one order, matching the
    single-order-per-grant constraint of the shared order bus. Tracks active quote identifiers
    for trade-snoop fill attribution, maintains last-trade and last-quoted-fair registers that
    drive the fair-price fallback and requote trigger, and optionally skews the half-spread by
    accumulated inventory when the v2 logic is enabled.

    Args:
        skew_enable: Determines whether to skew quotes by accumulated inventory (v2 when True).
        anchor_price: The cold-start fair price in ticks when book and tape are both empty.
        order_quantity: The number of shares per posted quote.
        half_spread_ticks: The nominal half-spread in ticks around the fair price.
        requote_threshold: The fair-price drift in ticks that triggers a requote sequence.
        skew_shift_bits: The arithmetic right shift applied to inventory to form the skew.
        max_skew_ticks: The saturation bound on the absolute value of the inventory skew.
        order_id_base: The lowest order_id this agent will issue.
        order_id_span: The size of this agent's reserved order_id block.
        price_range: The number of addressable price ticks, matching kPriceRange in the DUT.

    Attributes:
        skew_enable: Cached version-switch parameter that toggles v1 vs v2 spread logic.
        anchor_price: Cached cold-start fair price parameter.
        order_quantity: Cached per-quote share count parameter.
        half_spread_ticks: Cached nominal half-spread parameter.
        requote_threshold: Cached drift threshold parameter.
        skew_shift_bits: Cached skew right-shift parameter.
        max_skew_ticks: Cached skew saturation parameter.
        order_id_base: Cached lowest reserved order_id.
        order_id_span: Cached size of the reserved order_id block.
        price_range: Cached price-tick range parameter.
        _state: The current FSM state.
        _next_order_id: The identifier to use for the next emitted order.
        _active_bid_id: The identifier of the currently resting bid quote.
        _active_bid_valid: Determines whether the bid quote is live.
        _active_bid_price: The price of the currently resting bid quote.
        _active_ask_id: The identifier of the currently resting ask quote.
        _active_ask_valid: Determines whether the ask quote is live.
        _active_ask_price: The price of the currently resting ask quote.
        _net_inventory: The net position in shares (positive long, negative short).
        _last_trade_price: The most recent trade price observed on the snoop bus.
        _last_trade_price_valid: Determines whether _last_trade_price has been populated.
        _last_quoted_fair: The fair price at the moment of the most recent post.
        _last_quoted_fair_valid: Determines whether _last_quoted_fair has been populated.
    """

    def __init__(
        self,
        skew_enable: bool = False,
        anchor_price: int = 1024,
        order_quantity: int = 10,
        half_spread_ticks: int = 2,
        requote_threshold: int = 1,
        skew_shift_bits: int = 3,
        max_skew_ticks: int = 16,
        order_id_base: int = 10_000,
        order_id_span: int = 16_384,
        price_range: int = 2048,
    ) -> None:
        self.skew_enable: bool = skew_enable
        self.anchor_price: int = anchor_price
        self.order_quantity: int = order_quantity
        self.half_spread_ticks: int = half_spread_ticks
        self.requote_threshold: int = requote_threshold
        self.skew_shift_bits: int = skew_shift_bits
        self.max_skew_ticks: int = max_skew_ticks
        self.order_id_base: int = order_id_base
        self.order_id_span: int = order_id_span
        self.price_range: int = price_range

        self._state: State = State.INIT
        self._next_order_id: int = order_id_base

        self._active_bid_id: int = 0
        self._active_bid_valid: bool = False
        self._active_bid_price: int = 0
        self._active_ask_id: int = 0
        self._active_ask_valid: bool = False
        self._active_ask_price: int = 0

        self._net_inventory: int = 0
        self._last_trade_price: int = 0
        self._last_trade_price_valid: bool = False
        self._last_quoted_fair: int = 0
        self._last_quoted_fair_valid: bool = False

    def __repr__(self) -> str:
        """Returns a string representation of the MarketMakerGolden instance."""
        return (
            f"MarketMakerGolden(skew_enable={self.skew_enable}, state={self._state.name}, "
            f"net_inventory={self._net_inventory}, active_bid_valid={self._active_bid_valid}, "
            f"active_ask_valid={self._active_ask_valid})"
        )

    @property
    def net_inventory(self) -> int:
        """Returns the current net position in shares (positive long, negative short)."""
        return self._net_inventory

    @property
    def state(self) -> State:
        """Returns the current FSM state."""
        return self._state

    def tick(self, observation: BookObservation) -> OrderCommand | None:
        """Advances the FSM one cycle and optionally emits an order to submit.

        Applies the trade-snoop fill attribution first, then evaluates the FSM transition and
        action for the current state, mirroring the Verilog module's two independent always
        blocks. Returns a single order command when the active state drives the order bus on
        this cycle, or None when the state is idle or evaluates only triggers.

        Args:
            observation: The book state, trade snoop event, and arbiter grant for this cycle.

        Returns:
            The order command to submit this cycle, or None when no order is driven.
        """
        # Runs in every non-reset cycle so inventory and quote liveness stay accurate regardless
        # of the FSM's current action state, matching the independent fill-attribution always
        # block in the Verilog module.
        if observation.trade_valid:
            self._last_trade_price = observation.trade_price
            self._last_trade_price_valid = True
            is_bid_fill = (
                self._active_bid_valid and observation.trade_resting_id == self._active_bid_id
            )
            is_ask_fill = (
                self._active_ask_valid and observation.trade_resting_id == self._active_ask_id
            )
            if is_bid_fill:
                self._net_inventory += observation.trade_quantity
                self._active_bid_valid = False
            elif is_ask_fill:
                self._net_inventory -= observation.trade_quantity
                self._active_ask_valid = False

        fair = self._fair_price(observation=observation)
        new_bid_price, new_ask_price = self._quote_prices(fair=fair)

        if self._state == State.INIT:
            self._state = State.SEED_BID
            return None

        if self._state == State.SEED_BID:
            order = OrderCommand(
                order_type=TYPE_LIMIT_BUY,
                order_id=self._next_order_id,
                order_price=new_bid_price,
                order_quantity=self.order_quantity,
            )
            self._latch_bid(order_id=self._next_order_id, price=new_bid_price)
            self._next_order_id = self._advance_id()
            self._state = State.SEED_ASK
            return order

        if self._state == State.SEED_ASK:
            order = OrderCommand(
                order_type=TYPE_LIMIT_SELL,
                order_id=self._next_order_id,
                order_price=new_ask_price,
                order_quantity=self.order_quantity,
            )
            self._latch_ask(order_id=self._next_order_id, price=new_ask_price)
            self._next_order_id = self._advance_id()
            self._last_quoted_fair = fair
            self._last_quoted_fair_valid = True
            self._state = State.QUOTING
            return order

        if self._state == State.QUOTING:
            self._state = self._next_quoting_state(observation=observation, fair=fair)
            return None

        if self._state == State.REPLENISH_BID:
            order = OrderCommand(
                order_type=TYPE_LIMIT_BUY,
                order_id=self._next_order_id,
                order_price=new_bid_price,
                order_quantity=self.order_quantity,
            )
            self._latch_bid(order_id=self._next_order_id, price=new_bid_price)
            self._next_order_id = self._advance_id()
            self._state = State.QUOTING
            return order

        if self._state == State.REPLENISH_ASK:
            order = OrderCommand(
                order_type=TYPE_LIMIT_SELL,
                order_id=self._next_order_id,
                order_price=new_ask_price,
                order_quantity=self.order_quantity,
            )
            self._latch_ask(order_id=self._next_order_id, price=new_ask_price)
            self._next_order_id = self._advance_id()
            self._state = State.QUOTING
            return order

        if self._state == State.CANCEL_BID:
            if self._active_bid_valid:
                order = OrderCommand(
                    order_type=TYPE_CANCEL,
                    order_id=self._active_bid_id,
                    order_price=0,
                    order_quantity=0,
                )
                self._active_bid_valid = False
                self._state = State.CANCEL_ASK
                return order
            self._state = State.CANCEL_ASK
            return None

        if self._state == State.CANCEL_ASK:
            if self._active_ask_valid:
                order = OrderCommand(
                    order_type=TYPE_CANCEL,
                    order_id=self._active_ask_id,
                    order_price=0,
                    order_quantity=0,
                )
                self._active_ask_valid = False
                self._state = State.POST_BID
                return order
            self._state = State.POST_BID
            return None

        if self._state == State.POST_BID:
            order = OrderCommand(
                order_type=TYPE_LIMIT_BUY,
                order_id=self._next_order_id,
                order_price=new_bid_price,
                order_quantity=self.order_quantity,
            )
            self._latch_bid(order_id=self._next_order_id, price=new_bid_price)
            self._next_order_id = self._advance_id()
            self._state = State.POST_ASK
            return order

        if self._state == State.POST_ASK:
            order = OrderCommand(
                order_type=TYPE_LIMIT_SELL,
                order_id=self._next_order_id,
                order_price=new_ask_price,
                order_quantity=self.order_quantity,
            )
            self._latch_ask(order_id=self._next_order_id, price=new_ask_price)
            self._next_order_id = self._advance_id()
            self._last_quoted_fair = fair
            self._last_quoted_fair_valid = True
            self._state = State.QUOTING
            return order

        self._state = State.QUOTING
        return None

    def _fair_price(self, observation: BookObservation) -> int:
        """Returns the fair price via the priority ladder: mid, then last trade, then anchor."""
        if observation.best_bid_valid and observation.best_ask_valid:
            return (observation.best_bid_price + observation.best_ask_price) >> 1
        if self._last_trade_price_valid:
            return self._last_trade_price
        return self.anchor_price

    def _skew(self) -> int:
        """Returns the saturated inventory skew in ticks, or zero when the v2 logic is disabled."""
        if not self.skew_enable:
            return 0
        # Python's >> is arithmetic right shift on signed integers.
        raw = self._net_inventory >> self.skew_shift_bits
        if raw > self.max_skew_ticks:
            return self.max_skew_ticks
        if raw < -self.max_skew_ticks:
            return -self.max_skew_ticks
        return raw

    def _quote_prices(self, fair: int) -> tuple[int, int]:
        """Returns the (bid_price, ask_price) pair with inventory-asymmetric spreads and clamping."""
        skew = self._skew()
        skew_abs = abs(skew)
        bid_half = self.half_spread_ticks + (skew_abs if skew > 0 else 0)
        ask_half = self.half_spread_ticks + (skew_abs if skew < 0 else 0)
        bid_price = max(1, fair - bid_half)
        ask_price = min(self.price_range - 1, fair + ask_half)
        return bid_price, ask_price

    def _next_quoting_state(self, observation: BookObservation, fair: int) -> State:
        """Returns the next state when currently in QUOTING, using priority-ordered triggers."""
        if not self._active_bid_valid:
            return State.REPLENISH_BID
        if not self._active_ask_valid:
            return State.REPLENISH_ASK
        if not observation.best_bid_valid:
            return State.REPLENISH_BID
        if not observation.best_ask_valid:
            return State.REPLENISH_ASK
        if (
            self._last_quoted_fair_valid
            and abs(fair - self._last_quoted_fair) >= self.requote_threshold
        ):
            return State.CANCEL_BID
        return State.QUOTING

    def _latch_bid(self, order_id: int, price: int) -> None:
        """Records a newly posted bid quote for later fill attribution and cancellation."""
        self._active_bid_id = order_id
        self._active_bid_valid = True
        self._active_bid_price = price

    def _latch_ask(self, order_id: int, price: int) -> None:
        """Records a newly posted ask quote for later fill attribution and cancellation."""
        self._active_ask_id = order_id
        self._active_ask_valid = True
        self._active_ask_price = price

    def _advance_id(self) -> int:
        """Returns the next order_id, wrapping at the top of the reserved block."""
        candidate = self._next_order_id + 1
        if candidate >= self.order_id_base + self.order_id_span:
            return self.order_id_base
        return candidate
