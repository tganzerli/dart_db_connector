// TPC-C transactions in Node using postgres.js (postgres@3).
// Port of `benchmarks/scripts/tpcc/transactions_native.dart`. SQL is
// string-interpolated for apples-to-apples comparison (no prepared
// statements, no parameter binding).

function esc(s) {
  return String(s).replace(/'/g, "''");
}

function fmt2(n) {
  return n.toFixed(2);
}

export class TpccRunner {
  constructor(sql) {
    this.sql = sql; // postgres.js client
  }

  async withTx(fn) {
    return this.sql.begin(async (tx) => fn(tx));
  }

  async newOrder(p) {
    return this.withTx(async (tx) => {
      await tx.unsafe(
        `SELECT c_discount, c_last, c_credit FROM customer ` +
          `WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}`,
      );
      await tx.unsafe(`SELECT w_tax FROM warehouse WHERE w_id=${p.wId}`);

      const dRows = await tx.unsafe(
        `SELECT d_next_o_id, d_tax FROM district ` +
          `WHERE d_w_id=${p.wId} AND d_id=${p.dId} FOR UPDATE`,
      );
      if (dRows.length === 0) return;
      const oId = dRows[0].d_next_o_id;

      await tx.unsafe(
        `UPDATE district SET d_next_o_id = d_next_o_id + 1 ` +
          `WHERE d_w_id=${p.wId} AND d_id=${p.dId}`,
      );

      const allLocal = p.lines.every((l) => l.supplyWId === p.wId) ? 1 : 0;
      await tx.unsafe(
        `INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) ` +
          `VALUES (${p.wId}, ${p.dId}, ${oId}, ${p.cId}, NOW(), NULL, ${p.lines.length}, ${allLocal})`,
      );
      await tx.unsafe(
        `INSERT INTO new_order (no_w_id, no_d_id, no_o_id) ` +
          `VALUES (${p.wId}, ${p.dId}, ${oId})`,
      );

      for (let olNumber = 1; olNumber <= p.lines.length; olNumber++) {
        const line = p.lines[olNumber - 1];
        const iRows = await tx.unsafe(
          `SELECT i_price, i_name, i_data FROM item WHERE i_id=${line.iId}`,
        );
        const price = Number(iRows[0].i_price);

        const sRows = await tx.unsafe(
          `SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt ` +
            `FROM stock WHERE s_w_id=${line.supplyWId} AND s_i_id=${line.iId} FOR UPDATE`,
        );
        const s = sRows[0];
        const sQty = s.s_quantity;
        const sDist = s.s_dist_info;
        const sYtd = Number(s.s_ytd);
        const sOrderCnt = s.s_order_cnt;
        const sRemoteCnt = s.s_remote_cnt;

        const newQty =
          sQty - line.quantity >= 10
            ? sQty - line.quantity
            : sQty - line.quantity + 91;
        const remoteInc = line.supplyWId === p.wId ? 0 : 1;

        await tx.unsafe(
          `UPDATE stock SET s_quantity=${newQty}, ` +
            `s_ytd=${fmt2(sYtd + line.quantity)}, ` +
            `s_order_cnt=${sOrderCnt + 1}, ` +
            `s_remote_cnt=${sRemoteCnt + remoteInc} ` +
            `WHERE s_w_id=${line.supplyWId} AND s_i_id=${line.iId}`,
        );

        const amount = fmt2(line.quantity * price);
        const sDistEsc = esc(sDist);
        await tx.unsafe(
          `INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) ` +
            `VALUES (${p.wId}, ${p.dId}, ${oId}, ${olNumber}, ${line.iId}, ${line.supplyWId}, NULL, ${line.quantity}, ${amount}, '${sDistEsc}')`,
        );
      }
    });
  }

  async payment(p) {
    return this.withTx(async (tx) => {
      const amt = fmt2(p.amount);
      await tx.unsafe(`UPDATE warehouse SET w_ytd = w_ytd + ${amt} WHERE w_id=${p.wId}`);
      await tx.unsafe(
        `SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse WHERE w_id=${p.wId}`,
      );
      await tx.unsafe(
        `UPDATE district SET d_ytd = d_ytd + ${amt} ` +
          `WHERE d_w_id=${p.wId} AND d_id=${p.dId}`,
      );
      await tx.unsafe(
        `SELECT d_name, d_street, d_city, d_state, d_zip FROM district ` +
          `WHERE d_w_id=${p.wId} AND d_id=${p.dId}`,
      );
      await tx.unsafe(
        `SELECT c_first, c_middle, c_last, c_balance, c_credit ` +
          `FROM customer WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}`,
      );
      await tx.unsafe(
        `UPDATE customer SET c_balance = c_balance - ${amt}, ` +
          `c_ytd_payment = c_ytd_payment + ${amt}, ` +
          `c_payment_cnt = c_payment_cnt + 1 ` +
          `WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}`,
      );
      await tx.unsafe(
        `INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) ` +
          `VALUES (${p.cId}, ${p.dId}, ${p.wId}, ${p.dId}, ${p.wId}, NOW(), ${amt}, 'BENCH')`,
      );
    });
  }

  async orderStatus(p) {
    return this.withTx(async (tx) => {
      await tx.unsafe(
        `SELECT c_first, c_middle, c_last, c_balance FROM customer ` +
          `WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}`,
      );
      const oRows = await tx.unsafe(
        `SELECT o_id, o_entry_d, o_carrier_id FROM orders ` +
          `WHERE o_w_id=${p.wId} AND o_d_id=${p.dId} AND o_c_id=${p.cId} ` +
          `ORDER BY o_id DESC LIMIT 1`,
      );
      if (oRows.length === 0) return;
      const oId = oRows[0].o_id;
      await tx.unsafe(
        `SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d ` +
          `FROM order_line WHERE ol_w_id=${p.wId} AND ol_d_id=${p.dId} AND ol_o_id=${oId}`,
      );
    });
  }

  async delivery(p) {
    return this.withTx(async (tx) => {
      for (let dId = 1; dId <= 10; dId++) {
        const noRows = await tx.unsafe(
          `SELECT no_o_id FROM new_order ` +
            `WHERE no_w_id=${p.wId} AND no_d_id=${dId} ` +
            `ORDER BY no_o_id ASC LIMIT 1`,
        );
        if (noRows.length === 0) continue;
        const oId = noRows[0].no_o_id;
        await tx.unsafe(
          `DELETE FROM new_order WHERE no_w_id=${p.wId} AND no_d_id=${dId} AND no_o_id=${oId}`,
        );
        const oRows = await tx.unsafe(
          `SELECT o_c_id FROM orders ` +
            `WHERE o_w_id=${p.wId} AND o_d_id=${dId} AND o_id=${oId}`,
        );
        const cId = oRows[0].o_c_id;
        await tx.unsafe(
          `UPDATE orders SET o_carrier_id=${p.carrierId} ` +
            `WHERE o_w_id=${p.wId} AND o_d_id=${dId} AND o_id=${oId}`,
        );
        await tx.unsafe(
          `UPDATE order_line SET ol_delivery_d=NOW() ` +
            `WHERE ol_w_id=${p.wId} AND ol_d_id=${dId} AND ol_o_id=${oId}`,
        );
        const amtRows = await tx.unsafe(
          `SELECT COALESCE(SUM(ol_amount), 0) AS total FROM order_line ` +
            `WHERE ol_w_id=${p.wId} AND ol_d_id=${dId} AND ol_o_id=${oId}`,
        );
        const amount = Number(amtRows[0].total);
        await tx.unsafe(
          `UPDATE customer SET c_balance = c_balance + ${fmt2(amount)}, ` +
            `c_delivery_cnt = c_delivery_cnt + 1 ` +
            `WHERE c_w_id=${p.wId} AND c_d_id=${dId} AND c_id=${cId}`,
        );
      }
    });
  }

  async stockLevel(p) {
    return this.withTx(async (tx) => {
      const dRows = await tx.unsafe(
        `SELECT d_next_o_id FROM district ` +
          `WHERE d_w_id=${p.wId} AND d_id=${p.dId}`,
      );
      const nextOId = dRows[0].d_next_o_id;
      const lowOId = nextOId - 20;
      await tx.unsafe(
        `SELECT COUNT(DISTINCT s.s_i_id) AS low_stock FROM order_line ol ` +
          `JOIN stock s ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id ` +
          `WHERE ol.ol_w_id=${p.wId} AND ol.ol_d_id=${p.dId} ` +
          `  AND ol.ol_o_id >= ${lowOId} AND ol.ol_o_id < ${nextOId} ` +
          `  AND s.s_quantity < ${p.threshold}`,
      );
    });
  }
}
