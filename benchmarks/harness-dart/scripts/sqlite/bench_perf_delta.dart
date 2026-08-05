/// P5 bench: measures the two levers vs the  baseline and pub
/// `sqlite3`. Part A — sync fast-path (executeSync) vs async (execute) vs pub,
/// point-read. Part B — multi-read (N reads/round-trip) vs N async reads.
///
/// Run: dart run benchmarks/scripts/sqlite/bench_perf_delta.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:sqlite3/sqlite3.dart' as pkg;

const _ops = 20000;
const _records = 2000;

double _p(List<int> v, double q) {
  v.sort();
  return v[((v.length - 1) * q).round()].toDouble();
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('ddc_perf_');
  try {
    // ---- setup a developed pool + a pub db on the same schema ----
    final pool = SqliteConnectionPool(
        SqlitePoolConfig(path: '${dir.path}/dev.db', maxSize: 1));
    await pool.start();
    final c = await pool.acquire();
    final ex = SqliteQueryExecutor(pool.binding, c.raw);
    (await ex.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)'))
        .release();
    final inserts = [
      for (var i = 0; i < _records; i++) 'INSERT INTO kv VALUES ($i, $i)'
    ];
    await ex.executeBatch(inserts); // dogfood the batch primitive for load

    final pdb = pkg.sqlite3.open('${dir.path}/pub.db');
    pdb.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)');
    pdb.execute('BEGIN');
    for (var i = 0; i < _records; i++) {
      pdb.execute('INSERT INTO kv VALUES ($i, $i)');
    }
    pdb.execute('COMMIT');

    // ---- Part A: point-read latency ----
    stdout.writeln('== Part A — point-read (1 conn) ==');
    final asyncR = await _timeAsync(ex);
    final syncR = _timeSync(ex);
    final pubR = _timePub(pdb);
    stdout.writeln('async  execute   : ${asyncR.ops.toStringAsFixed(0)} ops/s  '
        'p50=${asyncR.p50.toStringAsFixed(1)}µs');
    stdout.writeln('sync   executeSync: ${syncR.ops.toStringAsFixed(0)} ops/s  '
        'p50=${syncR.p50.toStringAsFixed(1)}µs');
    stdout.writeln('pub    select     : ${pubR.ops.toStringAsFixed(0)} ops/s  '
        'p50=${pubR.p50.toStringAsFixed(1)}µs');
    stdout.writeln(
        '→ sync/async = ${(syncR.ops / asyncR.ops).toStringAsFixed(2)}× ; '
        'sync/pub = ${(syncR.ops / pubR.ops).toStringAsFixed(2)}');

    // ---- Part B: multi-read amortization ----
    stdout.writeln('\n== Part B — N reads: multi-read vs N async ==');
    stdout.writeln('  N | async ops/s | multiread ops/s | speedup');
    for (final k in [1, 5, 10, 20]) {
      final a = await _timeNAsync(ex, k);
      final m = await _timeMulti(ex, k);
      stdout.writeln('${k.toString().padLeft(3)} | '
          '${a.toStringAsFixed(0).padLeft(11)} | '
          '${m.toStringAsFixed(0).padLeft(15)} | '
          '${(m / a).toStringAsFixed(2)}×');
    }

    await c.release();
    await pool.close();
    pdb.close();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

class _R {
  final double ops, p50;
  _R(this.ops, this.p50);
}

Future<_R> _timeAsync(SqliteQueryExecutor ex) async {
  final lat = <int>[];
  final w = Stopwatch()..start();
  for (var i = 0; i < _ops; i++) {
    final sw = Stopwatch()..start();
    final rs = await ex.execute('SELECT v FROM kv WHERE id=${i % _records}');
    rs.row(0)[0];
    rs.release();
    lat.add(sw.elapsedMicroseconds);
  }
  return _R(_ops * 1000 / w.elapsedMilliseconds, _p(lat, 0.5));
}

_R _timeSync(SqliteQueryExecutor ex) {
  final lat = <int>[];
  final w = Stopwatch()..start();
  for (var i = 0; i < _ops; i++) {
    final sw = Stopwatch()..start();
    final rs = ex.executeSync('SELECT v FROM kv WHERE id=${i % _records}');
    rs.row(0)[0];
    rs.release();
    lat.add(sw.elapsedMicroseconds);
  }
  return _R(_ops * 1000 / w.elapsedMilliseconds, _p(lat, 0.5));
}

_R _timePub(pkg.Database db) {
  final lat = <int>[];
  final w = Stopwatch()..start();
  for (var i = 0; i < _ops; i++) {
    final sw = Stopwatch()..start();
    db.select('SELECT v FROM kv WHERE id=${i % _records}').first[0];
    lat.add(sw.elapsedMicroseconds);
  }
  return _R(_ops * 1000 / w.elapsedMilliseconds, _p(lat, 0.5));
}

Future<double> _timeNAsync(SqliteQueryExecutor ex, int k) async {
  const batches = 2000;
  final w = Stopwatch()..start();
  for (var i = 0; i < batches; i++) {
    for (var j = 0; j < k; j++) {
      (await ex.execute('SELECT v FROM kv WHERE id=${(i + j) % _records}'))
          .release();
    }
  }
  return batches * k * 1000 / w.elapsedMilliseconds;
}

Future<double> _timeMulti(SqliteQueryExecutor ex, int k) async {
  const batches = 2000;
  final w = Stopwatch()..start();
  for (var i = 0; i < batches; i++) {
    final reads = [
      for (var j = 0; j < k; j++)
        'SELECT v FROM kv WHERE id=${(i + j) % _records}'
    ];
    final rs = await ex.executeMultiRead(reads);
    for (final r in rs) {
      r.release();
    }
  }
  return batches * k * 1000 / w.elapsedMilliseconds;
}
