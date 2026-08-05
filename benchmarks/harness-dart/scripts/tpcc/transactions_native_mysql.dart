/// TPC-C transactions for the developed MySQL driver (`dart_db_connector`
/// MySQL surface, ). Counterpart of `transactions_native.dart`.
///
/// The developed MySQL driver is v1: **no prepared statements and no
/// pipeline** (the native ABI is simple-protocol only). So, unlike the
/// PostgreSQL native driver (prepared reads + pipelined writes), this
/// runs **inline SQL reads + sequential writes** — more round-trips per
/// transaction. This protocol asymmetry is documented in the bench page:
/// the comparison against `mysql_client` (pub.dev, prepared statements)
/// is deliberately reported alongside this handicap.
///
/// Uses string-interpolated SQL (benchmark code; no parameter binding in
/// v1). Values are internal/synthetic, matching the PostgreSQL bench.
library;

import 'package:dart_db_connector/dart_db_connector.dart';

import 'mysql_conn_info.dart';
import 'tpcc_driver.dart';

class NativeMysqlTpccDriver implements TpccDriver {
  final int poolSize;
  late final MysqlConnectionPool _pool;

  NativeMysqlTpccDriver({this.poolSize = 4});

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
      // ─── PHASE 1: READS (inline; sequential) ───
      final cRs = await exec.execute(
          'SELECT c_discount, c_last FROM customer '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      cRs.row(0).getDouble('c_discount');
      cRs.release();

      final wRs = await exec
          .execute('SELECT w_tax FROM warehouse WHERE w_id=${p.wId}');
      wRs.row(0).getDouble('w_tax');
      wRs.release();

      final dRs = await exec.execute(
          'SELECT d_next_o_id FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId} FOR UPDATE');
      final oId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();

      final lineData = <_LineCache>[];
      for (final line in p.lines) {
        final iRs = await exec
            .execute('SELECT i_price FROM item WHERE i_id=${line.iId}');
        final price = iRs.row(0).getDouble('i_price')!;
        iRs.release();

        final sRs = await exec.execute(
            'SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt '
            'FROM stock WHERE s_w_id=${line.supplyWId} AND s_i_id=${line.iId} '
            'FOR UPDATE');
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

      // ─── PHASE 2: WRITES (sequential; no pipeline in v1) ───
      final allLocal = p.lines.every((l) => l.supplyWId == p.wId) ? 1 : 0;

      (await exec.execute(
              'UPDATE district SET d_next_o_id = d_next_o_id + 1 '
              'WHERE d_w_id=${p.wId} AND d_id=${p.dId}'))
          .release();

      (await exec.execute(
              'INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) '
              'VALUES (${p.wId}, ${p.dId}, $oId, ${p.cId}, NOW(), NULL, ${p.lines.length}, $allLocal)'))
          .release();

      (await exec.execute(
              'INSERT INTO new_order (no_w_id, no_d_id, no_o_id) '
              'VALUES (${p.wId}, ${p.dId}, $oId)'))
          .release();

      for (var olNumber = 1; olNumber <= lineData.length; olNumber++) {
        final ld = lineData[olNumber - 1];
        final newQty = ld.sQty - ld.line.quantity >= 10
            ? ld.sQty - ld.line.quantity
            : ld.sQty - ld.line.quantity + 91;
        final remoteInc = ld.line.supplyWId == p.wId ? 0 : 1;
        (await exec.execute(
                'UPDATE stock SET s_quantity=$newQty, '
                's_ytd=${ld.sYtd + ld.line.quantity}, '
                's_order_cnt=${ld.sOrderCnt + 1}, '
                's_remote_cnt=${ld.sRemoteCnt + remoteInc} '
                'WHERE s_w_id=${ld.line.supplyWId} AND s_i_id=${ld.line.iId}'))
            .release();

        final olAmount = (ld.line.quantity * ld.price).toStringAsFixed(2);
        final sDistEsc = ld.sDist.replaceAll("'", "''");
        (await exec.execute(
                'INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) '
                "VALUES (${p.wId}, ${p.dId}, $oId, $olNumber, ${ld.line.iId}, ${ld.line.supplyWId}, NULL, ${ld.line.quantity}, $olAmount, '$sDistEsc')"))
            .release();
      }
    });
  }

  @override
  Future<void> payment(PaymentParams p) async {
    await _tx((exec) async {
      final amountStr = p.amount.toStringAsFixed(2);

      final wRs = await exec
          .execute('SELECT w_name FROM warehouse WHERE w_id=${p.wId}');
      wRs.row(0).getString('w_name');
      wRs.release();

      final dRs = await exec.execute('SELECT d_name FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      dRs.row(0).getString('d_name');
      dRs.release();

      final cRs = await exec.execute('SELECT c_last FROM customer '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      cRs.row(0).getString('c_last');
      cRs.release();

      // Writes (sequential).
      (await exec.execute(
              'UPDATE warehouse SET w_ytd = w_ytd + $amountStr WHERE w_id=${p.wId}'))
          .release();
      (await exec.execute('UPDATE district SET d_ytd = d_ytd + $amountStr '
              'WHERE d_w_id=${p.wId} AND d_id=${p.dId}'))
          .release();
      (await exec.execute('UPDATE customer SET c_balance = c_balance - $amountStr, '
              'c_ytd_payment = c_ytd_payment + $amountStr, '
              'c_payment_cnt = c_payment_cnt + 1 '
              'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}'))
          .release();
      (await exec.execute(
              'INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) '
              "VALUES (${p.cId}, ${p.dId}, ${p.wId}, ${p.dId}, ${p.wId}, NOW(), $amountStr, 'BENCH')"))
          .release();
    });
  }

  @override
  Future<void> orderStatus(OrderStatusParams p) async {
    await _tx((exec) async {
      final cRs = await exec.execute('SELECT c_last FROM customer '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      cRs.row(0).getString('c_last');
      cRs.release();

      final oRs = await exec.execute('SELECT o_id FROM orders '
          'WHERE o_w_id=${p.wId} AND o_d_id=${p.dId} AND o_c_id=${p.cId} '
          'ORDER BY o_id DESC LIMIT 1');
      if (oRs.rowCount == 0) {
        oRs.release();
        return;
      }
      final oId = oRs.row(0).getInt('o_id')!;
      oRs.release();

      final olRs = await exec.execute(
          'SELECT ol_i_id FROM order_line '
          'WHERE ol_w_id=${p.wId} AND ol_d_id=${p.dId} AND ol_o_id=$oId');
      for (final row in olRs.rows) {
        row.getInt('ol_i_id');
      }
      olRs.release();
    });
  }

  @override
  Future<void> delivery(DeliveryParams p) async {
    await _tx((exec) async {
      for (var dId = 1; dId <= 10; dId++) {
        final noRs = await exec.execute('SELECT no_o_id FROM new_order '
            'WHERE no_w_id=${p.wId} AND no_d_id=$dId '
            'ORDER BY no_o_id ASC LIMIT 1');
        if (noRs.rowCount == 0) {
          noRs.release();
          continue;
        }
        final oId = noRs.row(0).getInt('no_o_id')!;
        noRs.release();

        final oRs = await exec.execute('SELECT o_c_id FROM orders '
            'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId');
        final cId = oRs.row(0).getInt('o_c_id')!;
        oRs.release();

        final amtRs = await exec.execute(
            'SELECT SUM(ol_amount) AS total FROM order_line '
            'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId');
        final amount = amtRs.row(0).getDouble('total') ?? 0.0;
        amtRs.release();

        (await exec.execute('DELETE FROM new_order '
                'WHERE no_w_id=${p.wId} AND no_d_id=$dId AND no_o_id=$oId'))
            .release();
        (await exec.execute('UPDATE orders SET o_carrier_id=${p.carrierId} '
                'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId'))
            .release();
        (await exec.execute('UPDATE order_line SET ol_delivery_d=NOW() '
                'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId'))
            .release();
        (await exec.execute(
                'UPDATE customer SET c_balance = c_balance + ${amount.toStringAsFixed(2)}, '
                'c_delivery_cnt = c_delivery_cnt + 1 '
                'WHERE c_w_id=${p.wId} AND c_d_id=$dId AND c_id=$cId'))
            .release();
      }
    });
  }

  @override
  Future<void> stockLevel(StockLevelParams p) async {
    await _tx((exec) async {
      final dRs = await exec.execute('SELECT d_next_o_id FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      final nextOId = dRs.row(0).getInt('d_next_o_id')!;
      dRs.release();

      final lowOId = nextOId - 20;
      final cRs = await exec.execute(
          'SELECT COUNT(DISTINCT s.s_i_id) AS low_stock '
          'FROM order_line ol JOIN stock s '
          'ON s.s_w_id=${p.wId} AND s.s_i_id=ol.ol_i_id '
          'WHERE ol.ol_w_id=${p.wId} AND ol.ol_d_id=${p.dId} '
          'AND ol.ol_o_id >= $lowOId AND ol.ol_o_id < $nextOId '
          'AND s.s_quantity < ${p.threshold}');
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
