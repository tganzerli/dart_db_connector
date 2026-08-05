/// TPC-C transactions for the developed PostgreSQL driver using the
/// multi-read primitive (`executeMultiRead`, ABI MINOR 2) for the read
/// phase and the pipeline (`executePipeline`, ABI MINOR 1) for the
/// write phase.
///
/// This is the Postgres materialisation of the F1b lever already
/// benchmarked for MySQL (`transactions_native_mysql_readmulti.dart`,
/// +27%/+28%). It is IDENTICAL to `transactions_native.dart` (the
/// developed baseline) except that the independent reads of a
/// transaction collapse into a SINGLE multi-statement round-trip that
/// returns N result sets in order, instead of N sequential round-trips.
/// Everything else — prepared statements, pipelined writes — is held
/// constant so the delta isolates the read-batching lever.
///
/// Only newOrder (2N+3 independent reads) and payment (3 independent
/// reads) are batched; orderStatus / delivery / stockLevel keep the
/// baseline's sequential reads because their reads are data-dependent
/// (a later read needs an earlier read's value) and cannot share one
/// round-trip. All SQL is program-synthesized — the injection-safe
/// usage contract for multi-statement.
library;

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';

import 'conn_info.dart';
import 'tpcc_driver.dart';
import 'tpcc_prepared_statements.dart';

class NativeMultiReadTpccDriver implements TpccDriver {
  final int poolSize;
  late final PostgresConnectionPool _pool;

  NativeMultiReadTpccDriver({this.poolSize = 4});

  @override
  Future<void> setup() async {
    _pool = PostgresConnectionPool(
      PoolConfig(
        connInfo: connInfo(),
        minSize: poolSize,
        maxSize: poolSize,
      ),
    );
    await _pool.start();

    // Prepare the TPC-C statements on every conn (persist server-side
    // per conn). Same procedure as the developed baseline so the only
    // moving part vs it is the read transport.
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

  @override
  Future<void> close() => _pool.close();

  Future<T> _tx<T>(Future<T> Function(PostgresQueryExecutor exec) body) =>
      withTransaction(_pool, (exec) => body(exec as PostgresQueryExecutor));

  @override
  Future<void> newOrder(NewOrderParams p) async {
    await _tx((exec) async {
      // ─── PHASE 1: ALL READS in ONE round-trip ───
      // The 3 fixed reads + 2 per line are mutually independent, so
      // they collapse into a single multi-read. Order matters: the
      // result sets come back in the order the statements were sent.
      final reads = <String>[
        'EXECUTE tpcc_sel_customer(${p.wId}, ${p.dId}, ${p.cId})',
        'EXECUTE tpcc_sel_warehouse_tax(${p.wId})',
        'EXECUTE tpcc_sel_district_for_no(${p.wId}, ${p.dId})',
      ];
      for (final line in p.lines) {
        reads.add('EXECUTE tpcc_sel_item(${line.iId})');
        reads.add(
            'EXECUTE tpcc_sel_stock_for_no(${line.supplyWId}, ${line.iId})');
      }
      final rs = await exec.executeMultiRead(reads);

      rs[0].row(0).getDouble('c_discount');
      rs[0].row(0).getString('c_last');
      rs[1].row(0).getDouble('w_tax');
      final oId = rs[2].row(0).getInt('d_next_o_id')!;

      final lineData = <_LineCache>[];
      for (var i = 0; i < p.lines.length; i++) {
        final line = p.lines[i];
        final iRs = rs[3 + 2 * i];
        final sRs = rs[3 + 2 * i + 1];
        final price = iRs.row(0).getDouble('i_price')!;
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
      }
      for (final r in rs) {
        r.release();
      }

      // ─── PHASE 2: WRITES (1 pipelined round-trip) ───
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
        writes.add('UPDATE stock SET s_quantity=$newQty, '
            's_ytd=${ld.sYtd + ld.line.quantity}, '
            's_order_cnt=${ld.sOrderCnt + 1}, '
            's_remote_cnt=${ld.sRemoteCnt + remoteInc} '
            'WHERE s_w_id=${ld.line.supplyWId} AND s_i_id=${ld.line.iId}');
        final olAmount = (ld.line.quantity * ld.price).toStringAsFixed(2);
        final sDistEsc = ld.sDist.replaceAll("'", "''");
        writes.add(
            'INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) '
            "VALUES (${p.wId}, ${p.dId}, $oId, $olNumber, ${ld.line.iId}, ${ld.line.supplyWId}, NULL, ${ld.line.quantity}, $olAmount, '$sDistEsc')");
      }
      await exec.executePipeline(writes);
    });
  }

  @override
  Future<void> payment(PaymentParams p) async {
    await _tx((exec) async {
      final amountStr = p.amount.toStringAsFixed(2);

      // ─── PHASE 1: 3 independent reads in ONE round-trip ───
      final reads = await exec.executeMultiRead([
        'EXECUTE tpcc_sel_warehouse_addr(${p.wId})',
        'EXECUTE tpcc_sel_district_addr(${p.wId}, ${p.dId})',
        'EXECUTE tpcc_sel_customer_payment(${p.wId}, ${p.dId}, ${p.cId})',
      ]);
      reads[0].row(0).getString('w_name');
      reads[1].row(0).getString('d_name');
      reads[2].row(0).getString('c_last');
      for (final r in reads) {
        r.release();
      }

      // ─── PHASE 2: WRITES (1 pipelined round-trip) ───
      await exec.executePipeline([
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
      // Reads are data-dependent (order_lines needs o_id) — kept
      // sequential, matching the developed baseline.
      final cRs = await exec.execute(
          'EXECUTE tpcc_sel_customer_status(${p.wId}, ${p.dId}, ${p.cId})');
      cRs.row(0).getString('c_last');
      cRs.release();

      final oRs = await exec.execute(
          'EXECUTE tpcc_sel_latest_order(${p.wId}, ${p.dId}, ${p.cId})');
      if (oRs.rowCount == 0) {
        oRs.release();
        return;
      }
      final oId = oRs.row(0).getInt('o_id')!;
      oRs.release();

      final olRs = await exec
          .execute('EXECUTE tpcc_sel_order_lines(${p.wId}, ${p.dId}, $oId)');
      for (final row in olRs.rows) {
        row.getInt('ol_i_id');
      }
      olRs.release();
    });
  }

  @override
  Future<void> delivery(DeliveryParams p) async {
    await _tx((exec) async {
      // Per-district reads are data-dependent (o_id gates the others) —
      // kept sequential, matching the developed baseline.
      for (var dId = 1; dId <= 10; dId++) {
        final noRs = await exec
            .execute('EXECUTE tpcc_sel_new_order_oldest(${p.wId}, $dId)');
        if (noRs.rowCount == 0) {
          noRs.release();
          continue;
        }
        final oId = noRs.row(0).getInt('no_o_id')!;
        noRs.release();

        final oRs = await exec
            .execute('EXECUTE tpcc_sel_orders_cid(${p.wId}, $dId, $oId)');
        final cId = oRs.row(0).getInt('o_c_id')!;
        oRs.release();

        final amtRs = await exec
            .execute('EXECUTE tpcc_sel_ol_amount_sum(${p.wId}, $dId, $oId)');
        final amount = amtRs.row(0).getDouble('total')!;
        amtRs.release();

        await exec.executePipeline([
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
      // Second read needs the first read's value — kept sequential.
      final dRs = await exec
          .execute('EXECUTE tpcc_sel_district_next_o_id(${p.wId}, ${p.dId})');
      final nextOId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();

      final lowOId = nextOId - 20;
      final cRs = await exec.execute(
          'EXECUTE tpcc_sel_stock_low_count(${p.wId}, ${p.dId}, $lowOId, $nextOId, ${p.threshold})');
      cRs.row(0).getInt('low_stock');
      cRs.release();
    });
  }
}

/// Cached per-line read result used by [NativeMultiReadTpccDriver.newOrder]
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
