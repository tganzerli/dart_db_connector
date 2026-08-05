package main

import (
	"context"
	"database/sql"
	"fmt"
)

// TpccRunner ports the 5 transactions to MySQL via database/sql +
// go-sql-driver/mysql. SQL is string-interpolated (no bound params) to
// match the developed driver and the Dart mysql_client baseline
// apples-to-apples (all three run the text protocol, no prepared stmts).
type TpccRunner struct {
	db *sql.DB
}

func NewTpccRunner(db *sql.DB) *TpccRunner { return &TpccRunner{db: db} }

func (r *TpccRunner) withTx(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func discard(rows *sql.Rows, err error) error {
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
	}
	return rows.Err()
}

func (r *TpccRunner) NewOrder(ctx context.Context, p NewOrderParams) error {
	return r.withTx(ctx, func(tx *sql.Tx) error {
		if err := discard(tx.QueryContext(ctx, fmt.Sprintf(
			"SELECT c_discount, c_last FROM customer "+
				"WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.WID, p.DID, p.CID))); err != nil {
			return err
		}
		if err := discard(tx.QueryContext(ctx, fmt.Sprintf(
			"SELECT w_tax FROM warehouse WHERE w_id=%d", p.WID))); err != nil {
			return err
		}

		var oID int
		if err := tx.QueryRowContext(ctx, fmt.Sprintf(
			"SELECT d_next_o_id FROM district "+
				"WHERE d_w_id=%d AND d_id=%d FOR UPDATE",
			p.WID, p.DID)).Scan(&oID); err != nil {
			return err
		}

		type lineCache struct {
			line                        NewOrderLine
			price, sYtd                 float64
			sQty, sOrderCnt, sRemoteCnt int
			sDist                       string
		}
		cache := make([]lineCache, 0, len(p.Lines))
		for _, line := range p.Lines {
			var price float64
			if err := tx.QueryRowContext(ctx, fmt.Sprintf(
				"SELECT i_price FROM item WHERE i_id=%d", line.IID)).Scan(&price); err != nil {
				return err
			}
			var lc lineCache
			lc.line = line
			lc.price = price
			if err := tx.QueryRowContext(ctx, fmt.Sprintf(
				"SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt "+
					"FROM stock WHERE s_w_id=%d AND s_i_id=%d FOR UPDATE",
				line.SupplyWID, line.IID)).Scan(
				&lc.sQty, &lc.sDist, &lc.sYtd, &lc.sOrderCnt, &lc.sRemoteCnt); err != nil {
				return err
			}
			cache = append(cache, lc)
		}

		allLocal := 1
		for _, l := range p.Lines {
			if l.SupplyWID != p.WID {
				allLocal = 0
				break
			}
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(
			"UPDATE district SET d_next_o_id = d_next_o_id + 1 "+
				"WHERE d_w_id=%d AND d_id=%d", p.WID, p.DID)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(
			"INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) "+
				"VALUES (%d, %d, %d, %d, NOW(), NULL, %d, %d)",
			p.WID, p.DID, oID, p.CID, len(p.Lines), allLocal)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(
			"INSERT INTO new_order (no_w_id, no_d_id, no_o_id) VALUES (%d, %d, %d)",
			p.WID, p.DID, oID)); err != nil {
			return err
		}

		for i, lc := range cache {
			olNumber := i + 1
			newQty := lc.sQty - lc.line.Quantity
			if newQty < 10 {
				newQty += 91
			}
			remoteInc := 0
			if lc.line.SupplyWID != p.WID {
				remoteInc = 1
			}
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(
				"UPDATE stock SET s_quantity=%d, s_ytd=%.2f, s_order_cnt=%d, s_remote_cnt=%d "+
					"WHERE s_w_id=%d AND s_i_id=%d",
				newQty, lc.sYtd+float64(lc.line.Quantity),
				lc.sOrderCnt+1, lc.sRemoteCnt+remoteInc,
				lc.line.SupplyWID, lc.line.IID)); err != nil {
				return err
			}
			amount := float64(lc.line.Quantity) * lc.price
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(
				"INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) "+
					"VALUES (%d, %d, %d, %d, %d, %d, NULL, %d, %.2f, '%s')",
				p.WID, p.DID, oID, olNumber, lc.line.IID, lc.line.SupplyWID,
				lc.line.Quantity, amount, escapeSQL(lc.sDist))); err != nil {
				return err
			}
		}
		return nil
	})
}

func (r *TpccRunner) Payment(ctx context.Context, p PaymentParams) error {
	return r.withTx(ctx, func(tx *sql.Tx) error {
		if err := discard(tx.QueryContext(ctx, fmt.Sprintf(
			"SELECT w_name FROM warehouse WHERE w_id=%d", p.WID))); err != nil {
			return err
		}
		if err := discard(tx.QueryContext(ctx, fmt.Sprintf(
			"SELECT d_name FROM district WHERE d_w_id=%d AND d_id=%d", p.WID, p.DID))); err != nil {
			return err
		}
		if err := discard(tx.QueryContext(ctx, fmt.Sprintf(
			"SELECT c_last FROM customer WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.WID, p.DID, p.CID))); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(
			"UPDATE warehouse SET w_ytd = w_ytd + %.2f WHERE w_id=%d", p.Amount, p.WID)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(
			"UPDATE district SET d_ytd = d_ytd + %.2f WHERE d_w_id=%d AND d_id=%d",
			p.Amount, p.WID, p.DID)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(
			"UPDATE customer SET c_balance = c_balance - %.2f, "+
				"c_ytd_payment = c_ytd_payment + %.2f, c_payment_cnt = c_payment_cnt + 1 "+
				"WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.Amount, p.Amount, p.WID, p.DID, p.CID)); err != nil {
			return err
		}
		_, err := tx.ExecContext(ctx, fmt.Sprintf(
			"INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) "+
				"VALUES (%d, %d, %d, %d, %d, NOW(), %.2f, 'BENCH')",
			p.CID, p.DID, p.WID, p.DID, p.WID, p.Amount))
		return err
	})
}

func (r *TpccRunner) OrderStatus(ctx context.Context, p OrderStatusParams) error {
	return r.withTx(ctx, func(tx *sql.Tx) error {
		if err := discard(tx.QueryContext(ctx, fmt.Sprintf(
			"SELECT c_last FROM customer WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
			p.WID, p.DID, p.CID))); err != nil {
			return err
		}
		var oID int
		err := tx.QueryRowContext(ctx, fmt.Sprintf(
			"SELECT o_id FROM orders WHERE o_w_id=%d AND o_d_id=%d AND o_c_id=%d "+
				"ORDER BY o_id DESC LIMIT 1", p.WID, p.DID, p.CID)).Scan(&oID)
		if err == sql.ErrNoRows {
			return nil
		}
		if err != nil {
			return err
		}
		return discard(tx.QueryContext(ctx, fmt.Sprintf(
			"SELECT ol_i_id FROM order_line WHERE ol_w_id=%d AND ol_d_id=%d AND ol_o_id=%d",
			p.WID, p.DID, oID)))
	})
}

func (r *TpccRunner) Delivery(ctx context.Context, p DeliveryParams) error {
	return r.withTx(ctx, func(tx *sql.Tx) error {
		for dID := 1; dID <= 10; dID++ {
			var oID int
			err := tx.QueryRowContext(ctx, fmt.Sprintf(
				"SELECT no_o_id FROM new_order WHERE no_w_id=%d AND no_d_id=%d "+
					"ORDER BY no_o_id ASC LIMIT 1", p.WID, dID)).Scan(&oID)
			if err == sql.ErrNoRows {
				continue
			}
			if err != nil {
				return err
			}
			var cID int
			if err := tx.QueryRowContext(ctx, fmt.Sprintf(
				"SELECT o_c_id FROM orders WHERE o_w_id=%d AND o_d_id=%d AND o_id=%d",
				p.WID, dID, oID)).Scan(&cID); err != nil {
				return err
			}
			var amount float64
			if err := tx.QueryRowContext(ctx, fmt.Sprintf(
				"SELECT COALESCE(SUM(ol_amount), 0) FROM order_line "+
					"WHERE ol_w_id=%d AND ol_d_id=%d AND ol_o_id=%d",
				p.WID, dID, oID)).Scan(&amount); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(
				"DELETE FROM new_order WHERE no_w_id=%d AND no_d_id=%d AND no_o_id=%d",
				p.WID, dID, oID)); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(
				"UPDATE orders SET o_carrier_id=%d WHERE o_w_id=%d AND o_d_id=%d AND o_id=%d",
				p.CarrierID, p.WID, dID, oID)); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(
				"UPDATE order_line SET ol_delivery_d=NOW() "+
					"WHERE ol_w_id=%d AND ol_d_id=%d AND ol_o_id=%d",
				p.WID, dID, oID)); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(
				"UPDATE customer SET c_balance = c_balance + %.2f, "+
					"c_delivery_cnt = c_delivery_cnt + 1 "+
					"WHERE c_w_id=%d AND c_d_id=%d AND c_id=%d",
				amount, p.WID, dID, cID)); err != nil {
				return err
			}
		}
		return nil
	})
}

func (r *TpccRunner) StockLevel(ctx context.Context, p StockLevelParams) error {
	return r.withTx(ctx, func(tx *sql.Tx) error {
		var nextOID int
		if err := tx.QueryRowContext(ctx, fmt.Sprintf(
			"SELECT d_next_o_id FROM district WHERE d_w_id=%d AND d_id=%d",
			p.WID, p.DID)).Scan(&nextOID); err != nil {
			return err
		}
		lowOID := nextOID - 20
		var lowStock int
		return tx.QueryRowContext(ctx, fmt.Sprintf(
			"SELECT COUNT(DISTINCT s.s_i_id) FROM order_line ol "+
				"JOIN stock s ON s.s_w_id=%d AND s.s_i_id=ol.ol_i_id "+
				"WHERE ol.ol_w_id=%d AND ol.ol_d_id=%d "+
				"  AND ol.ol_o_id >= %d AND ol.ol_o_id < %d "+
				"  AND s.s_quantity < %d",
			p.WID, p.WID, p.DID, lowOID, nextOID, p.Threshold)).Scan(&lowStock)
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
