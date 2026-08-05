/// TPC-C transactions implemented against the `postgres` package (v3).
///
/// Mirror of `transactions_native.dart`. Same SQL strings, same number
/// of round-trips, same transaction boundaries. We use the Simple
/// Query protocol (`QueryMode.simple`) to mirror our connector — which
/// uses `PQsendQuery` (simple protocol) — instead of the package's
/// default Extended Protocol (separate parse/bind/execute). Otherwise
/// we'd be comparing different wire-protocol behaviours, not driver
/// architectures.
library;

import 'package:postgres/postgres.dart';

import 'conn_info.dart';
import 'tpcc_driver.dart';

class PostgresPkgTpccDriver implements TpccDriver {
  final int poolSize;
  late final Pool _pool;

  PostgresPkgTpccDriver({this.poolSize = 4});

  @override
  Future<void> setup() async {
    final e = endpoint();
    _pool = Pool.withEndpoints(
      [
        Endpoint(
          host: e.host,
          port: e.port,
          database: e.database,
          username: e.username,
          password: e.password,
        ),
      ],
      settings: PoolSettings(
        maxConnectionCount: poolSize,
        sslMode: SslMode.disable,
        queryMode: QueryMode.simple,
      ),
    );
  }

  @override
  Future<void> close() => _pool.close();

  @override
  Future<void> newOrder(NewOrderParams p) async {
    await _pool.runTx((s) async {
      final cRows = await s.execute(
          'SELECT c_discount, c_last, c_credit FROM customer '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      // Touch the row to ensure decode.
      cRows.first[0];

      final wRows =
          await s.execute('SELECT w_tax FROM warehouse WHERE w_id=${p.wId}');
      wRows.first[0];

      final dRows = await s.execute(
          'SELECT d_next_o_id, d_tax FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId} FOR UPDATE');
      final oId = dRows.first[0] as int;

      await s.execute('UPDATE district SET d_next_o_id = d_next_o_id + 1 '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');

      final allLocal =
          p.lines.every((l) => l.supplyWId == p.wId) ? 1 : 0;
      await s.execute(
          'INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) '
          'VALUES (${p.wId}, ${p.dId}, $oId, ${p.cId}, NOW(), NULL, ${p.lines.length}, $allLocal)');

      await s.execute(
          'INSERT INTO new_order (no_w_id, no_d_id, no_o_id) '
          'VALUES (${p.wId}, ${p.dId}, $oId)');

      for (var olNumber = 1; olNumber <= p.lines.length; olNumber++) {
        final line = p.lines[olNumber - 1];
        final iRows = await s.execute(
            'SELECT i_price, i_name, i_data FROM item WHERE i_id=${line.iId}');
        final price = _asDouble(iRows.first[0]);

        final sRows = await s.execute(
            'SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt '
            'FROM stock WHERE s_w_id=${line.supplyWId} AND s_i_id=${line.iId} FOR UPDATE');
        final sRow = sRows.first;
        final sQty = sRow[0] as int;
        final sDist = sRow[1] as String;
        final sYtd = _asDouble(sRow[2]);
        final sOrderCnt = sRow[3] as int;
        final sRemoteCnt = sRow[4] as int;

        final newQty = sQty - line.quantity >= 10
            ? sQty - line.quantity
            : sQty - line.quantity + 91;
        final remoteInc = line.supplyWId == p.wId ? 0 : 1;
        await s.execute('UPDATE stock SET s_quantity=$newQty, '
            's_ytd=${sYtd + line.quantity}, '
            's_order_cnt=${sOrderCnt + 1}, '
            's_remote_cnt=${sRemoteCnt + remoteInc} '
            'WHERE s_w_id=${line.supplyWId} AND s_i_id=${line.iId}');

        final olAmount = (line.quantity * price).toStringAsFixed(2);
        final sDistEsc = sDist.replaceAll("'", "''");
        await s.execute(
            'INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) '
            "VALUES (${p.wId}, ${p.dId}, $oId, $olNumber, ${line.iId}, ${line.supplyWId}, NULL, ${line.quantity}, $olAmount, '$sDistEsc')");
      }
    });
  }

  @override
  Future<void> payment(PaymentParams p) async {
    await _pool.runTx((s) async {
      final amountStr = p.amount.toStringAsFixed(2);

      await s.execute(
          'UPDATE warehouse SET w_ytd = w_ytd + $amountStr WHERE w_id=${p.wId}');
      final wRows = await s.execute(
          'SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse WHERE w_id=${p.wId}');
      wRows.first[0];

      await s.execute(
          'UPDATE district SET d_ytd = d_ytd + $amountStr '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      final dRows = await s.execute(
          'SELECT d_name, d_street, d_city, d_state, d_zip FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      dRows.first[0];

      final cRows = await s.execute(
          'SELECT c_first, c_middle, c_last, c_balance, c_credit '
          'FROM customer WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      cRows.first[2];

      await s.execute(
          'UPDATE customer SET c_balance = c_balance - $amountStr, '
          'c_ytd_payment = c_ytd_payment + $amountStr, '
          'c_payment_cnt = c_payment_cnt + 1 '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');

      await s.execute(
          'INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) '
          "VALUES (${p.cId}, ${p.dId}, ${p.wId}, ${p.dId}, ${p.wId}, NOW(), $amountStr, 'BENCH')");
    });
  }

  @override
  Future<void> orderStatus(OrderStatusParams p) async {
    await _pool.runTx((s) async {
      final cRows = await s.execute(
          'SELECT c_first, c_middle, c_last, c_balance FROM customer '
          'WHERE c_w_id=${p.wId} AND c_d_id=${p.dId} AND c_id=${p.cId}');
      cRows.first[2];

      final oRows = await s.execute(
          'SELECT o_id, o_entry_d, o_carrier_id FROM orders '
          'WHERE o_w_id=${p.wId} AND o_d_id=${p.dId} AND o_c_id=${p.cId} '
          'ORDER BY o_id DESC LIMIT 1');
      if (oRows.isEmpty) return;
      final oId = oRows.first[0] as int;

      final olRows = await s.execute(
          'SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d '
          'FROM order_line WHERE ol_w_id=${p.wId} AND ol_d_id=${p.dId} AND ol_o_id=$oId');
      for (final row in olRows) {
        row[0];
      }
    });
  }

  @override
  Future<void> delivery(DeliveryParams p) async {
    await _pool.runTx((s) async {
      for (var dId = 1; dId <= 10; dId++) {
        final noRows = await s.execute(
            'SELECT no_o_id FROM new_order '
            'WHERE no_w_id=${p.wId} AND no_d_id=$dId '
            'ORDER BY no_o_id ASC LIMIT 1');
        if (noRows.isEmpty) continue;
        final oId = noRows.first[0] as int;

        await s.execute('DELETE FROM new_order '
            'WHERE no_w_id=${p.wId} AND no_d_id=$dId AND no_o_id=$oId');

        final oRows = await s.execute('SELECT o_c_id FROM orders '
            'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId');
        final cId = oRows.first[0] as int;

        await s.execute(
            'UPDATE orders SET o_carrier_id=${p.carrierId} '
            'WHERE o_w_id=${p.wId} AND o_d_id=$dId AND o_id=$oId');

        await s.execute(
            'UPDATE order_line SET ol_delivery_d=NOW() '
            'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId');

        final amtRows = await s.execute(
            'SELECT COALESCE(SUM(ol_amount), 0) AS total FROM order_line '
            'WHERE ol_w_id=${p.wId} AND ol_d_id=$dId AND ol_o_id=$oId');
        final amount = _asDouble(amtRows.first[0]);

        await s.execute(
            'UPDATE customer SET c_balance = c_balance + ${amount.toStringAsFixed(2)}, '
            'c_delivery_cnt = c_delivery_cnt + 1 '
            'WHERE c_w_id=${p.wId} AND c_d_id=$dId AND c_id=$cId');
      }
    });
  }

  @override
  Future<void> stockLevel(StockLevelParams p) async {
    await _pool.runTx((s) async {
      final dRows = await s.execute(
          'SELECT d_next_o_id FROM district '
          'WHERE d_w_id=${p.wId} AND d_id=${p.dId}');
      final nextOId = dRows.first[0] as int;

      final lowOId = nextOId - 20;
      final cRows = await s.execute(
          'SELECT COUNT(DISTINCT s.s_i_id) AS low_stock FROM order_line ol '
          'JOIN stock s ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id '
          'WHERE ol.ol_w_id=${p.wId} AND ol.ol_d_id=${p.dId} '
          '  AND ol.ol_o_id >= $lowOId AND ol.ol_o_id < $nextOId '
          '  AND s.s_quantity < ${p.threshold}');
      cRows.first[0];
    });
  }

  /// `numeric` columns come back from the package as `String` or `num`
  /// depending on the registry. Coerce to double for math.
  double _asDouble(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.parse(v);
    return double.parse('$v');
  }
}
