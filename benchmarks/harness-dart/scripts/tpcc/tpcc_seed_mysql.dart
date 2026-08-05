/// Deterministic TPC-C seeder for MySQL.
///
/// Populates the base tables at the canonical subset scale (kWarehouses ×
/// 10 districts, 300 customers/district, 100k items, kWarehouses×100k
/// stock). Assumes the schema already exists (applied by the runner via
/// the `mysql` CLI, mirroring the Postgres seed-and-run pattern). Orders /
/// order_line / new_order start empty — NewOrder transactions create them
/// (the read-only transactions tolerate empty results).
///
/// Uses batched multi-row INSERTs through the developed driver's simple
/// protocol (no prepared statements in v1). Deterministic RNG so runs are
/// reproducible.
library;

import 'dart:io';
import 'dart:math';

import 'package:dart_db_connector/dart_db_connector.dart';

import 'mix.dart' show kWarehouses, kDistrictsPerWarehouse, kCustomersPerDistrict, kItems;

const int _batch = 500;

Future<void> seedMysql(MysqlConnectionPool pool, {int seed = 42}) async {
  final rng = Random(seed);

  await withMysqlTransaction(pool, (exec) async {
    // warehouse
    for (var w = 1; w <= kWarehouses; w++) {
      await exec.execute(
        'INSERT INTO warehouse VALUES '
        "($w, 'W$w', '${_street(rng)}', 'City$w', 'CA', '12345-678', "
        '0.0750, 300000.00)',
      );
    }
    // district
    final dVals = <String>[];
    for (var w = 1; w <= kWarehouses; w++) {
      for (var d = 1; d <= kDistrictsPerWarehouse; d++) {
        dVals.add(
          "($w, $d, 'D$d', '${_street(rng)}', 'City', 'CA', '12345-678', "
          '0.0750, 30000.00, 1)',
        );
      }
    }
    await _insertBatched(exec, 'INSERT INTO district VALUES ', dVals);
  });

  // customer (kWarehouses × 10 × 300)
  await withMysqlTransaction(pool, (exec) async {
    final vals = <String>[];
    for (var w = 1; w <= kWarehouses; w++) {
      for (var d = 1; d <= kDistrictsPerWarehouse; d++) {
        for (var c = 1; c <= kCustomersPerDistrict; c++) {
          final credit = rng.nextInt(10) == 0 ? 'BC' : 'GC';
          vals.add(
            "($w, $d, $c, 'First$c', 'OE', 'Last$c', '${_street(rng)}', "
            "'City', 'CA', '12345-678', NOW(), '$credit', 50000.00, "
            '0.1000, -10.00, 10.00, 1, 0)',
          );
          if (vals.length >= _batch) {
            await _insertBatched(exec, 'INSERT INTO customer VALUES ', vals);
            vals.clear();
          }
        }
      }
    }
    if (vals.isNotEmpty) {
      await _insertBatched(exec, 'INSERT INTO customer VALUES ', vals);
    }
  });

  // item (100k)
  await _seedBig(pool, 'INSERT INTO item VALUES ', kItems, (i) {
    final id = i + 1;
    return "($id, ${1 + rng.nextInt(10000)}, 'Item$id', "
        '${(1 + rng.nextInt(9999)) / 100 + 1}, '
        "'data padding for item $id ok')";
  });

  // stock (kWarehouses × 100k)
  for (var w = 1; w <= kWarehouses; w++) {
    await _seedBig(pool, 'INSERT INTO stock VALUES ', kItems, (i) {
      final id = i + 1;
      return "($w, $id, ${10 + rng.nextInt(91)}, "
          "'${_dist(rng)}', 0, 0, 0)";
    });
  }

  stderr.writeln('[seed] done: $kWarehouses warehouses, '
      '${kWarehouses * kDistrictsPerWarehouse * kCustomersPerDistrict} customers, '
      '$kItems items, ${kWarehouses * kItems} stock rows.');
}

Future<void> _seedBig(MysqlConnectionPool pool, String prefix, int count,
    String Function(int i) row) async {
  var i = 0;
  while (i < count) {
    await withMysqlTransaction(pool, (exec) async {
      final vals = <String>[];
      final end = (i + _batch * 10 < count) ? i + _batch * 10 : count;
      while (i < end) {
        vals.add(row(i));
        i++;
        if (vals.length >= _batch) {
          await _insertBatched(exec, prefix, vals);
          vals.clear();
        }
      }
      if (vals.isNotEmpty) await _insertBatched(exec, prefix, vals);
    });
  }
}

Future<void> _insertBatched(
    MysqlQueryExecutor exec, String prefix, List<String> values) async {
  if (values.isEmpty) return;
  (await exec.execute(prefix + values.join(','))).release();
}

String _street(Random r) => 'Street ${r.nextInt(9999)}';
String _dist(Random r) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  return List.generate(24, (_) => chars[r.nextInt(chars.length)]).join();
}
