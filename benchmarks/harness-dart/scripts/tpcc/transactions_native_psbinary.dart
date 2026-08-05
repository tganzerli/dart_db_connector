/// TPC-C transactions for `dart_db_connector` — **PS binary variant** (L).
///
/// Companion to `transactions_native.dart`. Same TPC-C transactions
/// (NewOrder / Payment / OrderStatus / Delivery / StockLevel), same
/// pipeline-mode batched writes, but **reads now use the Postgres
/// Extended Query Protocol** via `pool_submit_query_params` (ABI MINOR 1,
/// 2026-05-23 —.
///
/// Trade-off vs `NativeTpccDriver` (the F2 baseline):
///   * **No `setup()` PREPARE step** — relies on libpq's automatic
///     parse/plan caching for Extended Protocol queries. Removes the
///     per-conn warm-up cost and the L.v1 PREPARE machinery.
///   * **Reads use text result format** (`binaryResult: false`). TPC-C
///     reads return many `numeric` columns (`c_discount`, `w_tax`,
///     `i_price`, …) whose binary wire format is not yet decoded
///     (see `decodeByOidBinary` docstring); text-mode decoder
///     handles them as `double` losslessly for bench amounts.
///   * **Writes remain in pipeline mode**, no params, no binary —
///     identical to the F2 baseline write path. Isolates the
///     measured variable to the read side (Extended Protocol with
///     bound params vs `EXECUTE prep_name(…)` text interpolation).
///
/// The variable measured: **cost of Extended-Protocol parameter
/// binding** for TPC-C reads, attributable to dispatch overhead
/// (PQsendQueryParams vs PQexec `EXECUTE`), client-side marshalling,
/// and server-side plan-cache reuse.
// ignore_for_file: invalid_use_of_internal_member
library;

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';

import 'conn_info.dart';
import 'tpcc_driver.dart';

class NativePsBinaryTpccDriver implements TpccDriver {
  final int poolSize;
  final PoolDiagnosticsSink? diagnosticsSink;
  late final PostgresConnectionPool _pool;

  NativePsBinaryTpccDriver({
    this.poolSize = 4,
    this.diagnosticsSink,
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
    // No PREPARE step — Extended Protocol gets plan-cache reuse
    // automatically for repeated SQL strings on the same conn.
  }

  @override
  Future<void> close() => _pool.close();

  Future<T> _tx<T>(Future<T> Function(QueryExecutor exec) body) {
    if (diagnosticsSink != null) {
      return withTransactionInstrumented(_pool, body, diagnosticsSink!);
    }
    return withTransaction(_pool, body);
  }

  // ── SQL templates (mirror of tpcc_prepared_statements.dart shape;
  //    here used directly with PQsendQueryParams rather than via PREPARE). ──

  static const _sqlSelCustomerNo =
      'SELECT c_discount, c_last, c_credit FROM customer '
      'WHERE c_w_id=\$1 AND c_d_id=\$2 AND c_id=\$3';

  static const _sqlSelWarehouseTax =
      'SELECT w_tax FROM warehouse WHERE w_id=\$1';

  static const _sqlSelDistrictForNo =
      'SELECT d_next_o_id, d_tax FROM district '
      'WHERE d_w_id=\$1 AND d_id=\$2 FOR UPDATE';

  static const _sqlSelItem =
      'SELECT i_price, i_name, i_data FROM item WHERE i_id=\$1';

  static const _sqlSelStockForNo =
      'SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt '
      'FROM stock WHERE s_w_id=\$1 AND s_i_id=\$2 FOR UPDATE';

  static const _sqlSelWarehouseAddr =
      'SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse '
      'WHERE w_id=\$1';

  static const _sqlSelDistrictAddr =
      'SELECT d_name, d_street, d_city, d_state, d_zip FROM district '
      'WHERE d_w_id=\$1 AND d_id=\$2';

  static const _sqlSelCustomerPayment =
      'SELECT c_first, c_middle, c_last, c_balance, c_credit FROM customer '
      'WHERE c_w_id=\$1 AND c_d_id=\$2 AND c_id=\$3';

  static const _sqlSelCustomerStatus =
      'SELECT c_first, c_middle, c_last, c_balance FROM customer '
      'WHERE c_w_id=\$1 AND c_d_id=\$2 AND c_id=\$3';

  static const _sqlSelLatestOrder =
      'SELECT o_id, o_entry_d, o_carrier_id FROM orders '
      'WHERE o_w_id=\$1 AND o_d_id=\$2 AND o_c_id=\$3 '
      'ORDER BY o_id DESC LIMIT 1';

  static const _sqlSelOrderLines =
      'SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d '
      'FROM order_line '
      'WHERE ol_w_id=\$1 AND ol_d_id=\$2 AND ol_o_id=\$3';

  static const _sqlSelNewOrderOldest =
      'SELECT no_o_id FROM new_order '
      'WHERE no_w_id=\$1 AND no_d_id=\$2 '
      'ORDER BY no_o_id ASC LIMIT 1';

  static const _sqlSelOrdersCid =
      'SELECT o_c_id FROM orders '
      'WHERE o_w_id=\$1 AND o_d_id=\$2 AND o_id=\$3';

  static const _sqlSelOlAmountSum =
      'SELECT COALESCE(SUM(ol_amount), 0) AS total FROM order_line '
      'WHERE ol_w_id=\$1 AND ol_d_id=\$2 AND ol_o_id=\$3';

  static const _sqlSelDistrictNextOId =
      'SELECT d_next_o_id FROM district '
      'WHERE d_w_id=\$1 AND d_id=\$2';

  static const _sqlSelStockLowCount =
      'SELECT COUNT(DISTINCT s.s_i_id)::int4 AS low_stock '
      'FROM order_line ol JOIN stock s '
      'ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id '
      'WHERE ol.ol_w_id=\$1 AND ol.ol_d_id=\$2 '
      'AND ol.ol_o_id BETWEEN \$3 AND \$4 '
      'AND s.s_quantity < \$5';

  @override
  Future<void> newOrder(NewOrderParams p) async {
    await _tx((exec) async {
      // ─── PHASE 1: READS (Extended Protocol with bound params) ───
      final cRs = await exec.execute(
        _sqlSelCustomerNo,
        params: [Param.int4(p.wId), Param.int4(p.dId), Param.int4(p.cId)],
      );
      cRs.row(0).getDouble('c_discount');
      cRs.row(0).getString('c_last');
      cRs.release();

      final wRs = await exec.execute(
        _sqlSelWarehouseTax,
        params: [Param.int4(p.wId)],
      );
      wRs.row(0).getDouble('w_tax');
      wRs.release();

      final dRs = await exec.execute(
        _sqlSelDistrictForNo,
        params: [Param.int4(p.wId), Param.int4(p.dId)],
      );
      final oId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();

      final lineData = <_LineCache>[];
      for (final line in p.lines) {
        final iRs = await exec.execute(
          _sqlSelItem,
          params: [Param.int4(line.iId)],
        );
        final price = iRs.row(0).getDouble('i_price')!;
        iRs.release();

        final sRs = await exec.execute(
          _sqlSelStockForNo,
          params: [Param.int4(line.supplyWId), Param.int4(line.iId)],
        );
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

      // ─── PHASE 2: WRITES (pipelined, no params — same as F2 baseline) ───
      final allLocal = p.lines.every((l) => l.supplyWId == p.wId) ? 1 : 0;
      final writes = <String>[
        'UPDATE district SET d_next_o_id = d_next_o_id + 1 '
            'WHERE d_w_id=${p.wId} AND d_id=${p.dId}',
        'INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) '
            'VALUES (${p.wId}, ${p.dId}, $oId, ${p.cId}, NOW(), NULL, ${p.lines.length}, $allLocal)',
        'INSERT INTO new_order (no_w_id, no_d_id, no_o_id) '
            'VALUES (${p.wId}, ${p.dId}, $oId)',
      ];

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

      await (exec as PostgresQueryExecutor).executePipeline(writes);
    });
  }

  @override
  Future<void> payment(PaymentParams p) async {
    await _tx((exec) async {
      final amountStr = p.amount.toStringAsFixed(2);

      final wRs = await exec.execute(
        _sqlSelWarehouseAddr,
        params: [Param.int4(p.wId)],
      );
      wRs.row(0).getString('w_name');
      wRs.release();

      final dRs = await exec.execute(
        _sqlSelDistrictAddr,
        params: [Param.int4(p.wId), Param.int4(p.dId)],
      );
      dRs.row(0).getString('d_name');
      dRs.release();

      final cRs = await exec.execute(
        _sqlSelCustomerPayment,
        params: [Param.int4(p.wId), Param.int4(p.dId), Param.int4(p.cId)],
      );
      cRs.row(0).getString('c_last');
      cRs.release();

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
      final cRs = await exec.execute(
        _sqlSelCustomerStatus,
        params: [Param.int4(p.wId), Param.int4(p.dId), Param.int4(p.cId)],
      );
      cRs.row(0).getString('c_last');
      cRs.release();

      final oRs = await exec.execute(
        _sqlSelLatestOrder,
        params: [Param.int4(p.wId), Param.int4(p.dId), Param.int4(p.cId)],
      );
      if (oRs.rowCount == 0) {
        oRs.release();
        return;
      }
      final oId = oRs.row(0).getInt('o_id')!;
      oRs.release();

      final olRs = await exec.execute(
        _sqlSelOrderLines,
        params: [Param.int4(p.wId), Param.int4(p.dId), Param.int4(oId)],
      );
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
      for (var dId = 1; dId <= 10; dId++) {
        final noRs = await exec.execute(
          _sqlSelNewOrderOldest,
          params: [Param.int4(p.wId), Param.int4(dId)],
        );
        if (noRs.rowCount == 0) {
          noRs.release();
          continue;
        }
        final oId = noRs.row(0).getInt('no_o_id')!;
        noRs.release();

        final oRs = await exec.execute(
          _sqlSelOrdersCid,
          params: [Param.int4(p.wId), Param.int4(dId), Param.int4(oId)],
        );
        final cId = oRs.row(0).getInt('o_c_id')!;
        oRs.release();

        final amtRs = await exec.execute(
          _sqlSelOlAmountSum,
          params: [Param.int4(p.wId), Param.int4(dId), Param.int4(oId)],
        );
        final amount = amtRs.row(0).getDouble('total')!;
        amtRs.release();

        await pExec.executePipeline([
          'DELETE FROM new_order '
              'WHERE no_w_id=${p.wId} AND no_d_id=$dId AND no_o_id=$oId',
          'UPDATE orders SET o_carrier_id=${p.carrierId} '
              'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId',
          'UPDATE order_line SET ol_delivery_d=NOW() '
              'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId',
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
      final dRs = await exec.execute(
        _sqlSelDistrictNextOId,
        params: [Param.int4(p.wId), Param.int4(p.dId)],
      );
      final nextOId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();

      final lowOId = nextOId - 20;
      final cRs = await exec.execute(
        _sqlSelStockLowCount,
        params: [
          Param.int4(p.wId),
          Param.int4(p.dId),
          Param.int4(lowOId),
          Param.int4(nextOId),
          Param.int4(p.threshold),
        ],
      );
      cRs.row(0).getInt('low_stock');
      cRs.release();
    });
  }
}

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
