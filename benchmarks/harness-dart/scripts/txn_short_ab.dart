/// Short-transaction A/B micro-benchmark for BEGIN piggyback (P5).
///
/// Measures the per-transaction wall-clock of a **short** Postgres
/// transaction (`BEGIN; <one Simple statement>; COMMIT`) under two arms:
///
///   - `eager`  — the pre-P5 shape: a dedicated `BEGIN` round-trip,
///                then the statement, then `COMMIT` (3 round-trips).
///   - `fused`  — P5: `withTransaction`, which defers the BEGIN and
///                fuses it into the first Simple statement (2 round-trips).
///
/// Both arms run in the SAME process on the SAME warm 1×1 pool, so the
/// only difference is the BEGIN fusion — a clean isolation of the lever
/// (better than an A/B across git checkouts, which would also vary build
/// noise). Arms are interleaved per rep (order flips each rep) to cancel
/// drift, with a discarded warmup, per the P4 benchmarking lesson.
///
/// Run (from `benchmarks/`):
///   export DART_DB_CONNECTOR_NATIVE_LIB_PATH=/abs/path/libnative_db.dylib
///   dart run scripts/txn_short_ab.dart --warmup 500 --n 5000 --reps 5 \
///     --out outputs/begin-piggyback-txn.csv
///
/// Output CSV (one row per arm×rep):
///   arm,rep,n,p50_us,p95_us,p99_us,mean_us,tps
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';

import 'tpcc/conn_info.dart';
import 'tpcc/metrics.dart' show percentiles;

const _body = 'SELECT 1';

/// Pre-P5 shape: eager standalone BEGIN, statement, COMMIT (3 RTTs).
/// Mirrors `withTransactionOn` but forces a dedicated BEGIN dispatch.
Future<void> _eagerTxn(PostgresConnectionPool pool,
    Future<void> Function(QueryExecutor) body) async {
  final leased = await pool.acquire();
  try {
    final e = PostgresQueryExecutor(pool.binding, leased.raw);
    (await e.execute('BEGIN')).release();
    try {
      await body(e);
      (await e.execute('COMMIT')).release();
    } catch (_) {
      (await e.execute('ROLLBACK')).release();
      rethrow;
    }
  } finally {
    await leased.release();
  }
}

/// P5 shape: deferred + fused BEGIN via the public `withTransaction`.
Future<void> _fusedTxn(
    PostgresConnectionPool pool, Future<void> Function(QueryExecutor) body) {
  return withTransaction(pool, (exec) async {
    await body(exec);
  });
}

Future<void> _oneStatement(QueryExecutor e) async {
  (await e.execute(_body)).release();
}

Map<String, String> _parseArgs(List<String> args) {
  final m = <String, String>{
    'warmup': '500',
    'n': '5000',
    'reps': '5',
    'out': 'outputs/begin-piggyback-txn.csv',
  };
  for (var i = 0; i + 1 < args.length; i += 2) {
    m[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  return m;
}

/// Runs [count] short transactions of [arm], returning per-tx latency (µs).
Future<List<int>> _measure(
  PostgresConnectionPool pool,
  Future<void> Function(
          PostgresConnectionPool, Future<void> Function(QueryExecutor))
      arm,
  int count,
) async {
  final out = <int>[];
  final sw = Stopwatch();
  for (var i = 0; i < count; i++) {
    sw
      ..reset()
      ..start();
    await arm(pool, _oneStatement);
    sw.stop();
    out.add(sw.elapsedMicroseconds);
  }
  return out;
}

Future<void> main(List<String> args) async {
  final cfg = _parseArgs(args);
  final warmup = int.parse(cfg['warmup']!);
  final n = int.parse(cfg['n']!);
  final reps = int.parse(cfg['reps']!);
  final outPath = cfg['out']!;

  final pool = PostgresConnectionPool(
    PoolConfig(connInfo: connInfo(), minSize: 1, maxSize: 1),
  );
  await pool.start();

  // Warm up both arms (discarded).
  await _measure(pool, _eagerTxn, warmup);
  await _measure(pool, _fusedTxn, warmup);

  final rows = <String>[];
  rows.add('arm,rep,n,p50_us,p95_us,p99_us,mean_us,tps');
  final agg = <String, List<int>>{'eager': [], 'fused': []};

  for (var rep = 0; rep < reps; rep++) {
    // Interleave arm order per rep to cancel monotonic drift.
    final order = rep.isEven ? ['eager', 'fused'] : ['fused', 'eager'];
    for (final arm in order) {
      final lat =
          await _measure(pool, arm == 'eager' ? _eagerTxn : _fusedTxn, n);
      agg[arm]!.addAll(lat);
      final p = percentiles(List<int>.from(lat));
      final mean = lat.reduce((a, b) => a + b) / lat.length;
      final tps = 1e6 / mean;
      rows.add('$arm,$rep,$n,${p['p50']},${p['p95']},${p['p99']},'
          '${mean.toStringAsFixed(1)},${tps.toStringAsFixed(1)}');
    }
  }

  await pool.close();

  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString('${rows.join('\n')}\n');

  // Console summary: pooled medians across all reps.
  final ep = percentiles(List<int>.from(agg['eager']!));
  final fp = percentiles(List<int>.from(agg['fused']!));
  final eMean = agg['eager']!.reduce((a, b) => a + b) / agg['eager']!.length;
  final fMean = agg['fused']!.reduce((a, b) => a + b) / agg['fused']!.length;
  final dP50 = 100.0 * (fp['p50']! - ep['p50']!) / ep['p50']!;
  final dMean = 100.0 * (fMean - eMean) / eMean;
  stdout.writeln('── short-txn A/B (1×1, warm, interleaved) ──');
  stdout.writeln('samples/arm: ${agg['eager']!.length}  (reps=$reps × n=$n)');
  stdout.writeln('eager  p50=${ep['p50']}µs  p95=${ep['p95']}µs  '
      'mean=${eMean.toStringAsFixed(1)}µs  tps=${(1e6 / eMean).toStringAsFixed(0)}');
  stdout.writeln('fused  p50=${fp['p50']}µs  p95=${fp['p95']}µs  '
      'mean=${fMean.toStringAsFixed(1)}µs  tps=${(1e6 / fMean).toStringAsFixed(0)}');
  stdout.writeln('Δ p50: ${dP50.toStringAsFixed(1)}%   '
      'Δ mean: ${dMean.toStringAsFixed(1)}%  (negative = fused faster)');
  stdout.writeln('CSV → $outPath');
}
