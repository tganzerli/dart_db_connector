package main

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TpccRunner ports the 5 transactions from
// `benchmarks/scripts/tpcc/transactions_native.dart`. SQL is identical
// (string-interpolated, no parameter binding) for apples-to-apples
// comparison.
type TpccRunner struct {
	pool *pgxpool.Pool
}

func NewTpccRunner(pool *pgxpool.Pool) *TpccRunner { return &TpccRunner{pool: pool} }

func (r *TpccRunner) withTx(ctx context.Context, fn func(pgx.Tx) error) error {
	conn, err := r.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

func discard(rows pgx.Rows) {
	defer rows.Close()
	for rows.Next() {
		// touch values to force decode
		_, _ = rows.Values()
	}
}

func (r *TpccRunner) NewOrder(ctx context.Context, p NewOrderParams) error {
	return r.withTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, fmt.Sprintf(
			"SELECT c_discount, c_last, c_credit FROM customer "+
				"WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.WID, p.DID, p.CID))
		if err != nil {
			return err
		}
		discard(rows)

		rows, err = tx.Query(ctx, fmt.Sprintf("SELECT w_tax FROM warehouse WHERE w_id=%d", p.WID))
		if err != nil {
			return err
		}
		discard(rows)

		var oID int
		var dTax float64
		err = tx.QueryRow(ctx, fmt.Sprintf(
			"SELECT d_next_o_id, d_tax FROM district "+
				"WHERE d_w_id=%d AND d_id=%d FOR UPDATE",
			p.WID, p.DID)).Scan(&oID, &dTax)
		if err != nil {
			return err
		}

		_, err = tx.Exec(ctx, fmt.Sprintf(
			"UPDATE district SET d_next_o_id = d_next_o_id + 1 "+
				"WHERE d_w_id=%d AND d_id=%d", p.WID, p.DID))
		if err != nil {
			return err
		}

		allLocal := 1
		for _, l := range p.Lines {
			if l.SupplyWID != p.WID {
				allLocal = 0
				break
			}
		}
		_, err = tx.Exec(ctx, fmt.Sprintf(
			"INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) "+
				"VALUES (%d, %d, %d, %d, NOW(), NULL, %d, %d)",
			p.WID, p.DID, oID, p.CID, len(p.Lines), allLocal))
		if err != nil {
			return err
		}

		_, err = tx.Exec(ctx, fmt.Sprintf(
			"INSERT INTO new_order (no_w_id, no_d_id, no_o_id) VALUES (%d, %d, %d)",
			p.WID, p.DID, oID))
		if err != nil {
			return err
		}

		for olNumber, line := range p.Lines {
			olNumber++
			var price float64
			var iName, iData string
			err = tx.QueryRow(ctx, fmt.Sprintf(
				"SELECT i_price, i_name, i_data FROM item WHERE i_id=%d", line.IID)).
				Scan(&price, &iName, &iData)
			if err != nil {
				return err
			}

			var sQty, sOrderCnt, sRemoteCnt int
			var sDist string
			var sYtd float64
			err = tx.QueryRow(ctx, fmt.Sprintf(
				"SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt "+
					"FROM stock WHERE s_w_id=%d AND s_i_id=%d FOR UPDATE",
				line.SupplyWID, line.IID)).
				Scan(&sQty, &sDist, &sYtd, &sOrderCnt, &sRemoteCnt)
			if err != nil {
				return err
			}

			newQty := sQty - line.Quantity
			if newQty < 10 {
				newQty += 91
			}
			remoteInc := 0
			if line.SupplyWID != p.WID {
				remoteInc = 1
			}
			_, err = tx.Exec(ctx, fmt.Sprintf(
				"UPDATE stock SET s_quantity=%d, s_ytd=%.2f, s_order_cnt=%d, s_remote_cnt=%d "+
					"WHERE s_w_id=%d AND s_i_id=%d",
				newQty, sYtd+float64(line.Quantity),
				sOrderCnt+1, sRemoteCnt+remoteInc,
				line.SupplyWID, line.IID))
			if err != nil {
				return err
			}

			amount := float64(line.Quantity) * price
			sDistEsc := escapeSQL(sDist)
			_, err = tx.Exec(ctx, fmt.Sprintf(
				"INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) "+
					"VALUES (%d, %d, %d, %d, %d, %d, NULL, %d, %.2f, '%s')",
				p.WID, p.DID, oID, olNumber, line.IID, line.SupplyWID,
				line.Quantity, amount, sDistEsc))
			if err != nil {
				return err
			}
		}
		return nil
	})
}

func (r *TpccRunner) Payment(ctx context.Context, p PaymentParams) error {
	return r.withTx(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, fmt.Sprintf(
			"UPDATE warehouse SET w_ytd = w_ytd + %.2f WHERE w_id=%d", p.Amount, p.WID))
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, fmt.Sprintf(
			"SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse WHERE w_id=%d", p.WID))
		if err != nil {
			return err
		}
		discard(rows)

		_, err = tx.Exec(ctx, fmt.Sprintf(
			"UPDATE district SET d_ytd = d_ytd + %.2f WHERE d_w_id=%d AND d_id=%d",
			p.Amount, p.WID, p.DID))
		if err != nil {
			return err
		}
		rows, err = tx.Query(ctx, fmt.Sprintf(
			"SELECT d_name, d_street, d_city, d_state, d_zip FROM district "+
				"WHERE d_w_id=%d AND d_id=%d", p.WID, p.DID))
		if err != nil {
			return err
		}
		discard(rows)

		rows, err = tx.Query(ctx, fmt.Sprintf(
			"SELECT c_first, c_middle, c_last, c_balance, c_credit "+
				"FROM customer WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.WID, p.DID, p.CID))
		if err != nil {
			return err
		}
		discard(rows)

		_, err = tx.Exec(ctx, fmt.Sprintf(
			"UPDATE customer SET c_balance = c_balance - %.2f, "+
				"c_ytd_payment = c_ytd_payment + %.2f, c_payment_cnt = c_payment_cnt + 1 "+
				"WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.Amount, p.Amount, p.WID, p.DID, p.CID))
		if err != nil {
			return err
		}

		_, err = tx.Exec(ctx, fmt.Sprintf(
			"INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) "+
				"VALUES (%d, %d, %d, %d, %d, NOW(), %.2f, 'BENCH')",
			p.CID, p.DID, p.WID, p.DID, p.WID, p.Amount))
		return err
	})
}

func (r *TpccRunner) OrderStatus(ctx context.Context, p OrderStatusParams) error {
	return r.withTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, fmt.Sprintf(
			"SELECT c_first, c_middle, c_last, c_balance FROM customer "+
				"WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.WID, p.DID, p.CID))
		if err != nil {
			return err
		}
		discard(rows)

		var oID int
		row := tx.QueryRow(ctx, fmt.Sprintf(
			"SELECT o_id FROM orders "+
				"WHERE o_w_id=%d AND o_d_id=%d AND o_c_id=%d "+
				"ORDER BY o_id DESC LIMIT 1",
			p.WID, p.DID, p.CID))
		if err := row.Scan(&oID); err != nil {
			if err == pgx.ErrNoRows {
				return nil
			}
			return err
		}

		rows, err = tx.Query(ctx, fmt.Sprintf(
			"SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d "+
				"FROM order_line WHERE ol_w_id=%d AND ol_d_id=%d AND ol_o_id=%d",
			p.WID, p.DID, oID))
		if err != nil {
			return err
		}
		discard(rows)
		return nil
	})
}

func (r *TpccRunner) Delivery(ctx context.Context, p DeliveryParams) error {
	return r.withTx(ctx, func(tx pgx.Tx) error {
		for dID := 1; dID <= 10; dID++ {
			var oID int
			err := tx.QueryRow(ctx, fmt.Sprintf(
				"SELECT no_o_id FROM new_order "+
					"WHERE no_w_id=%d AND no_d_id=%d "+
					"ORDER BY no_o_id ASC LIMIT 1",
				p.WID, dID)).Scan(&oID)
			if err != nil {
				if err == pgx.ErrNoRows {
					continue
				}
				return err
			}

			_, err = tx.Exec(ctx, fmt.Sprintf(
				"DELETE FROM new_order WHERE no_w_id=%d AND no_d_id=%d AND no_o_id=%d",
				p.WID, dID, oID))
			if err != nil {
				return err
			}

			var cID int
			err = tx.QueryRow(ctx, fmt.Sprintf(
				"SELECT o_c_id FROM orders "+
					"WHERE o_w_id=%d AND o_d_id=%d AND o_id=%d",
				p.WID, dID, oID)).Scan(&cID)
			if err != nil {
				return err
			}

			_, err = tx.Exec(ctx, fmt.Sprintf(
				"UPDATE orders SET o_carrier_id=%d "+
					"WHERE o_w_id=%d AND o_d_id=%d AND o_id=%d",
				p.CarrierID, p.WID, dID, oID))
			if err != nil {
				return err
			}

			_, err = tx.Exec(ctx, fmt.Sprintf(
				"UPDATE order_line SET ol_delivery_d=NOW() "+
					"WHERE ol_w_id=%d AND ol_d_id=%d AND ol_o_id=%d",
				p.WID, dID, oID))
			if err != nil {
				return err
			}

			var amount float64
			err = tx.QueryRow(ctx, fmt.Sprintf(
				"SELECT COALESCE(SUM(ol_amount), 0) FROM order_line "+
					"WHERE ol_w_id=%d AND ol_d_id=%d AND ol_o_id=%d",
				p.WID, dID, oID)).Scan(&amount)
			if err != nil {
				return err
			}

			_, err = tx.Exec(ctx, fmt.Sprintf(
				"UPDATE customer SET c_balance = c_balance + %.2f, "+
					"c_delivery_cnt = c_delivery_cnt + 1 "+
					"WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
				amount, p.WID, dID, cID))
			if err != nil {
				return err
			}
		}
		return nil
	})
}

func (r *TpccRunner) StockLevel(ctx context.Context, p StockLevelParams) error {
	return r.withTx(ctx, func(tx pgx.Tx) error {
		var nextOID int
		err := tx.QueryRow(ctx, fmt.Sprintf(
			"SELECT d_next_o_id FROM district WHERE d_w_id=%d AND d_id=%d",
			p.WID, p.DID)).Scan(&nextOID)
		if err != nil {
			return err
		}
		lowOID := nextOID - 20

		var lowStock int
		err = tx.QueryRow(ctx, fmt.Sprintf(
			"SELECT COUNT(DISTINCT s.s_i_id) FROM order_line ol "+
				"JOIN stock s ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id "+
				"WHERE ol.ol_w_id=%d AND ol.ol_d_id=%d "+
				"  AND ol.ol_o_id >= %d AND ol.ol_o_id < %d "+
				"  AND s.s_quantity < %d",
			p.WID, p.DID, lowOID, nextOID, p.Threshold)).Scan(&lowStock)
		return err
	})
}

func escapeSQL(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\'' {
			out = append(out, '\'', '\'')
		} else {
			out = append(out, s[i])
		}
	}
	return string(out)
}
