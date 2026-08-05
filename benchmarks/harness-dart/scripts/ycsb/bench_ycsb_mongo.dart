/// YCSB runner for the MongoDB drivers.
///
/// Load phase populates `--records` documents, then the run phase issues
/// `--ops` operations across `--conns` concurrent loops using a fixed-seed
/// workload (identical key stream per driver). Throughput is reported by
/// **wall-clock** (ops ÷ wall seconds), per benchmark_protocol_rule P10.
/// Per-op samples go to the same CSV schema as the TPC-C bench so the shared
/// aggregator consumes Dart + Go uniformly.
///
/// Usage:
///   dart run benchmarks/scripts/ycsb/bench_ycsb_mongo.dart \
///     --driver native-mongo --workload C --conns 4 --ops 40000 \
///     --records 10000 --reps 3 [--csv out.csv]
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import 'ycsb_driver.dart';
import 'ycsb_mongo_pkg.dart';
import 'ycsb_native_mongo.dart';
import 'ycsb_workload.dart';

int _argInt(List<String> a, String flag, int def) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? int.parse(a[i + 1]) : def;
}

String? _argStr(List<String> a, String flag) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : null;
}

Future<void> main(List<String> args) async {
  final conns = _argInt(args, '--conns', 4);
  final opCount = _argInt(args, '--ops', 40000);
  final recordCount = _argInt(args, '--records', 10000);
  final reps = _argInt(args, '--reps', 3);
  final warmup = _argInt(args, '--warmup', 500);
  // Bulk batch size for the write-heavy (W) workload: 1 = unitary insertOne
  // baseline, >1 = insertMany of this many docs (the F1 lever under test).
  final batch = _argInt(args, '--batch', 1);
  final baseSeed = _argInt(args, '--seed', 12345);
  final csvPath = _argStr(args, '--csv');
  final driverName = _argStr(args, '--driver') ?? 'native-mongo';
  final workloadName = _argStr(args, '--workload') ?? 'C';
  final topology = _argStr(args, '--topology') ?? '';
  // Key distribution: uniform (default, for fair cross-language runs where
  // every driver must draw the SAME kind of key stream) or zipfian.
  final zipfian = (_argStr(args, '--dist') ?? 'uniform') == 'zipfian';

  final cfg = YcsbConfig(recordCount: recordCount);
  final workload = YcsbWorkload.byName(workloadName);

  final driver = _makeDriver(driverName, conns);
  await driver.setup(conns);

  if (workload.isWriteHeavy) {
    stderr.writeln('[reset] emptying collection for write-heavy insert '
        '($driverName, batch=$batch)…');
    await driver.resetEmpty();
  } else {
    stderr.writeln('[load] inserting $recordCount records ($driverName)…');
    await driver.load(cfg);
  }

  final workers = <YcsbWorker>[];
  for (var k = 0; k < conns; k++) {
    workers.add(await driver.worker());
  }

  if (workload.isWriteHeavy) {
    await _runWriteHeavy(
      driver: driver,
      workers: workers,
      cfg: cfg,
      driverName: driverName,
      conns: conns,
      opCount: opCount,
      reps: reps,
      warmup: warmup,
      batch: batch,
      topology: topology,
      csvPath: csvPath,
    );
    return;
  }

  // Warmup (unmeasured), on worker 0.
  final warmMix = YcsbMix(cfg, workload, baseSeed, zipfian: zipfian);
  for (var i = 0; i < warmup; i++) {
    final o = warmMix.next();
    try {
      if (o.op == YcsbOp.read) {
        await workers[0].read(o.key);
      } else {
        await workers[0].update(o.key, ycsbUpdateField(cfg, o.field));
      }
    } catch (_) {}
  }

  final samples = <String>[
    'run_id,driver,tx_type,latency_us,success,worker_id,topology'
  ];

  for (var rep = 1; rep <= reps; rep++) {
    final perLoop = (opCount / conns).ceil();
    var failed = 0;
    final wall = Stopwatch()..start();
    final perLoopRows = await Future.wait([
      for (var k = 0; k < conns; k++)
        () async {
          final mix = YcsbMix(cfg, workload, baseSeed + rep * 1000 + k, zipfian: zipfian);
          final w = workers[k];
          final rows = <String>[];
          for (var i = 0; i < perLoop; i++) {
            final o = mix.next();
            final sw = Stopwatch()..start();
            var ok = true;
            try {
              if (o.op == YcsbOp.read) {
                await w.read(o.key);
              } else {
                await w.update(o.key, ycsbUpdateField(cfg, o.field));
              }
            } catch (_) {
              ok = false;
              failed++;
            }
            sw.stop();
            rows.add('$rep,$driverName,${o.op.name},${sw.elapsedMicroseconds},'
                '${ok ? 1 : 0},$k,$topology');
          }
          return rows;
        }(),
    ]);
    wall.stop();

    final done = perLoop * conns;
    for (final r in perLoopRows) {
      samples.addAll(r);
    }
    final tps = done * 1000.0 / wall.elapsedMilliseconds;
    stdout.writeln('rep $rep: driver=$driverName wl=$workloadName conns=$conns '
        'ops=$done wall=${wall.elapsedMilliseconds}ms '
        'ops/s=${tps.toStringAsFixed(0)} failed=$failed');
  }

  await driver.close();

  if (csvPath != null) {
    File(csvPath).writeAsStringSync('${samples.join('\n')}\n');
    stderr.writeln('[csv] wrote $csvPath (${samples.length - 1} samples)');
  }
}

/// Write-heavy (workload W) run phase: each worker inserts a DISJOINT range of
/// new documents, either one-by-one (`batch == 1`, unitary insertOne baseline)
/// or in bulk (`batch > 1`, insertMany — the F1 lever). Throughput is reported
/// in DOCUMENTS/sec by wall-clock (P10). `_id`s are unique across (rep, worker)
/// so no drop is needed between reps.
Future<void> _runWriteHeavy({
  required YcsbDriver driver,
  required List<YcsbWorker> workers,
  required YcsbConfig cfg,
  required String driverName,
  required int conns,
  required int opCount,
  required int reps,
  required int warmup,
  required int batch,
  required String topology,
  required String? csvPath,
}) async {
  final fields = ycsbFields(cfg);
  Map<String, Object?> buildDoc(int id) => {'_id': id, ...fields};
  final txType = batch > 1 ? 'insert_bulk' : 'insert';

  // Warmup (unmeasured), on worker 0, with negative ids (disjoint from the
  // measured range, which is >= 0).
  for (var i = 0; i < warmup; i++) {
    try {
      await workers[0].insertOne(buildDoc(-1 - i));
    } catch (_) {}
  }

  final samples = <String>[
    'run_id,driver,tx_type,latency_us,success,worker_id,topology'
  ];

  final perLoop = (opCount / conns).ceil();
  for (var rep = 1; rep <= reps; rep++) {
    var failed = 0;
    final wall = Stopwatch()..start();
    final perLoopRows = await Future.wait([
      for (var k = 0; k < conns; k++)
        () async {
          final w = workers[k];
          final base = (rep * conns + k) * perLoop;
          final rows = <String>[];
          for (var i = 0; i < perLoop; i += batch) {
            final take = min(batch, perLoop - i);
            final sw = Stopwatch()..start();
            var ok = true;
            try {
              if (batch == 1) {
                await w.insertOne(buildDoc(base + i));
              } else {
                await w.insertMany(
                    [for (var j = 0; j < take; j++) buildDoc(base + i + j)]);
              }
            } catch (_) {
              ok = false;
              failed += take;
            }
            sw.stop();
            rows.add('$rep,$driverName,$txType,${sw.elapsedMicroseconds},'
                '${ok ? 1 : 0},$k,$topology');
          }
          return rows;
        }(),
    ]);
    wall.stop();

    for (final r in perLoopRows) {
      samples.addAll(r);
    }
    final done = perLoop * conns; // documents inserted
    final tps = done * 1000.0 / wall.elapsedMilliseconds;
    stdout.writeln('rep $rep: driver=$driverName wl=W batch=$batch conns=$conns '
        'docs=$done wall=${wall.elapsedMilliseconds}ms '
        'docs/s=${tps.toStringAsFixed(0)} failed=$failed');
  }

  await driver.close();

  if (csvPath != null) {
    File(csvPath).writeAsStringSync('${samples.join('\n')}\n');
    stderr.writeln('[csv] wrote $csvPath (${samples.length - 1} samples)');
  }
}

YcsbDriver _makeDriver(String name, int poolSize) {
  switch (name) {
    case 'native-mongo':
      return NativeMongoYcsbDriver(poolSize: poolSize);
    case 'mongo-pkg':
      return MongoPkgYcsbDriver(poolSize: poolSize);
    default:
      throw ArgumentError('unknown driver: $name (native-mongo | mongo-pkg)');
  }
}
