"""TPC-C mix + parameter generation with seeded RNG."""

import random
from dataclasses import dataclass

K_WAREHOUSES = 3
K_DISTRICTS_PER_WAREHOUSE = 10
K_CUSTOMERS_PER_DISTRICT = 300
K_ITEMS = 100_000

TX_NEW_ORDER = "newOrder"
TX_PAYMENT = "payment"
TX_ORDER_STATUS = "orderStatus"
TX_DELIVERY = "delivery"
TX_STOCK_LEVEL = "stockLevel"


@dataclass(slots=True)
class NewOrderLine:
    i_id: int
    supply_w_id: int
    quantity: int


@dataclass(slots=True)
class NewOrderParams:
    w_id: int
    d_id: int
    c_id: int
    lines: list[NewOrderLine]


@dataclass(slots=True)
class PaymentParams:
    w_id: int
    d_id: int
    c_id: int
    amount: float


@dataclass(slots=True)
class OrderStatusParams:
    w_id: int
    d_id: int
    c_id: int


@dataclass(slots=True)
class DeliveryParams:
    w_id: int
    carrier_id: int


@dataclass(slots=True)
class StockLevelParams:
    w_id: int
    d_id: int
    threshold: int


class TpccMix:
    def __init__(self, seed: int) -> None:
        self.rng = random.Random(seed)

    def next_type(self) -> str:
        r = self.rng.randrange(100)
        if r < 45:
            return TX_NEW_ORDER
        if r < 88:
            return TX_PAYMENT
        if r < 92:
            return TX_ORDER_STATUS
        if r < 96:
            return TX_DELIVERY
        return TX_STOCK_LEVEL

    def _w(self) -> int:
        return 1 + self.rng.randrange(K_WAREHOUSES)

    def _d(self) -> int:
        return 1 + self.rng.randrange(K_DISTRICTS_PER_WAREHOUSE)

    def _c(self) -> int:
        return 1 + self.rng.randrange(K_CUSTOMERS_PER_DISTRICT)

    def _item(self) -> int:
        return 1 + self.rng.randrange(K_ITEMS)

    def new_order(self) -> NewOrderParams:
        w_id = self._w()
        ol_cnt = 5 + self.rng.randrange(11)
        lines: list[NewOrderLine] = []
        for _ in range(ol_cnt):
            remote = self.rng.randrange(100) == 0
            supply_w_id = 1 + self.rng.randrange(K_WAREHOUSES) if remote else w_id
            lines.append(
                NewOrderLine(
                    i_id=self._item(),
                    supply_w_id=supply_w_id,
                    quantity=1 + self.rng.randrange(10),
                )
            )
        return NewOrderParams(w_id=w_id, d_id=self._d(), c_id=self._c(), lines=lines)

    def payment(self) -> PaymentParams:
        amount = 1.0 + self.rng.randrange(5000) + self.rng.random()
        return PaymentParams(
            w_id=self._w(),
            d_id=self._d(),
            c_id=self._c(),
            amount=round(amount, 2),
        )

    def order_status(self) -> OrderStatusParams:
        return OrderStatusParams(w_id=self._w(), d_id=self._d(), c_id=self._c())

    def delivery(self) -> DeliveryParams:
        return DeliveryParams(w_id=self._w(), carrier_id=1 + self.rng.randrange(10))

    def stock_level(self) -> StockLevelParams:
        return StockLevelParams(
            w_id=self._w(), d_id=self._d(), threshold=10 + self.rng.randrange(11)
        )
