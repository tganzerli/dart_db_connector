/// TPC-C multi-isolate benchmark harness.
///
/// Spawns N workers (each its own Dart isolate), each with M Postgres
/// connections, and distributes the total tx count across them. Both
/// drivers (native + postgres pkg) use the same N×M topology for an
/// apples-to-apples test of the "IsolateWorkerPool architecture pays
/// 2-5× under concurrency" hypothesis.
///
/// Usage:
///   dart run scripts/tpcc_multi.dart --driver native \
///     --workers 4 --conns-per-worker 4 \
///     --tx-count 5000 --reps 3
///
/// Output (appended; pre-delete CSV between drivers if you want
/// independent files):
///   ../docker/bench/outputs/legacy/tpcc-multi-isolate.csv  (latency rows + worker_id)
library;

import 'dart:io';
import 'dart:isolate';

import 'tpcc/metrics.dart';
import 'tpcc/mix.dart';
import 'tpcc/multi_worker.dart';

const _outputDirDefault = '../docker/bench/outputs';
const _outputBaseDefault = 'tpcc-multi-isolate';

Future<void> main(List<String> args) async {
  final params = _parseArgs(args);
  final driverName = params['driver']!;
  final workers = int.parse(params['workers']!);
  final connsPerWorker = int.parse(params['conns-per-worker']!);
  final totalTxCount = int.parse(params['tx-count']!);
  final reps = int.parse(params['reps']!);
  final perWorker = totalTxCount ~/ workers;
  if (perWorker * workers != totalTxCount) {
    print('[warn] tx-count $totalTxCount not divisible by workers $workers; '
        'actual total per rep = ${perWorker * workers}');
  }

  final outputDir =
      Platform.environment['BENCH_OUTPUT_DIR'] ?? _outputDirDefault;
  final outputBase = params['out-base'] ?? _outputBaseDefault;

  print('=== TPC-C multi-isolate benchmark ===');
  print('driver=$driverName, workers=$workers × conns=$connsPerWorker '
      '= ${workers * connsPerWorker} total conns');
  print('per-rep tx: $perWorker × $workers workers = ${perWorker * workers}, '
      'reps=$reps');
  print('output=$outputDir/$outputBase.csv');

  final metrics = MetricsCollector();
  final repTps = <double>[];

  for (var rep = 1; rep <= reps; rep++) {
    print('\n--- rep $rep/$reps ---');

    final replies = ReceivePort();
    final isolates = <Isolate>[];
    final repStart = Stopwatch()..start();

    for (var w = 0; w < workers; w++) {
      final iso = await Isolate.spawn(multiWorkerMain, WorkerStart(
        workerId: w,
        repId: rep,
        driverName: driverName,
        txCount: perWorker,
        connsPerWorker: connsPerWorker,
        seed: 42 + rep * 1000 + w,
        replyPort: replies.sendPort,
      ));
      isolates.add(iso);
    }

    final workerResults = <WorkerResult>[];
    await for (final dynamic r in replies) {
      workerResults.add(r as WorkerResult);
      if (workerResults.length == workers) break;
    }
    replies.close();
    for (final iso in isolates) {
      iso.kill(priority: Isolate.beforeNextEvent);
    }
    repStart.stop();

    int totalSamples = 0;
    int peakRss = 0;
    for (final r in workerResults) {
      metrics.samples.addAll(r.samples);
      totalSamples += r.samples.length;
      if (r.peakRssBytes > peakRss) peakRss = r.peakRssBytes;
    }
    final tps = totalSamples * 1000 / repStart.elapsedMilliseconds;
    repTps.add(tps);
    print('[rep $rep] wall=${repStart.elapsed}, '
        'samples=$totalSamples, tps=${tps.toStringAsFixed(1)}, '
        'peakRSS=${(peakRss / 1024 / 1024).toStringAsFixed(1)}MiB');
  }

  Directory(outputDir).createSync(recursive: true);
  await metrics.writeSamplesCsv('$outputDir/$outputBase.csv');

  // Summary by tx_type.
  print('\n=== summary ($driverName) ===');
  final byType = <String, List<int>>{};
  for (final s in metrics.samples) {
    if (!s.success) continue;
    byType.putIfAbsent(s.txType, () => []).add(s.latencyUs);
  }
  for (final type in TxType.values.map((t) => t.name)) {
    final lats = byType[type] ?? const <int>[];
    if (lats.isEmpty) {
      print('  $type: 0 samples');
      continue;
    }
    final p = percentiles(List.of(lats));
    final mean = lats.reduce((a, b) => a + b) / lats.length;
    print('  $type: n=${lats.length} '
        'mean=${mean.toStringAsFixed(0)}us '
        'p50=${p['p50']}us p95=${p['p95']}us p99=${p['p99']}us');
  }
  final avgTps = repTps.reduce((a, b) => a + b) / repTps.length;
  print('\nTPS avg across reps: ${avgTps.toStringAsFixed(1)}');

  final fails = metrics.samples.where((s) => !s.success).length;
  if (fails > 0) {
    print('  failed tx: $fails / ${metrics.samples.length} '
        '(${(100.0 * fails / metrics.samples.length).toStringAsFixed(2)}%)');
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final r = <String, String>{
    'driver': 'native',
    'workers': '4',
    'conns-per-worker': '4',
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
