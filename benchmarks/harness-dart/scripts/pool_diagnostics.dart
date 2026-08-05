/// Pool diagnostics runner (task J — pool-diagnostics-instrumentation).
///
/// Runs the TPC-C mix with `PostgresConnectionPool` instrumentation
/// enabled. Captures per-tx breakdown of wait_us + queue_depth +
/// begin_us + work_us + commit_us, so we can pinpoint where the
/// Dart 4×4 stockLevel p99 of 189ms is actually spent.
///
/// Usage:
///   dart run scripts/pool_diagnostics.dart --topology 4x4 --tx-count 5000 --reps 3
///
/// Topologies:
///   1x1 — 1 worker × 1 conn  (control)
///   4x2 — 4 workers × 2 conns (8 active = within `cores*2` theoretical limit)
///   4x4 — 4 workers × 4 conns (16 active = above limit; current bench setting)
///
/// Output: CSV at `$BENCH_OUTPUT_DIR/pool-diag-<topology>.csv` (default
/// `/outputs` inside Docker).
library;

import 'dart:io';
import 'dart:isolate';

import 'tpcc/diagnostic_worker.dart';
import 'tpcc/metrics.dart';

const _outputDirDefault = '../docker/bench/outputs';

Future<void> main(List<String> args) async {
  final params = _parseArgs(args);
  final topology = params['topology']!;
  final totalTxCount = int.parse(params['tx-count']!);
  final reps = int.parse(params['reps']!);
  final outBase = params['out-base'] ?? 'pool-diag-$topology';

  // Map topology -> (workers, connsPerWorker)
  final (workers, connsPerWorker) = switch (topology) {
    '1x1' => (1, 1),
    '4x2' => (4, 2),
    '4x4' => (4, 4),
    _ => throw ArgumentError('unknown topology: $topology'),
  };
  final perWorker = totalTxCount ~/ workers;

  final outputDir =
      Platform.environment['BENCH_OUTPUT_DIR'] ?? _outputDirDefault;
  Directory(outputDir).createSync(recursive: true);
  final csvPath = '$outputDir/$outBase.csv';

  print('=== Pool diagnostics ($topology) ===');
  print('workers=$workers conns-per-worker=$connsPerWorker '
      'total-conns=${workers * connsPerWorker}');
  print('per-rep tx: $perWorker × $workers = ${perWorker * workers}, reps=$reps');
  print('csv=$csvPath');

  final repTps = <double>[];

  for (var rep = 1; rep <= reps; rep++) {
    print('\n--- rep $rep/$reps ---');

    final replies = ReceivePort();
    final isolates = <Isolate>[];
    final repStart = Stopwatch()..start();

    for (var w = 0; w < workers; w++) {
      final iso = await Isolate.spawn(diagnosticWorkerMain, DiagWorkerStart(
        workerId: w,
        repId: rep,
        txCount: perWorker,
        connsPerWorker: connsPerWorker,
        seed: 42 + rep * 1000 + w,
        replyPort: replies.sendPort,
        topology: topology,
      ));
      isolates.add(iso);
    }

    final workerResults = <DiagWorkerResult>[];
    await for (final dynamic r in replies) {
      workerResults.add(r as DiagWorkerResult);
      if (workerResults.length == workers) break;
    }
    replies.close();
    for (final iso in isolates) {
      iso.kill(priority: Isolate.beforeNextEvent);
    }
    repStart.stop();

    final allSamples = <DiagSample>[];
    var totalCount = 0;
    var peakRss = 0;
    for (final r in workerResults) {
      allSamples.addAll(r.samples);
      totalCount += r.samples.length;
      if (r.peakRssBytes > peakRss) peakRss = r.peakRssBytes;
    }
    final tps = totalCount * 1000 / repStart.elapsedMilliseconds;
    repTps.add(tps);
    print('[rep $rep] wall=${repStart.elapsed} samples=$totalCount '
        'tps=${tps.toStringAsFixed(1)} '
        'peakRSS=${(peakRss / 1024 / 1024).toStringAsFixed(1)}MiB');

    await writeDiagCsv(csvPath, allSamples);
  }

  print('\n=== summary ($topology) ===');
  final avgTps = repTps.reduce((a, b) => a + b) / repTps.length;
  print('TPS avg across reps: ${avgTps.toStringAsFixed(1)}');

  // Quick stockLevel p99 readback from CSV for early signal.
  print('\n=== stockLevel-focused breakdown (after-this-run) ===');
  await _printStockLevelBreakdown(csvPath, topology);
}

Future<void> _printStockLevelBreakdown(String csvPath, String topology) async {
  // Re-read the CSV we just wrote. Lightweight, doesn't dominate runtime.
  final lines = await File(csvPath).readAsLines();
  if (lines.length < 2) return;
  // header: run_id,driver,tx_type,latency_us,success,worker_id,topology,
  //         acquire_wait_us,queue_depth_at_acquire,begin_us,work_us,commit_us
  final lat = <int>[];
  final wait = <int>[];
  final qd = <int>[];
  final begin = <int>[];
  final work = <int>[];
  final commit = <int>[];
  for (var i = 1; i < lines.length; i++) {
    final cols = lines[i].split(',');
    if (cols.length < 12) continue;
    if (cols[2] != 'stockLevel') continue;
    if (cols[4] != '1') continue; // success only
    if (cols[6] != topology) continue;
    lat.add(int.parse(cols[3]));
    wait.add(int.parse(cols[7]));
    qd.add(int.parse(cols[8]));
    begin.add(int.parse(cols[9]));
    work.add(int.parse(cols[10]));
    commit.add(int.parse(cols[11]));
  }
  if (lat.isEmpty) {
    print('  (no stockLevel samples)');
    return;
  }
  print('  n=${lat.length}');
  _line('  latency', lat);
  _line('  wait   ', wait);
  _line('  queueD ', qd);
  _line('  begin  ', begin);
  _line('  work   ', work);
  _line('  commit ', commit);
}

void _line(String label, List<int> values) {
  final p = percentiles(List.of(values));
  print('$label  p50=${p['p50']}us p95=${p['p95']}us p99=${p['p99']}us');
}

Map<String, String> _parseArgs(List<String> args) {
  final r = <String, String>{
    'topology': '4x4',
    'tx-count': '5000',
    'reps': '3',
  };
  for (var i = 0; i < args.length; i += 2) {
    final k = args[i].replaceFirst('--', '');
    final v = args[i + 1];
    r[k] = v;
  }
  return r;
}
