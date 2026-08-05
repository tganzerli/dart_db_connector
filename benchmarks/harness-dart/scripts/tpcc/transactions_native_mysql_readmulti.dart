/// TPC-C transactions for the developed MySQL driver using BOTH primitives:
/// `executeMultiRead` (ABI MINOR 2) for the read phase and `executeBatch`
/// (ABI MINOR 1) for the write phase. Independent reads inside a transaction
/// collapse into a SINGLE multi-statement round-trip that returns N result
/// sets in order — the MySQL analog of the Postgres read pipeline.
///
/// Compare against `transactions_native_mysql_batched.dart` (batched writes,
/// sequential reads) to isolate the read-batching lever (F1b) on MySQL. All
/// SQL is program-synthesized (no external input) — the injection-safe
/// usage contract for multi-statement.
library;

import 'package:dart_db_connector/dart_db_connector.dart';

import 'mysql_conn_info.dart';
import 'tpcc_driver.dart';

class NativeMysqlReadMultiTpccDriver implements TpccDriver {
  final int poolSize;
  late final MysqlConnectionPool _pool;

  NativeMysqlReadMultiTpccDriver({this.poolSize = 4});

  @override
  Future<void> setup() async {
    final c = mysqlConn();
    _pool = MysqlConnectionPool(MysqlPoolConfig(
      host: c.host,
      port: c.port,
      user: c.user,
      password: c.password,
      database: c.database,
      minSize: poolSize,
      maxSize: poolSize,
    ));
    await _pool.start();
  }

  @override
  Future<void> close() => _pool.close();

  Future<T> _tx<T>(Future<T> Function(MysqlQueryExecutor exec) body) =>
      withMysqlTransaction(_pool, body);

  @override
  Future<void> newOrder(NewOrderParams p) async {
    await _tx((exec) async {
      // ─── READS phase A (customer + warehouse + district): 1 round-trip ───
      final headReads = await exec.executeMultiRead([
        'SELECT c_discount, c_last FROM customer '
            'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}',
        'SELECT w_tax FROM warehouse WHERE w_id=${p.wId}',
        'SELECT d_next_o_id FROM district '
            'WHERE d_w_id=${p.wId} AND d_id=${p.dId} FOR UPDATE',
      ]);
      headReads[0].row(0).getDouble('c_discount');
      headReads[1].row(0).getDouble('w_tax');
      final oId = headReads[2].row(0).getInt('d_next_o_id')!;
      for (final r in headReads) {
        r.release();
      }

      // ─── READS phase B (item + stock per line): 1 round-trip ───
      final lineReads = <String>[];
      for (final line in p.lines) {
        lineReads.add('SELECT i_price FROM item WHERE i_id=${line.iId}');
        lineReads.add(
            'SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt '
            'FROM stock WHERE s_w_id=${line.supplyWId} AND s_i_id=${line.iId} '
            'FOR UPDATE');
      }
      final lineRs = await exec.executeMultiRead(lineReads);
      final lineData = <_LineCache>[];
      for (var i = 0; i < p.lines.length; i++) {
        final line = p.lines[i];
        final iRs = lineRs[2 * i];
        final sRs = lineRs[2 * i + 1];
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
      for (final r in lineRs) {
        r.release();
      }

      // ─── WRITES (BATCHED: one round-trip) ───
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
      await exec.executeBatch(writes);
    });
  }

  @override
  Future<void> payment(PaymentParams p) async {
    await _tx((exec) async {
      final amountStr = p.amount.toStringAsFixed(2);
      // ─── READS (warehouse + district + customer): 1 round-trip ───
      final reads = await exec.executeMultiRead([
        'SELECT w_name FROM warehouse WHERE w_id=${p.wId}',
        'SELECT d_name FROM district '
            'WHERE d_w_id=${p.wId} AND d_id=${p.dId}',
        'SELECT c_last FROM customer '
            'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}',
      ]);
      for (final r in reads) {
        r.release();
      }

      await exec.executeBatch([
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
      // c_last and the latest order are independent → 1 round-trip.
      final reads = await exec.executeMultiRead([
        'SELECT c_last FROM customer '
            'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}',
        'SELECT o_id FROM orders '
            'WHERE o_w_id=${p.wId} AND o_d_id=${p.dId} AND o_c_id=${p.cId} '
            'ORDER BY o_id DESC LIMIT 1',
      ]);
      reads[0].release();
      final oRs = reads[1];
      if (oRs.rowCount == 0) {
        oRs.release();
        return;
      }
      final oId = oRs.row(0).getInt('o_id')!;
      oRs.release();
      (await exec.execute('SELECT ol_i_id FROM order_line '
              'WHERE ol_w_id=${p.wId} AND ol_d_id=${p.dId} AND ol_o_id=$oId'))
          .release();
    });
  }

  @override
  Future<void> delivery(DeliveryParams p) async {
    await _tx((exec) async {
      // Look up the oldest new_order for all 10 districts in ONE round-trip.
      final noReads = <String>[
        for (var dId = 1; dId <= 10; dId++)
          'SELECT no_o_id FROM new_order '
              'WHERE no_w_id=${p.wId} AND no_d_id=$dId '
              'ORDER BY no_o_id ASC LIMIT 1',
      ];
      final noRs = await exec.executeMultiRead(noReads);
      final pending = <int, int>{}; // dId -> oId
      for (var dId = 1; dId <= 10; dId++) {
        final rs = noRs[dId - 1];
        if (rs.rowCount > 0) pending[dId] = rs.row(0).getInt('no_o_id')!;
        rs.release();
      }

      for (final entry in pending.entries) {
        final dId = entry.key;
        final oId = entry.value;
        // o_c_id and the order-line total are independent → 1 round-trip.
        final reads = await exec.executeMultiRead([
          'SELECT o_c_id FROM orders '
              'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId',
          'SELECT SUM(ol_amount) AS total FROM order_line '
              'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId',
        ]);
        final cId = reads[0].row(0).getInt('o_c_id')!;
        final amount = reads[1].row(0).getDouble('total') ?? 0.0;
        for (final r in reads) {
          r.release();
        }
        await exec.executeBatch([
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
      // Second read depends on d_next_o_id → stays sequential.
      final dRs = await exec.execute('SELECT d_next_o_id FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      final nextOId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();
      final lowOId = nextOId - 20;
      (await exec.execute(
              'SELECT COUNT(DISTINCT s.s_i_id) AS low_stock '
              'FROM order_line ol JOIN stock s '
              'ON s.s_w_id=${p.wId} AND s.s_i_id=ol.ol_i_id '
              'WHERE ol.ol_w_id=${p.wId} AND ol.ol_d_id=${p.dId} '
              'AND ol.ol_o_id >= $lowOId AND ol.ol_o_id < $nextOId '
              'AND s.s_quantity < ${p.threshold}'))
          .release();
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
