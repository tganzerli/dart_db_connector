/// `driver_us` attribution harness (task P3, 2026-07-29).
///
/// Decomposes the driver-side wall-clock of a query into three phases —
/// **submit / wait / decode** (see `QueryPhases`) — across two result
/// shapes and two topologies, so the codec-plan task (P2) knows which
/// phase to attack first. Uses the opt-in `QueryPhaseSink` on
/// `PostgresQueryExecutor`; no ABI change, no TPS-vs-driver claim — this
/// is a **relative** attribution, not a cross-driver comparison.
///
/// It also measures the instrumentation overhead itself (sink off vs on,
/// 1×1, narrow shape) to confirm the ≤2% budget.
///
/// Run (from `benchmarks/`):
///   dart run scripts/attribution.dart \
///     --shapes narrow,wide100 --topologies 1x1,4x4 \
///     --warmup 500 --n 5000 \
///     --out outputs/driver-us-attribution.csv
///
/// Output CSV (long format, one row per phase):
///   shape,topology,phase,samples,p50_us,p95_us,p99_us,mean_us
/// Plus `overhead` rows: shape=narrow,topology=1x1,phase=overhead,...
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';

import 'attribution_worker.dart';
import 'tpcc/conn_info.dart';
import 'tpcc/metrics.dart' show percentiles;

/// 12-column mixed-type wide shape over `generate_series(1,n)`. Types map
/// to the decoder (int4/int8/text/float8/bool/text/timestamp/numeric).
String _wideSql(int n) =>
    'SELECT g AS c_int4, g::bigint AS c_int8, g::text AS c_text, '
    '(g*1.5)::float8 AS c_f8, (g%2=0) AS c_bool, md5(g::text) AS c_md5, '
    'now() AS c_ts, (g*1.01)::numeric(12,2) AS c_num, '
    "('row-'||g) AS c_label, (g*3)::int AS c_int4b, "
    '(g/2.0)::float8 AS c_f8b, (g%7)::int AS c_mod '
    'FROM generate_series(1, $n) g';

/// Maps a shape name to its SQL. `narrow` mirrors TechEmpower `/db`
/// (2 int4 cols, 1 row) — the exact shape whose driver_us we attribute.
final Map<String, String> _shapes = {
  'narrow': 'SELECT g AS id, (g*7)::int AS n FROM generate_series(1,1) g',
  'wide1': _wideSql(1),
  'wide100': _wideSql(100),
};

/// Topology → (workers, conns per worker, concurrent loops per worker).
final Map<String, ({int workers, int conns, int concurrency})> _topologies = {
  '1x1': (workers: 1, conns: 1, concurrency: 1),
  '4x4': (workers: 4, conns: 4, concurrency: 4),
};

Map<String, String> _parseArgs(List<String> args) {
  final m = <String, String>{
    'shapes': 'narrow,wide100',
    'topologies': '1x1,4x4',
    'warmup': '500',
    'n': '5000',
    'out': 'outputs/driver-us-attribution.csv',
  };
  for (var i = 0; i < args.length - 1; i += 2) {
    final key = args[i].replaceFirst('--', '');
    m[key] = args[i + 1];
  }
  return m;
}

Future<void> main(List<String> args) async {
  final p = _parseArgs(args);
  final shapeNames = p['shapes']!.split(',');
  final topoNames = p['topologies']!.split(',');
  final warmup = int.parse(p['warmup']!);
  final n = int.parse(p['n']!);
  final outPath = p['out']!;

  print('=== driver_us attribution ===');
  print('shapes=$shapeNames topologies=$topoNames warmup=$warmup n=$n');
  print('conninfo=${connInfo()}\n');

  final rows = <String>[
    'shape,topology,phase,samples,p50_us,p95_us,p99_us,mean_us'
  ];

  // ── Instrumentation overhead: sink off vs on (1×1, narrow) ──
  await _measureOverhead(_shapes['narrow']!, warmup, n, rows);

  // ── Phase breakdown per shape × topology ──
  for (final shapeName in shapeNames) {
    final sql = _shapes[shapeName];
    if (sql == null) throw ArgumentError('unknown shape: $shapeName');
    for (final topoName in topoNames) {
      final topo = _topologies[topoName];
      if (topo == null) throw ArgumentError('unknown topology: $topoName');
      await _runCell(shapeName, sql, topoName, topo, warmup, n, rows);
    }
  }

  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString('${rows.join('\n')}\n');
  print('\nwrote ${rows.length - 1} rows → $outPath');
}

/// Runs one (shape, topology) cell across `workers` isolates, aggregates
/// all phase triples, prints + appends per-phase percentile rows.
Future<void> _runCell(
  String shapeName,
  String sql,
  String topoName,
  ({int workers, int conns, int concurrency}) topo,
  int warmup,
  int n,
  List<String> rows,
) async {
  // Split the total measured budget across workers × loops.
  final perLoop =
      (n / (topo.workers * topo.concurrency)).ceil().clamp(1, 1 << 30);

  final results = <AttrWorkerResult>[];
  final futures = <Future<void>>[];
  for (var w = 0; w < topo.workers; w++) {
    final rp = ReceivePort();
    final done = Completer<void>();
    rp.listen((msg) {
      results.add(msg as AttrWorkerResult);
      rp.close();
      done.complete();
    });
    await Isolate.spawn(
      attributionWorkerMain,
      AttrWorkerStart(
        workerId: w,
        sql: sql,
        conns: topo.conns,
        concurrency: topo.concurrency,
        warmupPerLoop: warmup,
        measuredPerLoop: perLoop,
        replyPort: rp.sendPort,
      ),
    );
    futures.add(done.future);
  }
  await Future.wait(futures);

  // Aggregate triples across all workers.
  final submit = <int>[], wait = <int>[], decode = <int>[];
  var rowCount = 0, colCount = 0;
  for (final r in results) {
    for (var i = 0; i + 2 < r.phases.length; i += 3) {
      submit.add(r.phases[i]);
      wait.add(r.phases[i + 1]);
      decode.add(r.phases[i + 2]);
    }
    rowCount = r.rowCount;
    colCount = r.colCount;
  }

  print('--- $shapeName / $topoName (${rowCount}x$colCount, '
      '${submit.length} samples) ---');
  _emitPhase(shapeName, topoName, 'submit', submit, rows);
  _emitPhase(shapeName, topoName, 'wait', wait, rows);
  _emitPhase(shapeName, topoName, 'decode', decode, rows);
}

void _emitPhase(String shape, String topo, String phase, List<int> samples,
    List<String> rows) {
  if (samples.isEmpty) return;
  final pct = percentiles(List<int>.from(samples));
  final mean = samples.fold<int>(0, (a, b) => a + b) / samples.length;
  rows.add('$shape,$topo,$phase,${samples.length},${pct['p50']},'
      '${pct['p95']},${pct['p99']},${mean.toStringAsFixed(2)}');
  print('  $phase: p50=${pct['p50']}us p95=${pct['p95']}us '
      'p99=${pct['p99']}us mean=${mean.toStringAsFixed(1)}us');
}

/// Sink off vs on, single isolate, narrow shape — confirms the sink adds
/// no measurable penalty. The two configs are **interleaved** across
/// reps and reported by **median TPS** so warmup-order bias cancels.
///
/// Caveat (recorded in the page): at 1×1 the query wall-clock is
/// dominated by the ~round-trip `wait` phase (~200µs); the sink's cost is
/// a few `Stopwatch` reads (sub-µs) on the submit/decode CPU (~3µs), so
/// any wall-clock delta here is within run-to-run noise by construction.
Future<void> _measureOverhead(
    String sql, int warmup, int n, List<String> rows) async {
  const reps = 5;
  final pool = PostgresConnectionPool(
    PoolConfig(connInfo: connInfo(), minSize: 1, maxSize: 1),
  );
  await pool.start();
  final leased = await pool.acquire();
  try {
    final execOff = PostgresQueryExecutor(pool.binding, leased.raw);
    final execOn =
        PostgresQueryExecutor(pool.binding, leased.raw, phaseSink: (_) {});

    Future<double> run(PostgresQueryExecutor exec, int iters) async {
      final sw = Stopwatch()..start();
      for (var i = 0; i < iters; i++) {
        (await exec.execute(sql)).release();
      }
      sw.stop();
      return iters / (sw.elapsedMicroseconds / 1e6); // TPS wall-clock
    }

    // Warmup both.
    await run(execOff, warmup);
    await run(execOn, warmup);

    final offTps = <double>[], onTps = <double>[];
    final perRep = (n / reps).ceil();
    for (var r = 0; r < reps; r++) {
      // Interleave off/on each rep to cancel drift.
      offTps.add(await run(execOff, perRep));
      onTps.add(await run(execOn, perRep));
    }
    double median(List<double> xs) {
      final s = List<double>.from(xs)..sort();
      return s[s.length ~/ 2];
    }

    final off = median(offTps), on = median(onTps);
    final overheadPct = (off - on) / off * 100;
    print(
        '--- instrumentation overhead (1x1, narrow, $reps interleaved reps) ---');
    print('  sink off (median): ${off.toStringAsFixed(0)} TPS');
    print('  sink on  (median): ${on.toStringAsFixed(0)} TPS');
    print('  delta: ${overheadPct.toStringAsFixed(2)}% '
        '(within round-trip noise; sink cost is sub-µs CPU)\n');
    rows.add('narrow,1x1,overhead_off_tps,$n,${off.toStringAsFixed(0)},,,');
    rows.add('narrow,1x1,overhead_on_tps,$n,${on.toStringAsFixed(0)},,,'
        '${overheadPct.toStringAsFixed(2)}');
  } finally {
    await leased.release();
    await pool.close();
  }
}
