/// Server-side prepared statement templates for the TPC-C reads.
///
/// L.v1 strategy (per
/// `the design notes1-prepared-statements-text.md`):
/// each fresh connection issues `PREPARE` for these 9 templates at
/// open time. In ABI MAJOR 2 (2026-05-20) the
/// `PoolConfig.onConnectionOpen` hook is gone; callers instead
/// iterate every `PooledConnection` after `pool.start()` and invoke
/// [prepareTpccStatements] manually (see
/// `transactions_native.dart#setup`). Subsequent reads at runtime go
/// through `EXECUTE stmt(...)`, letting Postgres reuse the cached
/// plan and skip parse + plan phases (~5× faster per Gemini Deep
/// Research ref 16).
///
/// **NOT covered by L.v1:** writes (kept in pipeline mode v1 — see
/// task M), binary format, [ParamValue] types, ABI changes. Those
/// belong to L.v2 (post-publication).
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:ffi' as ffi;

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';

/// `(stmtName, sql)` pairs for the 9 read templates. Names are stable
/// across processes/connections so callers can [tpccExecute] without
/// extra plumbing.
const tpccPreparedStatements = <(String, String)>[
  // NewOrder reads
  (
    'tpcc_sel_customer',
    'SELECT c_discount, c_last, c_credit FROM customer '
        'WHERE c_w_id=\$1 AND c_d_id=\$2 AND c_id=\$3'
  ),
  ('tpcc_sel_warehouse_tax', 'SELECT w_tax FROM warehouse WHERE w_id=\$1'),
  (
    'tpcc_sel_district_for_no',
    'SELECT d_next_o_id, d_tax FROM district '
        'WHERE d_w_id=\$1 AND d_id=\$2 FOR UPDATE'
  ),
  (
    'tpcc_sel_item',
    'SELECT i_price, i_name, i_data FROM item WHERE i_id=\$1'
  ),
  (
    'tpcc_sel_stock_for_no',
    'SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt '
        'FROM stock WHERE s_w_id=\$1 AND s_i_id=\$2 FOR UPDATE'
  ),
  // Payment reads
  (
    'tpcc_sel_warehouse_addr',
    'SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse WHERE w_id=\$1'
  ),
  (
    'tpcc_sel_district_addr',
    'SELECT d_name, d_street, d_city, d_state, d_zip FROM district '
        'WHERE d_w_id=\$1 AND d_id=\$2'
  ),
  (
    'tpcc_sel_customer_payment',
    'SELECT c_first, c_middle, c_last, c_balance, c_credit FROM customer '
        'WHERE c_w_id=\$1 AND c_d_id=\$2 AND c_id=\$3'
  ),
  // Delivery reads
  (
    'tpcc_sel_new_order_oldest',
    'SELECT no_o_id FROM new_order '
        'WHERE no_w_id=\$1 AND no_d_id=\$2 '
        'ORDER BY no_o_id ASC LIMIT 1'
  ),
  (
    'tpcc_sel_orders_cid',
    'SELECT o_c_id FROM orders '
        'WHERE o_w_id=\$1 AND o_d_id=\$2 AND o_id=\$3'
  ),
  (
    'tpcc_sel_ol_amount_sum',
    'SELECT COALESCE(SUM(ol_amount), 0) AS total FROM order_line '
        'WHERE ol_w_id=\$1 AND ol_d_id=\$2 AND ol_o_id=\$3'
  ),
  // orderStatus reads
  (
    'tpcc_sel_customer_status',
    'SELECT c_first, c_middle, c_last, c_balance FROM customer '
        'WHERE c_w_id=\$1 AND c_d_id=\$2 AND c_id=\$3'
  ),
  (
    'tpcc_sel_latest_order',
    'SELECT o_id, o_entry_d, o_carrier_id FROM orders '
        'WHERE o_w_id=\$1 AND o_d_id=\$2 AND o_c_id=\$3 '
        'ORDER BY o_id DESC LIMIT 1'
  ),
  (
    'tpcc_sel_order_lines',
    'SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d '
        'FROM order_line '
        'WHERE ol_w_id=\$1 AND ol_d_id=\$2 AND ol_o_id=\$3'
  ),
  // stockLevel reads
  (
    'tpcc_sel_district_next_o_id',
    'SELECT d_next_o_id FROM district WHERE d_w_id=\$1 AND d_id=\$2'
  ),
  (
    'tpcc_sel_stock_low_count',
    'SELECT COUNT(DISTINCT s.s_i_id) AS low_stock FROM order_line ol '
        'JOIN stock s ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id '
        'WHERE ol.ol_w_id=\$1 AND ol.ol_d_id=\$2 '
        '  AND ol.ol_o_id >= \$3 AND ol.ol_o_id < \$4 '
        '  AND s.s_quantity < \$5'
  ),
];

/// Issues `PREPARE` for every entry in [tpccPreparedStatements] on the
/// given conn handle. Idempotent if the same connection is passed
/// twice in a single session: Postgres errors with "prepared
/// statement already exists", which we suppress here by `DEALLOCATE`-
/// ing before each prepare.
///
/// In ABI MAJOR 2 the `conn` argument is a `native_conn_t*` (the
/// `PooledConnection.raw` field). Callers invoke this once per conn
/// at startup — see `transactions_native.dart#setup`. Each fresh
/// connection pays this cost exactly once (~9 × fast simple-protocol
/// parse ≈ 0.5ms total).
///
/// takes the [PostgresConnectionPool] instead of
/// `PostgresBinding` directly — the executor pulls the binding from
/// the pool's `@internal` accessor.
Future<void> prepareTpccStatements(
  PostgresConnectionPool pool,
  ffi.Pointer<ffi.Void> conn,
) async {
  final exec = PostgresQueryExecutor(pool.binding, conn);
  for (final (name, sql) in tpccPreparedStatements) {
    // DEALLOCATE first — safe even if no prior PREPARE exists with
    // the same name (Postgres ignores DEALLOCATE for unknown names
    // when wrapped in DO block, but here we just swallow errors).
    try {
      (await exec.execute('DEALLOCATE $name')).release();
    } catch (_) {
      // ignore: stmt did not exist
    }
    (await exec.execute('PREPARE $name AS $sql')).release();
  }
}
