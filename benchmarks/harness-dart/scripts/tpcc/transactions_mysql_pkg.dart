/// TPC-C transactions for the pub.dev `mysql_client` package — the
/// intra-Dart baseline for the developed MySQL driver.
///
/// Uses `conn.execute(sql)` with **inline SQL and no bound params**, which
/// makes `mysql_client` use the MySQL text protocol (COM_QUERY) — the same
/// protocol tier as the developed driver's simple-query path. This keeps
/// the comparison apples-to-apples on the wire and isolates the driver
/// architecture (the thesis) rather than protocol differences. (Note:
/// `mysql_client` is pure-Dart; the developed driver is FFI + native
/// thread-per-conn pool.)
library;

import 'package:mysql_client/mysql_client.dart';

import 'mysql_conn_info.dart';
import 'tpcc_driver.dart';

class MysqlPkgTpccDriver implements TpccDriver {
  final int poolSize;
  late final MySQLConnectionPool _pool;

  MysqlPkgTpccDriver({this.poolSize = 4});

  @override
  Future<void> setup() async {
    final c = mysqlConn();
    _pool = MySQLConnectionPool(
      host: c.host,
      port: c.port,
      userName: c.user,
      password: c.password,
      databaseName: c.database,
      maxConnections: poolSize,
      secure: false,
    );
  }

  @override
  Future<void> close() => _pool.close();

  Future<void> newOrder(NewOrderParams p) async {
    await _pool.transactional((conn) async {
      final cRs = await conn.execute(
          'SELECT c_discount, c_last FROM customer '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      cRs.rows.first.colByName('c_discount');

      final wRs = await conn
          .execute('SELECT w_tax FROM warehouse WHERE w_id=${p.wId}');
      wRs.rows.first.colByName('w_tax');

      final dRs = await conn.execute('SELECT d_next_o_id FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId} FOR UPDATE');
      final oId = int.parse(dRs.rows.first.colByName('d_next_o_id')!);

      final lineData = <_LineCache>[];
      for (final line in p.lines) {
        final iRs = await conn
            .execute('SELECT i_price FROM item WHERE i_id=${line.iId}');
        final price = double.parse(iRs.rows.first.colByName('i_price')!);

        final sRs = await conn.execute(
            'SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt '
            'FROM stock WHERE s_w_id=${line.supplyWId} AND s_i_id=${line.iId} '
            'FOR UPDATE');
        final sRow = sRs.rows.first;
        lineData.add(_LineCache(
          line: line,
          price: price,
          sQty: int.parse(sRow.colByName('s_quantity')!),
          sDist: sRow.colByName('s_dist_info')!,
          sYtd: double.parse(sRow.colByName('s_ytd')!),
          sOrderCnt: int.parse(sRow.colByName('s_order_cnt')!),
          sRemoteCnt: int.parse(sRow.colByName('s_remote_cnt')!),
        ));
      }

      final allLocal = p.lines.every((l) => l.supplyWId == p.wId) ? 1 : 0;
      await conn.execute('UPDATE district SET d_next_o_id = d_next_o_id + 1 '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      await conn.execute(
          'INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) '
          'VALUES (${p.wId}, ${p.dId}, $oId, ${p.cId}, NOW(), NULL, ${p.lines.length}, $allLocal)');
      await conn.execute('INSERT INTO new_order (no_w_id, no_d_id, no_o_id) '
          'VALUES (${p.wId}, ${p.dId}, $oId)');

      for (var olNumber = 1; olNumber <= lineData.length; olNumber++) {
        final ld = lineData[olNumber - 1];
        final newQty = ld.sQty - ld.line.quantity >= 10
            ? ld.sQty - ld.line.quantity
            : ld.sQty - ld.line.quantity + 91;
        final remoteInc = ld.line.supplyWId == p.wId ? 0 : 1;
        await conn.execute('UPDATE stock SET s_quantity=$newQty, '
            's_ytd=${ld.sYtd + ld.line.quantity}, '
            's_order_cnt=${ld.sOrderCnt + 1}, '
            's_remote_cnt=${ld.sRemoteCnt + remoteInc} '
            'WHERE s_w_id=${ld.line.supplyWId} AND s_i_id=${ld.line.iId}');

        final olAmount = (ld.line.quantity * ld.price).toStringAsFixed(2);
        final sDistEsc = ld.sDist.replaceAll("'", "''");
        await conn.execute(
            'INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) '
            "VALUES (${p.wId}, ${p.dId}, $oId, $olNumber, ${ld.line.iId}, ${ld.line.supplyWId}, NULL, ${ld.line.quantity}, $olAmount, '$sDistEsc')");
      }
    });
  }

  @override
  Future<void> payment(PaymentParams p) async {
    await _pool.transactional((conn) async {
      final amountStr = p.amount.toStringAsFixed(2);
      (await conn.execute('SELECT w_name FROM warehouse WHERE w_id=${p.wId}'))
          .rows
          .first
          .colByName('w_name');
      (await conn.execute('SELECT d_name FROM district '
              'WHERE d_w_id=${p.wId} AND d_id=${p.dId}'))
          .rows
          .first
          .colByName('d_name');
      (await conn.execute('SELECT c_last FROM customer '
              'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}'))
          .rows
          .first
          .colByName('c_last');

      await conn.execute(
          'UPDATE warehouse SET w_ytd = w_ytd + $amountStr WHERE w_id=${p.wId}');
      await conn.execute('UPDATE district SET d_ytd = d_ytd + $amountStr '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      await conn.execute('UPDATE customer SET c_balance = c_balance - $amountStr, '
          'c_ytd_payment = c_ytd_payment + $amountStr, '
          'c_payment_cnt = c_payment_cnt + 1 '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      await conn.execute(
          'INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) '
          "VALUES (${p.cId}, ${p.dId}, ${p.wId}, ${p.dId}, ${p.wId}, NOW(), $amountStr, 'BENCH')");
    });
  }

  @override
  Future<void> orderStatus(OrderStatusParams p) async {
    await _pool.transactional((conn) async {
      (await conn.execute('SELECT c_last FROM customer '
              'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}'))
          .rows
          .first
          .colByName('c_last');

      final oRs = await conn.execute('SELECT o_id FROM orders '
          'WHERE o_w_id=${p.wId} AND o_d_id=${p.dId} AND o_c_id=${p.cId} '
          'ORDER BY o_id DESC LIMIT 1');
      if (oRs.rows.isEmpty) return;
      final oId = int.parse(oRs.rows.first.colByName('o_id')!);

      final olRs = await conn.execute('SELECT ol_i_id FROM order_line '
          'WHERE ol_w_id=${p.wId} AND ol_d_id=${p.dId} AND ol_o_id=$oId');
      for (final row in olRs.rows) {
        row.colByName('ol_i_id');
      }
    });
  }

  @override
  Future<void> delivery(DeliveryParams p) async {
    await _pool.transactional((conn) async {
      for (var dId = 1; dId <= 10; dId++) {
        final noRs = await conn.execute('SELECT no_o_id FROM new_order '
            'WHERE no_w_id=${p.wId} AND no_d_id=$dId '
            'ORDER BY no_o_id ASC LIMIT 1');
        if (noRs.rows.isEmpty) continue;
        final oId = int.parse(noRs.rows.first.colByName('no_o_id')!);

        final oRs = await conn.execute('SELECT o_c_id FROM orders '
            'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId');
        final cId = int.parse(oRs.rows.first.colByName('o_c_id')!);

        final amtRs = await conn.execute(
            'SELECT SUM(ol_amount) AS total FROM order_line '
            'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId');
        final totalStr = amtRs.rows.first.colByName('total');
        final amount = totalStr == null ? 0.0 : double.parse(totalStr);

        await conn.execute('DELETE FROM new_order '
            'WHERE no_w_id=${p.wId} AND no_d_id=$dId AND no_o_id=$oId');
        await conn.execute('UPDATE orders SET o_carrier_id=${p.carrierId} '
            'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId');
        await conn.execute('UPDATE order_line SET ol_delivery_d=NOW() '
            'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId');
        await conn.execute(
            'UPDATE customer SET c_balance = c_balance + ${amount.toStringAsFixed(2)}, '
            'c_delivery_cnt = c_delivery_cnt + 1 '
            'WHERE c_w_id=${p.wId} AND c_d_id=$dId AND c_id=$cId');
      }
    });
  }

  @override
  Future<void> stockLevel(StockLevelParams p) async {
    await _pool.transactional((conn) async {
      final dRs = await conn.execute('SELECT d_next_o_id FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      final nextOId = int.parse(dRs.rows.first.colByName('d_next_o_id')!);
      final lowOId = nextOId - 20;
      (await conn.execute('SELECT COUNT(DISTINCT s.s_i_id) AS low_stock '
              'FROM order_line ol JOIN stock s '
              'ON s.s_w_id=${p.wId} AND s.s_i_id=ol.ol_i_id '
              'WHERE ol.ol_w_id=${p.wId} AND ol.ol_d_id=${p.dId} '
              'AND ol.ol_o_id >= $lowOId AND ol.ol_o_id < $nextOId '
              'AND s.s_quantity < ${p.threshold}'))
          .rows
          .first
          .colByName('low_stock');
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
