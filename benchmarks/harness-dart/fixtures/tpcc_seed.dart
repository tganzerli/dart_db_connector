/// TPC-C deterministic seed generator.
///
/// Populates the schema defined in `tpcc_schema.sql` with:
///   - 3 warehouses
///   - 30 districts (10 per W)
///   - 9 000 customers (300 per D)
///   - 100 000 items (constant)
///   - 300 000 stock entries (100 000 per W)
///   - NEW_ORDER, ORDER, ORDER_LINE, HISTORY initially empty
///
/// Uses `Random(42)` so the seed is reproducible across runs.
/// Writes go through the native connector via batched INSERTs inside
/// transactions of ~1000 rows. Reset (DROP+CREATE) is done in
/// `tpcc_schema.sql`; this script assumes empty tables.
///
/// Run:
///   docker exec -i postgres-dev psql -U postgres -d teste \
///     < benchmarks/fixtures/tpcc_schema.sql
///   cd dart && dart run ../benchmarks/fixtures/tpcc_seed.dart
library;

import 'dart:io';
import 'dart:math';

import 'package:dart_db_connector/dart_db_connector.dart';

import '../scripts/tpcc/conn_info.dart';

/// Configurable via `TPCC_WAREHOUSES` env (default 3). MUST match the
/// value used by `mix.dart` at workload-generation time. Added by
/// .2.a (2026-05-20) to test the row-contention mitigation.
final int kWarehouses =
    int.tryParse(Platform.environment['TPCC_WAREHOUSES'] ?? '') ?? 3;
const int kDistrictsPerWarehouse = 10;
const int kCustomersPerDistrict = 300;
const int kItems = 100000;

final _rng = Random(42);

String _randomString(int min, int max) {
  final n = min + _rng.nextInt(max - min + 1);
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  return String.fromCharCodes(
      List.generate(n, (_) => alphabet.codeUnitAt(_rng.nextInt(26))));
}

String _randomState() {
  const states = 'ALABARAZSPSCRJMGRSGOPRPEMTMSPB';
  final i = _rng.nextInt(states.length ~/ 2) * 2;
  return states.substring(i, i + 2);
}

String _randomZip() {
  return List.generate(9, (_) => _rng.nextInt(10).toString()).join();
}

double _randomDouble(double min, double max, int decimals) {
  final v = min + _rng.nextDouble() * (max - min);
  return double.parse(v.toStringAsFixed(decimals));
}

Future<void> main() async {
  // FFI resolved internally — bench scripts
  // that don't need raw primitives now use the simplified public API.
  final pool = PostgresConnectionPool(
    PoolConfig(connInfo: connInfo(), minSize: 1, maxSize: 1),
  );
  await pool.start();

  final stopwatch = Stopwatch()..start();

  await _seedItems(pool);
  await _seedWarehousesAndDistricts(pool);
  await _seedStock(pool);
  await _seedCustomers(pool);

  stopwatch.stop();
  print('[seed] done in ${stopwatch.elapsed}');

  // Sanity check
  await withTransaction(pool, (exec) async {
    Future<int> count(String table) async {
      final rs = await exec.execute('SELECT COUNT(*) AS n FROM $table');
      final n = rs.row(0).getInt('n')!;
      rs.release();
      return n;
    }

    final warehouses = await count('warehouse');
    final districts = await count('district');
    final customers = await count('customer');
    final items = await count('item');
    final stock = await count('stock');
    print('[counts] warehouse=$warehouses district=$districts '
        'customer=$customers item=$items stock=$stock');

    final expected = {
      'warehouse': kWarehouses,
      'district': kWarehouses * kDistrictsPerWarehouse,
      'customer': kWarehouses * kDistrictsPerWarehouse * kCustomersPerDistrict,
      'item': kItems,
      'stock': kWarehouses * kItems,
    };
    if (warehouses != expected['warehouse'] ||
        districts != expected['district'] ||
        customers != expected['customer'] ||
        items != expected['item'] ||
        stock != expected['stock']) {
      throw StateError('seed produced unexpected counts: '
          'expected=$expected, got=($warehouses,$districts,$customers,$items,$stock)');
    }
    print('[ok] counts match expected');
  });

  await pool.close();
}

Future<void> _seedItems(PostgresConnectionPool pool) async {
  print('[seed] items (100k)...');
  final stopwatch = Stopwatch()..start();
  const batchSize = 1000;
  for (var batch = 0; batch < kItems; batch += batchSize) {
    final end = (batch + batchSize).clamp(0, kItems);
    final values = <String>[];
    for (var i = batch; i < end; i++) {
      final id = i + 1;
      final imId = 1 + _rng.nextInt(10000);
      final name = _randomString(14, 24);
      final price = _randomDouble(1.0, 100.0, 2);
      final data = _randomString(26, 50);
      values.add("($id, $imId, '$name', $price, '$data')");
    }
    await withTransaction(pool, (exec) async {
      await exec.execute(
          "INSERT INTO item (i_id, i_im_id, i_name, i_price, i_data) VALUES ${values.join(',')}");
    });
  }
  print('[seed] items done in ${stopwatch.elapsed}');
}

Future<void> _seedWarehousesAndDistricts(PostgresConnectionPool pool) async {
  print('[seed] warehouses + districts...');
  await withTransaction(pool, (exec) async {
    for (var w = 1; w <= kWarehouses; w++) {
      final name = _randomString(6, 10);
      final street = _randomString(10, 40);
      final city = _randomString(10, 20);
      final state = _randomState();
      final zip = _randomZip();
      final tax = _randomDouble(0.0, 0.2, 4);
      const ytd = 300000.0;
      await exec.execute(
          "INSERT INTO warehouse (w_id, w_name, w_street, w_city, w_state, w_zip, w_tax, w_ytd) "
          "VALUES ($w, '$name', '$street', '$city', '$state', '$zip', $tax, $ytd)");
      for (var d = 1; d <= kDistrictsPerWarehouse; d++) {
        final dName = _randomString(6, 10);
        final dStreet = _randomString(10, 40);
        final dCity = _randomString(10, 20);
        final dState = _randomState();
        final dZip = _randomZip();
        final dTax = _randomDouble(0.0, 0.2, 4);
        final dYtd = 30000.0;
        final dNextOId = 3001; // spec convention
        await exec.execute(
            "INSERT INTO district (d_w_id, d_id, d_name, d_street, d_city, d_state, d_zip, d_tax, d_ytd, d_next_o_id) "
            "VALUES ($w, $d, '$dName', '$dStreet', '$dCity', '$dState', '$dZip', $dTax, $dYtd, $dNextOId)");
      }
    }
  });
}

Future<void> _seedStock(PostgresConnectionPool pool) async {
  print('[seed] stock (300k)...');
  final stopwatch = Stopwatch()..start();
  const batchSize = 1000;
  for (var w = 1; w <= kWarehouses; w++) {
    for (var batch = 0; batch < kItems; batch += batchSize) {
      final end = (batch + batchSize).clamp(0, kItems);
      final values = <String>[];
      for (var i = batch; i < end; i++) {
        final iId = i + 1;
        final qty = 10 + _rng.nextInt(91);
        final dist = _randomString(24, 24);
        values.add("($w, $iId, $qty, '$dist', 0, 0, 0)");
      }
      await withTransaction(pool, (exec) async {
        await exec.execute(
            "INSERT INTO stock (s_w_id, s_i_id, s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt) "
            "VALUES ${values.join(',')}");
      });
    }
    print('[seed]   w=$w done (${stopwatch.elapsed})');
  }
  print('[seed] stock done in ${stopwatch.elapsed}');
}

Future<void> _seedCustomers(PostgresConnectionPool pool) async {
  print('[seed] customers (9k)...');
  final stopwatch = Stopwatch()..start();
  for (var w = 1; w <= kWarehouses; w++) {
    for (var d = 1; d <= kDistrictsPerWarehouse; d++) {
      final values = <String>[];
      for (var c = 1; c <= kCustomersPerDistrict; c++) {
        final first = _randomString(8, 16);
        final last = _randomString(8, 16);
        final street = _randomString(10, 40);
        final city = _randomString(10, 20);
        final state = _randomState();
        final zip = _randomZip();
        final credit = _rng.nextInt(10) == 0 ? 'BC' : 'GC';
        final discount = _randomDouble(0.0, 0.5, 4);
        values.add(
            "($w, $d, $c, '$first', 'OE', '$last', '$street', '$city', '$state', '$zip', NOW(), '$credit', 50000.00, $discount, -10.00, 10.00, 1, 0)");
      }
      await withTransaction(pool, (exec) async {
        await exec.execute(
            "INSERT INTO customer (c_w_id, c_d_id, c_id, c_first, c_middle, c_last, c_street, c_city, c_state, c_zip, c_since, c_credit, c_credit_lim, c_discount, c_balance, c_ytd_payment, c_payment_cnt, c_delivery_cnt) "
            "VALUES ${values.join(',')}");
      });
    }
  }
  print('[seed] customers done in ${stopwatch.elapsed}');
}
