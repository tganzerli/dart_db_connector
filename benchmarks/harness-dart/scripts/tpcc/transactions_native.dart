/// TPC-C transactions for `dart_db_connector` (the native connector).
///
/// Each public method runs as a single Postgres transaction via
/// `withTransaction`. Uses string-interpolated SQL (no parameter
/// binding yet — this is benchmark code, documented in
/// a design note §"SQL injection").
///
/// **** simplified setup — no explicit
/// `PostgresBinding` / `loadNativeDb`. Public API only.
library;

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';

import 'conn_info.dart';
import 'tpcc_driver.dart';
import 'tpcc_prepared_statements.dart';

class NativeTpccDriver implements TpccDriver {
  final int poolSize;
  final PoolDiagnosticsSink? diagnosticsSink;
  /// L.v1 toggle. When true, every fresh connection runs
  /// `prepareTpccStatements` at open time, and TPC-C reads use
  /// `EXECUTE stmt(...)` instead of inline SQL.
  final bool preparedStatements;
  late final PostgresConnectionPool _pool;

  NativeTpccDriver({
    this.poolSize = 4,
    this.diagnosticsSink,
    this.preparedStatements = true,
  });

  @override
  Future<void> setup() async {
    _pool = PostgresConnectionPool(
      PoolConfig(
        connInfo: connInfo(),
        minSize: poolSize,
        maxSize: poolSize,
        instrumentationEnabled: diagnosticsSink != null,
      ),
    );
    await _pool.start();

    // ABI MAJOR 2 (2026-05-20): `PoolConfig.onConnectionOpen` was
    // removed because the native pool allocates every conn eagerly
    // at `pool_create` time. We re-prepare statements by walking
    // every conn manually — acquire ALL conns at once (so each
    // subsequent acquire returns a different one), prepare, then
    // release in bulk. The PREPAREs persist server-side per conn.
    if (preparedStatements) {
      final leased = <PooledConnection>[];
      for (var i = 0; i < poolSize; i++) {
        leased.add(await _pool.acquire());
      }
      try {
        for (final c in leased) {
          await prepareTpccStatements(_pool, c.raw);
        }
      } finally {
        for (final c in leased) {
          await c.release();
        }
      }
    }
  }

  @override
  Future<void> close() => _pool.close();

  /// Internal helper: switches between instrumented and plain lifecycle.
  Future<T> _tx<T>(Future<T> Function(QueryExecutor exec) body) {
    if (diagnosticsSink != null) {
      return withTransactionInstrumented(_pool, body, diagnosticsSink!);
    }
    return withTransaction(_pool, body);
  }

  @override
  Future<void> newOrder(NewOrderParams p) async {
    await _tx((exec) async {
      // ─── PHASE 1: READS (sequential, need result values) ───
      // 3 fixed reads + 2 reads per line. For N=10 lines = 23 RTTs.

      // 1. Read customer (prepared: tpcc_sel_customer).
      final cRs = await exec.execute(
          'EXECUTE tpcc_sel_customer(${p.wId}, ${p.dId}, ${p.cId})');
      cRs.row(0).getDouble('c_discount');
      cRs.row(0).getString('c_last');
      cRs.release();

      // 2. Read warehouse tax (prepared: tpcc_sel_warehouse_tax).
      final wRs = await exec
          .execute('EXECUTE tpcc_sel_warehouse_tax(${p.wId})');
      wRs.row(0).getDouble('w_tax');
      wRs.release();

      // 3. Read + lock district (prepared: tpcc_sel_district_for_no).
      final dRs = await exec.execute(
          'EXECUTE tpcc_sel_district_for_no(${p.wId}, ${p.dId})');
      final oId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();

      // For each line: 2 reads via prepared stmts (tpcc_sel_item +
      // tpcc_sel_stock_for_no). Cache values for the write phase.
      final lineData = <_LineCache>[];
      for (final line in p.lines) {
        final iRs = await exec
            .execute('EXECUTE tpcc_sel_item(${line.iId})');
        final price = iRs.row(0).getDouble('i_price')!;
        iRs.release();

        final sRs = await exec.execute(
            'EXECUTE tpcc_sel_stock_for_no(${line.supplyWId}, ${line.iId})');
        final sRow = sRs.row(0);
        lineData.add(_LineCache(
          line: line,
          price: price,
          sQty: sRow.getInt('s_quantity')!,
          sDist: sRow.getString('s_dist_info')!,
          sYtd: sRow.getDouble('s_ytd')!,
          sOrderCnt: sRow.getInt('s_order_cnt')!,
          sRemoteCnt: sRow.getInt('s_remote_cnt')!,
        ));
        sRs.release();
      }

      // ─── PHASE 2: WRITES (1 pipelined batch = 1 RTT) ───
      // Reduces RTTs from N*2 + 3 fixed = 4N + 3 to 2N + 4 (reads + 1).

      final allLocal = p.lines.every((l) => l.supplyWId == p.wId) ? 1 : 0;
      final writes = <String>[
        // 4. Bump district next_o_id.
        'UPDATE district SET d_next_o_id = d_next_o_id + 1 '
            'WHERE d_w_id=${p.wId} AND d_id=${p.dId}',

        // 5. Insert orders row.
        'INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) '
            'VALUES (${p.wId}, ${p.dId}, $oId, ${p.cId}, NOW(), NULL, ${p.lines.length}, $allLocal)',

        // 6. Insert new_order row.
        'INSERT INTO new_order (no_w_id, no_d_id, no_o_id) '
            'VALUES (${p.wId}, ${p.dId}, $oId)',
      ];

      // 7. Per-line: update stock + insert order_line.
      for (var olNumber = 1; olNumber <= lineData.length; olNumber++) {
        final ld = lineData[olNumber - 1];
        final newQty = ld.sQty - ld.line.quantity >= 10
            ? ld.sQty - ld.line.quantity
            : ld.sQty - ld.line.quantity + 91;
        final remoteInc = ld.line.supplyWId == p.wId ? 0 : 1;
        writes.add(
          'UPDATE stock SET s_quantity=$newQty, '
              's_ytd=${ld.sYtd + ld.line.quantity}, '
              's_order_cnt=${ld.sOrderCnt + 1}, '
              's_remote_cnt=${ld.sRemoteCnt + remoteInc} '
              'WHERE s_w_id=${ld.line.supplyWId} AND s_i_id=${ld.line.iId}',
        );

        final olAmount = (ld.line.quantity * ld.price).toStringAsFixed(2);
        final sDistEsc = ld.sDist.replaceAll("'", "''");
        writes.add(
          'INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) '
              "VALUES (${p.wId}, ${p.dId}, $oId, $olNumber, ${ld.line.iId}, ${ld.line.supplyWId}, NULL, ${ld.line.quantity}, $olAmount, '$sDistEsc')",
        );
      }

      // Single pipelined RTT for all writes.
      await (exec as PostgresQueryExecutor).executePipeline(writes);
    });
  }

  @override
  Future<void> payment(PaymentParams p) async {
    await _tx((exec) async {
      final amountStr = p.amount.toStringAsFixed(2);

      // ─── PHASE 1: READS (sequential) ───
      // 3 reads for warehouse/district/customer (no read-result needed
      // for the writes; reads are just for spec conformity).

      final wRs = await exec
          .execute('EXECUTE tpcc_sel_warehouse_addr(${p.wId})');
      wRs.row(0).getString('w_name');
      wRs.release();

      final dRs = await exec.execute(
          'EXECUTE tpcc_sel_district_addr(${p.wId}, ${p.dId})');
      dRs.row(0).getString('d_name');
      dRs.release();

      final cRs = await exec.execute(
          'EXECUTE tpcc_sel_customer_payment(${p.wId}, ${p.dId}, ${p.cId})');
      cRs.row(0).getString('c_last');
      cRs.release();

      // ─── PHASE 2: WRITES (1 pipelined batch) ───
      // All 5 writes (warehouse ytd, district ytd, customer balance,
      // history insert) batched into 1 RTT. Old: 8 RTTs total; new: 4.

      await (exec as PostgresQueryExecutor).executePipeline([
        'UPDATE warehouse SET w_ytd = w_ytd + $amountStr WHERE w_id=${p.wId}',
        'UPDATE district SET d_ytd = d_ytd + $amountStr '
            'WHERE d_w_id=${p.wId} AND d_id=${p.dId}',
        'UPDATE customer SET c_balance = c_balance - $amountStr, '
            'c_ytd_payment = c_ytd_payment + $amountStr, '
            'c_payment_cnt = c_payment_cnt + 1 '
            'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}',
        'INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) '
            "VALUES (${p.cId}, ${p.dId}, ${p.wId}, ${p.dId}, ${p.wId}, NOW(), $amountStr, 'BENCH')",
      ]);
    });
  }

  @override
  Future<void> orderStatus(OrderStatusParams p) async {
    await _tx((exec) async {
      // 1. Read customer (prepared).
      final cRs = await exec.execute(
          'EXECUTE tpcc_sel_customer_status(${p.wId}, ${p.dId}, ${p.cId})');
      cRs.row(0).getString('c_last');
      cRs.release();

      // 2. Latest order (prepared).
      final oRs = await exec.execute(
          'EXECUTE tpcc_sel_latest_order(${p.wId}, ${p.dId}, ${p.cId})');
      if (oRs.rowCount == 0) {
        oRs.release();
        return;
      }
      final oId = oRs.row(0).getInt('o_id')!;
      oRs.release();

      // 3. All order_lines for that order (prepared).
      final olRs = await exec.execute(
          'EXECUTE tpcc_sel_order_lines(${p.wId}, ${p.dId}, $oId)');
      for (final row in olRs.rows) {
        row.getInt('ol_i_id');
      }
      olRs.release();
    });
  }

  @override
  Future<void> delivery(DeliveryParams p) async {
    await _tx((exec) async {
      final pExec = exec as PostgresQueryExecutor;
      // For each of the 10 districts, deliver the oldest new_order.
      // Per-district: 3 reads (locate, customer-id, ol-amount sum) +
      // 1 pipelined batch (4 writes). Old: 6 RTTs per district; new: 4.
      for (var dId = 1; dId <= 10; dId++) {
        // ─── PHASE 1: READS for this district ───

        // 1. Oldest new_order (prepared).
        final noRs = await exec.execute(
            'EXECUTE tpcc_sel_new_order_oldest(${p.wId}, $dId)');
        if (noRs.rowCount == 0) {
          noRs.release();
          continue;
        }
        final oId = noRs.row(0).getInt('no_o_id')!;
        noRs.release();

        // 2. Customer id (prepared).
        final oRs = await exec.execute(
            'EXECUTE tpcc_sel_orders_cid(${p.wId}, $dId, $oId)');
        final cId = oRs.row(0).getInt('o_c_id')!;
        oRs.release();

        // 3. ol_amount sum (prepared) BEFORE the UPDATE order_line
        // (delivery date doesn't affect amount; sequential for clarity).
        final amtRs = await exec.execute(
            'EXECUTE tpcc_sel_ol_amount_sum(${p.wId}, $dId, $oId)');
        final amount = amtRs.row(0).getDouble('total')!;
        amtRs.release();

        // ─── PHASE 2: WRITES for this district (1 pipelined RTT) ───
        await pExec.executePipeline([
          // Delete new_order row.
          'DELETE FROM new_order '
              'WHERE no_w_id=${p.wId} AND no_d_id=$dId AND no_o_id=$oId',
          // Update orders carrier.
          'UPDATE orders SET o_carrier_id=${p.carrierId} '
              'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId',
          // Update order_lines delivery date.
          'UPDATE order_line SET ol_delivery_d=NOW() '
              'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId',
          // Update customer balance + delivery_cnt.
          'UPDATE customer SET c_balance = c_balance + ${amount.toStringAsFixed(2)}, '
              'c_delivery_cnt = c_delivery_cnt + 1 '
              'WHERE c_w_id=${p.wId} AND c_d_id=$dId AND c_id=$cId',
        ]);
      }
    });
  }

  @override
  Future<void> stockLevel(StockLevelParams p) async {
    await _tx((exec) async {
      // 1. Get district next_o_id (prepared).
      final dRs = await exec.execute(
          'EXECUTE tpcc_sel_district_next_o_id(${p.wId}, ${p.dId})');
      final nextOId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();

      // 2. Count distinct items with stock below threshold (prepared).
      final lowOId = nextOId - 20;
      final cRs = await exec.execute(
          'EXECUTE tpcc_sel_stock_low_count(${p.wId}, ${p.dId}, $lowOId, $nextOId, ${p.threshold})');
      cRs.row(0).getInt('low_stock');
      cRs.release();
    });
  }
}

/// Cached per-line read result used by [NativeTpccDriver.newOrder]
/// to compose the batched write pipeline.
class _LineCache {
  final NewOrderLineItem line;
  final double price;
  final int sQty;
  final String sDist;
  final double sYtd;
  final int sOrderCnt;
  final int sRemoteCnt;

  _LineCache({
    required this.line,
    required this.price,
    required this.sQty,
    required this.sDist,
    required this.sYtd,
    required this.sOrderCnt,
    required this.sRemoteCnt,
  });
}
