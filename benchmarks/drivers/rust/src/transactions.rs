use deadpool_postgres::Pool;

use crate::mix::{
    DeliveryParams, NewOrderParams, OrderStatusParams, PaymentParams, StockLevelParams,
};

fn esc(s: &str) -> String {
    s.replace('\'', "''")
}

pub struct TpccRunner {
    pub pool: Pool,
}

impl TpccRunner {
    pub fn new(pool: Pool) -> Self {
        Self { pool }
    }

    pub async fn new_order(&self, p: NewOrderParams) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;

        let _ = tx
            .query(
                &format!(
                    "SELECT c_discount, c_last, c_credit FROM customer \
                     WHERE c_w_id={} AND c_d_id={} AND c_id={}",
                    p.w_id, p.d_id, p.c_id
                ),
                &[],
            )
            .await?;
        let _ = tx
            .query(&format!("SELECT w_tax FROM warehouse WHERE w_id={}", p.w_id), &[])
            .await?;

        let d_row = tx
            .query_one(
                &format!(
                    "SELECT d_next_o_id, d_tax FROM district \
                     WHERE d_w_id={} AND d_id={} FOR UPDATE",
                    p.w_id, p.d_id
                ),
                &[],
            )
            .await?;
        let o_id: i32 = d_row.get("d_next_o_id");

        tx.execute(
            &format!(
                "UPDATE district SET d_next_o_id = d_next_o_id + 1 \
                 WHERE d_w_id={} AND d_id={}",
                p.w_id, p.d_id
            ),
            &[],
        )
        .await?;

        let all_local = if p.lines.iter().all(|l| l.supply_w_id == p.w_id) { 1 } else { 0 };
        tx.execute(
            &format!(
                "INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) \
                 VALUES ({}, {}, {}, {}, NOW(), NULL, {}, {})",
                p.w_id, p.d_id, o_id, p.c_id, p.lines.len(), all_local
            ),
            &[],
        )
        .await?;

        tx.execute(
            &format!(
                "INSERT INTO new_order (no_w_id, no_d_id, no_o_id) \
                 VALUES ({}, {}, {})",
                p.w_id, p.d_id, o_id
            ),
            &[],
        )
        .await?;

        for (idx, line) in p.lines.iter().enumerate() {
            let ol_number = idx + 1;
            let i_row = tx
                .query_one(
                    &format!(
                        "SELECT i_price::FLOAT8 AS i_price, i_name, i_data FROM item WHERE i_id={}",
                        line.i_id
                    ),
                    &[],
                )
                .await?;
            let price: f64 = i_row.get("i_price");

            let s_row = tx
                .query_one(
                    &format!(
                        "SELECT s_quantity, s_dist_info, s_ytd::FLOAT8 AS s_ytd, s_order_cnt, s_remote_cnt \
                         FROM stock WHERE s_w_id={} AND s_i_id={} FOR UPDATE",
                        line.supply_w_id, line.i_id
                    ),
                    &[],
                )
                .await?;
            let s_qty: i32 = s_row.get("s_quantity");
            let s_dist: String = s_row.get("s_dist_info");
            let s_ytd: f64 = s_row.get("s_ytd");
            let s_order_cnt: i32 = s_row.get("s_order_cnt");
            let s_remote_cnt: i32 = s_row.get("s_remote_cnt");

            let new_qty = if s_qty - line.quantity >= 10 {
                s_qty - line.quantity
            } else {
                s_qty - line.quantity + 91
            };
            let remote_inc = if line.supply_w_id == p.w_id { 0 } else { 1 };

            tx.execute(
                &format!(
                    "UPDATE stock SET s_quantity={}, s_ytd={:.2}, \
                     s_order_cnt={}, s_remote_cnt={} \
                     WHERE s_w_id={} AND s_i_id={}",
                    new_qty,
                    s_ytd + line.quantity as f64,
                    s_order_cnt + 1,
                    s_remote_cnt + remote_inc,
                    line.supply_w_id,
                    line.i_id
                ),
                &[],
            )
            .await?;

            let amount = line.quantity as f64 * price;
            let s_dist_esc = esc(&s_dist);
            tx.execute(
                &format!(
                    "INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) \
                     VALUES ({}, {}, {}, {}, {}, {}, NULL, {}, {:.2}, '{}')",
                    p.w_id, p.d_id, o_id, ol_number, line.i_id, line.supply_w_id,
                    line.quantity, amount, s_dist_esc
                ),
                &[],
            )
            .await?;
        }

        tx.commit().await?;
        Ok(())
    }

    pub async fn payment(&self, p: PaymentParams) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let amt = format!("{:.2}", p.amount);
        tx.execute(
            &format!("UPDATE warehouse SET w_ytd = w_ytd + {} WHERE w_id={}", amt, p.w_id),
            &[],
        )
        .await?;
        let _ = tx
            .query(
                &format!(
                    "SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse WHERE w_id={}",
                    p.w_id
                ),
                &[],
            )
            .await?;
        tx.execute(
            &format!(
                "UPDATE district SET d_ytd = d_ytd + {} \
                 WHERE d_w_id={} AND d_id={}",
                amt, p.w_id, p.d_id
            ),
            &[],
        )
        .await?;
        let _ = tx
            .query(
                &format!(
                    "SELECT d_name, d_street, d_city, d_state, d_zip FROM district \
                     WHERE d_w_id={} AND d_id={}",
                    p.w_id, p.d_id
                ),
                &[],
            )
            .await?;
        let _ = tx
            .query(
                &format!(
                    "SELECT c_first, c_middle, c_last, c_balance, c_credit \
                     FROM customer WHERE c_w_id={} AND c_d_id={} AND c_id={}",
                    p.w_id, p.d_id, p.c_id
                ),
                &[],
            )
            .await?;
        tx.execute(
            &format!(
                "UPDATE customer SET c_balance = c_balance - {}, \
                 c_ytd_payment = c_ytd_payment + {}, c_payment_cnt = c_payment_cnt + 1 \
                 WHERE c_w_id={} AND c_d_id={} AND c_id={}",
                amt, amt, p.w_id, p.d_id, p.c_id
            ),
            &[],
        )
        .await?;
        tx.execute(
            &format!(
                "INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) \
                 VALUES ({}, {}, {}, {}, {}, NOW(), {}, 'BENCH')",
                p.c_id, p.d_id, p.w_id, p.d_id, p.w_id, amt
            ),
            &[],
        )
        .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn order_status(&self, p: OrderStatusParams) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let _ = tx
            .query(
                &format!(
                    "SELECT c_first, c_middle, c_last, c_balance FROM customer \
                     WHERE c_w_id={} AND c_d_id={} AND c_id={}",
                    p.w_id, p.d_id, p.c_id
                ),
                &[],
            )
            .await?;
        let rows = tx
            .query(
                &format!(
                    "SELECT o_id, o_entry_d, o_carrier_id FROM orders \
                     WHERE o_w_id={} AND o_d_id={} AND o_c_id={} \
                     ORDER BY o_id DESC LIMIT 1",
                    p.w_id, p.d_id, p.c_id
                ),
                &[],
            )
            .await?;
        if let Some(row) = rows.first() {
            let o_id: i32 = row.get("o_id");
            let _ = tx
                .query(
                    &format!(
                        "SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d \
                         FROM order_line WHERE ol_w_id={} AND ol_d_id={} AND ol_o_id={}",
                        p.w_id, p.d_id, o_id
                    ),
                    &[],
                )
                .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn delivery(&self, p: DeliveryParams) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        for d_id in 1..=10i32 {
            let no_rows = tx
                .query(
                    &format!(
                        "SELECT no_o_id FROM new_order \
                         WHERE no_w_id={} AND no_d_id={} \
                         ORDER BY no_o_id ASC LIMIT 1",
                        p.w_id, d_id
                    ),
                    &[],
                )
                .await?;
            let o_id = match no_rows.first() {
                Some(r) => r.get::<_, i32>("no_o_id"),
                None => continue,
            };
            tx.execute(
                &format!(
                    "DELETE FROM new_order WHERE no_w_id={} AND no_d_id={} AND no_o_id={}",
                    p.w_id, d_id, o_id
                ),
                &[],
            )
            .await?;
            let o_row = tx
                .query_one(
                    &format!(
                        "SELECT o_c_id FROM orders \
                         WHERE o_w_id={} AND o_d_id={} AND o_id={}",
                        p.w_id, d_id, o_id
                    ),
                    &[],
                )
                .await?;
            let c_id: i32 = o_row.get("o_c_id");
            tx.execute(
                &format!(
                    "UPDATE orders SET o_carrier_id={} \
                     WHERE o_w_id={} AND o_d_id={} AND o_id={}",
                    p.carrier_id, p.w_id, d_id, o_id
                ),
                &[],
            )
            .await?;
            tx.execute(
                &format!(
                    "UPDATE order_line SET ol_delivery_d=NOW() \
                     WHERE ol_w_id={} AND ol_d_id={} AND ol_o_id={}",
                    p.w_id, d_id, o_id
                ),
                &[],
            )
            .await?;
            let amt_row = tx
                .query_one(
                    &format!(
                        "SELECT COALESCE(SUM(ol_amount), 0)::FLOAT8 AS total FROM order_line \
                         WHERE ol_w_id={} AND ol_d_id={} AND ol_o_id={}",
                        p.w_id, d_id, o_id
                    ),
                    &[],
                )
                .await?;
            let amount: f64 = amt_row.get("total");
            tx.execute(
                &format!(
                    "UPDATE customer SET c_balance = c_balance + {:.2}, \
                     c_delivery_cnt = c_delivery_cnt + 1 \
                     WHERE c_w_id={} AND c_d_id={} AND c_id={}",
                    amount, p.w_id, d_id, c_id
                ),
                &[],
            )
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn stock_level(&self, p: StockLevelParams) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut client = self.pool.get().await?;
        let tx = client.transaction().await?;
        let d_row = tx
            .query_one(
                &format!(
                    "SELECT d_next_o_id FROM district WHERE d_w_id={} AND d_id={}",
                    p.w_id, p.d_id
                ),
                &[],
            )
            .await?;
        let next_o_id: i32 = d_row.get("d_next_o_id");
        let low_o_id = next_o_id - 20;
        let _ = tx
            .query(
                &format!(
                    "SELECT COUNT(DISTINCT s.s_i_id) AS low_stock FROM order_line ol \
                     JOIN stock s ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id \
                     WHERE ol.ol_w_id={} AND ol.ol_d_id={} \
                       AND ol.ol_o_id >= {} AND ol.ol_o_id < {} \
                       AND s.s_quantity < {}",
                    p.w_id, p.d_id, low_o_id, next_o_id, p.threshold
                ),
                &[],
            )
            .await?;
        tx.commit().await?;
        Ok(())
    }
}
