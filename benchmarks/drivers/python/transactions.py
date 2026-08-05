"""TPC-C transactions in Python using asyncpg.

Port of `benchmarks/scripts/tpcc/transactions_native.dart`. SQL is
string-interpolated for apples-to-apples comparison (no prepared
statements, no parameter binding).
"""

from __future__ import annotations

import asyncpg

from mix import (
    DeliveryParams,
    NewOrderParams,
    OrderStatusParams,
    PaymentParams,
    StockLevelParams,
)


def _esc(s: str) -> str:
    return s.replace("'", "''")


def _f2(x: float) -> str:
    return f"{x:.2f}"


class TpccRunner:
    def __init__(self, pool: asyncpg.Pool) -> None:
        self.pool = pool

    async def new_order(self, p: NewOrderParams) -> None:
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                await conn.fetch(
                    f"SELECT c_discount, c_last, c_credit FROM customer "
                    f"WHERE c_w_id={p.w_id} AND c_d_id={p.d_id} AND c_id={p.c_id}"
                )
                await conn.fetch(f"SELECT w_tax FROM warehouse WHERE w_id={p.w_id}")

                d_row = await conn.fetchrow(
                    f"SELECT d_next_o_id, d_tax FROM district "
                    f"WHERE d_w_id={p.w_id} AND d_id={p.d_id} FOR UPDATE"
                )
                o_id = d_row["d_next_o_id"]

                await conn.execute(
                    f"UPDATE district SET d_next_o_id = d_next_o_id + 1 "
                    f"WHERE d_w_id={p.w_id} AND d_id={p.d_id}"
                )

                all_local = 1 if all(l.supply_w_id == p.w_id for l in p.lines) else 0
                await conn.execute(
                    f"INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) "
                    f"VALUES ({p.w_id}, {p.d_id}, {o_id}, {p.c_id}, NOW(), NULL, {len(p.lines)}, {all_local})"
                )
                await conn.execute(
                    f"INSERT INTO new_order (no_w_id, no_d_id, no_o_id) "
                    f"VALUES ({p.w_id}, {p.d_id}, {o_id})"
                )

                for ol_number, line in enumerate(p.lines, start=1):
                    i_row = await conn.fetchrow(
                        f"SELECT i_price, i_name, i_data FROM item WHERE i_id={line.i_id}"
                    )
                    price = float(i_row["i_price"])

                    s_row = await conn.fetchrow(
                        f"SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt "
                        f"FROM stock WHERE s_w_id={line.supply_w_id} AND s_i_id={line.i_id} FOR UPDATE"
                    )
                    s_qty = s_row["s_quantity"]
                    s_dist = s_row["s_dist_info"]
                    s_ytd = float(s_row["s_ytd"])
                    s_order_cnt = s_row["s_order_cnt"]
                    s_remote_cnt = s_row["s_remote_cnt"]

                    new_qty = (
                        s_qty - line.quantity
                        if s_qty - line.quantity >= 10
                        else s_qty - line.quantity + 91
                    )
                    remote_inc = 0 if line.supply_w_id == p.w_id else 1

                    await conn.execute(
                        f"UPDATE stock SET s_quantity={new_qty}, "
                        f"s_ytd={_f2(s_ytd + line.quantity)}, "
                        f"s_order_cnt={s_order_cnt + 1}, "
                        f"s_remote_cnt={s_remote_cnt + remote_inc} "
                        f"WHERE s_w_id={line.supply_w_id} AND s_i_id={line.i_id}"
                    )

                    amount = _f2(line.quantity * price)
                    s_dist_esc = _esc(s_dist)
                    await conn.execute(
                        f"INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) "
                        f"VALUES ({p.w_id}, {p.d_id}, {o_id}, {ol_number}, {line.i_id}, {line.supply_w_id}, NULL, {line.quantity}, {amount}, '{s_dist_esc}')"
                    )

    async def payment(self, p: PaymentParams) -> None:
        amt = _f2(p.amount)
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute(
                    f"UPDATE warehouse SET w_ytd = w_ytd + {amt} WHERE w_id={p.w_id}"
                )
                await conn.fetch(
                    f"SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse WHERE w_id={p.w_id}"
                )
                await conn.execute(
                    f"UPDATE district SET d_ytd = d_ytd + {amt} "
                    f"WHERE d_w_id={p.w_id} AND d_id={p.d_id}"
                )
                await conn.fetch(
                    f"SELECT d_name, d_street, d_city, d_state, d_zip FROM district "
                    f"WHERE d_w_id={p.w_id} AND d_id={p.d_id}"
                )
                await conn.fetch(
                    f"SELECT c_first, c_middle, c_last, c_balance, c_credit "
                    f"FROM customer WHERE c_w_id={p.w_id} AND c_d_id={p.d_id} AND c_id={p.c_id}"
                )
                await conn.execute(
                    f"UPDATE customer SET c_balance = c_balance - {amt}, "
                    f"c_ytd_payment = c_ytd_payment + {amt}, "
                    f"c_payment_cnt = c_payment_cnt + 1 "
                    f"WHERE c_w_id={p.w_id} AND c_d_id={p.d_id} AND c_id={p.c_id}"
                )
                await conn.execute(
                    f"INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) "
                    f"VALUES ({p.c_id}, {p.d_id}, {p.w_id}, {p.d_id}, {p.w_id}, NOW(), {amt}, 'BENCH')"
                )

    async def order_status(self, p: OrderStatusParams) -> None:
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                await conn.fetch(
                    f"SELECT c_first, c_middle, c_last, c_balance FROM customer "
                    f"WHERE c_w_id={p.w_id} AND c_d_id={p.d_id} AND c_id={p.c_id}"
                )
                o_row = await conn.fetchrow(
                    f"SELECT o_id, o_entry_d, o_carrier_id FROM orders "
                    f"WHERE o_w_id={p.w_id} AND o_d_id={p.d_id} AND o_c_id={p.c_id} "
                    f"ORDER BY o_id DESC LIMIT 1"
                )
                if o_row is None:
                    return
                o_id = o_row["o_id"]
                await conn.fetch(
                    f"SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d "
                    f"FROM order_line WHERE ol_w_id={p.w_id} AND ol_d_id={p.d_id} AND ol_o_id={o_id}"
                )

    async def delivery(self, p: DeliveryParams) -> None:
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                for d_id in range(1, 11):
                    no_row = await conn.fetchrow(
                        f"SELECT no_o_id FROM new_order "
                        f"WHERE no_w_id={p.w_id} AND no_d_id={d_id} "
                        f"ORDER BY no_o_id ASC LIMIT 1"
                    )
                    if no_row is None:
                        continue
                    o_id = no_row["no_o_id"]
                    await conn.execute(
                        f"DELETE FROM new_order WHERE no_w_id={p.w_id} AND no_d_id={d_id} AND no_o_id={o_id}"
                    )
                    o_row = await conn.fetchrow(
                        f"SELECT o_c_id FROM orders "
                        f"WHERE o_w_id={p.w_id} AND o_d_id={d_id} AND o_id={o_id}"
                    )
                    c_id = o_row["o_c_id"]
                    await conn.execute(
                        f"UPDATE orders SET o_carrier_id={p.carrier_id} "
                        f"WHERE o_w_id={p.w_id} AND o_d_id={d_id} AND o_id={o_id}"
                    )
                    await conn.execute(
                        f"UPDATE order_line SET ol_delivery_d=NOW() "
                        f"WHERE ol_w_id={p.w_id} AND ol_d_id={d_id} AND ol_o_id={o_id}"
                    )
                    amt_row = await conn.fetchrow(
                        f"SELECT COALESCE(SUM(ol_amount), 0) AS total FROM order_line "
                        f"WHERE ol_w_id={p.w_id} AND ol_d_id={d_id} AND ol_o_id={o_id}"
                    )
                    amount = float(amt_row["total"])
                    await conn.execute(
                        f"UPDATE customer SET c_balance = c_balance + {_f2(amount)}, "
                        f"c_delivery_cnt = c_delivery_cnt + 1 "
                        f"WHERE c_w_id={p.w_id} AND c_d_id={d_id} AND c_id={c_id}"
                    )

    async def stock_level(self, p: StockLevelParams) -> None:
        async with self.pool.acquire() as conn:
            async with conn.transaction():
                d_row = await conn.fetchrow(
                    f"SELECT d_next_o_id FROM district "
                    f"WHERE d_w_id={p.w_id} AND d_id={p.d_id}"
                )
                next_o_id = d_row["d_next_o_id"]
                low_o_id = next_o_id - 20
                await conn.fetchrow(
                    f"SELECT COUNT(DISTINCT s.s_i_id) AS low_stock FROM order_line ol "
                    f"JOIN stock s ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id "
                    f"WHERE ol.ol_w_id={p.w_id} AND ol.ol_d_id={p.d_id} "
                    f"  AND ol.ol_o_id >= {low_o_id} AND ol.ol_o_id < {next_o_id} "
                    f"  AND s.s_quantity < {p.threshold}"
                )
