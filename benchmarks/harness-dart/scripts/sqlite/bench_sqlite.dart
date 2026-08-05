/// SQLite bench: the DEVELOPED driver (thread-per-conn WAL pool,
/// offloads sqlite3_step from the isolate) vs the pub.dev `sqlite3` package
/// (synchronous, in-isolate FFI). Same libsqlite3 underneath — FFI-vs-FFI.
///
/// The honest question: does offloading to native worker threads let the
/// event loop parallelise SQLite work? The developed driver should SCALE
/// with `--conns` (real WAL reader parallelism across threads); the pub
/// package cannot (synchronous calls serialise on the single isolate), but
/// pays no port-hop, so it wins single-op latency at 1×1.
///
/// Usage:
///   dart run benchmarks/scripts/sqlite/bench_sqlite.dart \
///     --driver native-sqlite --workload read --conns 4 --ops 40000 \
///     --records 10000 --reps 3
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:sqlite3/sqlite3.dart' as pkg;

int _argInt(List<String> a, String f, int d) {
  final i = a.indexOf(f);
  return (i >= 0 && i + 1 < a.length) ? int.parse(a[i + 1]) : d;
}

String? _argStr(List<String> a, String f) {
  final i = a.indexOf(f);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : null;
}

Future<void> main(List<String> args) async {
  final conns = _argInt(args, '--conns', 4);
  final opCount = _argInt(args, '--ops', 40000);
  final records = _argInt(args, '--records', 10000);
  final reps = _argInt(args, '--reps', 3);
  final baseSeed = _argInt(args, '--seed', 12345);
  final driver = _argStr(args, '--driver') ?? 'native-sqlite';
  final workload = _argStr(args, '--workload') ?? 'read'; // read | mixed
  final csvPath = _argStr(args, '--csv');
  final topology = _argStr(args, '--topology') ?? '';

  final dir = Directory.systemTemp.createTempSync('ddc_sqlite_bench_');
  final dbPath = '${dir.path}/bench.db';
  final samples = <String>[
    'run_id,driver,tx_type,latency_us,success,worker_id,topology'
  ];

  try {
    if (driver == 'native-sqlite') {
      await _runNative(dbPath, conns, opCount, records, reps, baseSeed,
          workload, driver, topology, samples);
    } else {
      _runPkg(dbPath, conns, opCount, records, reps, baseSeed, workload, driver,
          topology, samples);
    }
  } finally {
    dir.deleteSync(recursive: true);
  }

  if (csvPath != null) {
    File(csvPath).writeAsStringSync('${samples.join('\n')}\n');
    stderr.writeln('[csv] wrote $csvPath (${samples.length - 1} samples)');
  }
}

bool _isRead(String workload, int r) => workload == 'read' || r % 2 == 0;

Future<void> _runNative(
    String path,
    int conns,
    int opCount,
    int records,
    int reps,
    int baseSeed,
    String workload,
    String driver,
    String topology,
    List<String> samples) async {
  final pool = SqliteConnectionPool(
      SqlitePoolConfig(path: path, minSize: conns, maxSize: conns));
  await pool.start();

  // Load — on a single connection (works even with maxSize == 1).
  final loader = await pool.acquire();
  final lex = SqliteQueryExecutor(pool.binding, loader.raw);
  (await lex.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)'))
      .release();
  (await lex.execute('BEGIN')).release();
  for (var i = 0; i < records; i++) {
    (await lex.execute('INSERT INTO kv (id, v) VALUES ($i, $i)')).release();
  }
  (await lex.execute('COMMIT')).release();
  await loader.release();

  // One held connection per worker.
  final workers = <SqliteQueryExecutor>[];
  final held = <SqlitePooledConnection>[];
  for (var k = 0; k < conns; k++) {
    final c = await pool.acquire();
    held.add(c);
    workers.add(SqliteQueryExecutor(pool.binding, c.raw));
  }

  for (var rep = 1; rep <= reps; rep++) {
    final perLoop = (opCount / conns).ceil();
    final wall = Stopwatch()..start();
    final rows = await Future.wait([
      for (var k = 0; k < conns; k++)
        () async {
          var seed = baseSeed + rep * 1000 + k;
          final ex = workers[k];
          final out = <String>[];
          for (var i = 0; i < perLoop; i++) {
            seed = (seed * 1103515245 + 12345) & 0x7fffffff;
            final id = seed % records;
            final read = _isRead(workload, seed);
            final sw = Stopwatch()..start();
            final rs = await ex.execute(read
                ? 'SELECT v FROM kv WHERE id=$id'
                : 'UPDATE kv SET v=v+1 WHERE id=$id');
            rs.release();
            sw.stop();
            out.add('$rep,$driver,${read ? 'read' : 'update'},'
                '${sw.elapsedMicroseconds},1,$k,$topology');
          }
          return out;
        }(),
    ]);
    wall.stop();
    final done = perLoop * conns;
    for (final r in rows) {
      samples.addAll(r);
    }
    stdout.writeln('rep $rep: driver=$driver wl=$workload conns=$conns '
        'ops=$done wall=${wall.elapsedMilliseconds}ms '
        'ops/s=${(done * 1000 / wall.elapsedMilliseconds).toStringAsFixed(0)}');
  }

  for (final c in held) {
    await c.release();
  }
  await pool.close();
}

void _runPkg(
    String path,
    int conns,
    int opCount,
    int records,
    int reps,
    int baseSeed,
    String workload,
    String driver,
    String topology,
    List<String> samples) {
  // Load with one connection.
  final loader = pkg.sqlite3.open(path);
  loader.execute('PRAGMA journal_mode=WAL;');
  loader.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)');
  loader.execute('BEGIN');
  for (var i = 0; i < records; i++) {
    loader.execute('INSERT INTO kv (id, v) VALUES ($i, $i)');
  }
  loader.execute('COMMIT');
  loader.close();

  // One DB handle per "worker" (all run on the single isolate — synchronous
  // calls serialise; this is the point of the comparison).
  final dbs = [
    for (var k = 0; k < conns; k++)
      (pkg.sqlite3.open(path)..execute('PRAGMA busy_timeout=5000;'))
  ];

  for (var rep = 1; rep <= reps; rep++) {
    final perLoop = (opCount / conns).ceil();
    final wall = Stopwatch()..start();
    for (var k = 0; k < conns; k++) {
      var seed = baseSeed + rep * 1000 + k;
      final db = dbs[k];
      for (var i = 0; i < perLoop; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final id = seed % records;
        final read = _isRead(workload, seed);
        final sw = Stopwatch()..start();
        if (read) {
          db.select('SELECT v FROM kv WHERE id=$id');
        } else {
          db.execute('UPDATE kv SET v=v+1 WHERE id=$id');
        }
        sw.stop();
        samples.add('$rep,$driver,${read ? 'read' : 'update'},'
            '${sw.elapsedMicroseconds},1,$k,$topology');
      }
    }
    wall.stop();
    final done = perLoop * conns;
    stdout.writeln('rep $rep: driver=$driver wl=$workload conns=$conns '
        'ops=$done wall=${wall.elapsedMilliseconds}ms '
        'ops/s=${(done * 1000 / wall.elapsedMilliseconds).toStringAsFixed(0)}');
  }

  for (final db in dbs) {
    db.close();
  }
}
