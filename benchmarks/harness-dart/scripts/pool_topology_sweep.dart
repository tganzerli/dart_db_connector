/// Sweep de topologias N×M para `IsolateWorkerPool` em TPC-C.
///
/// 5 topologias com o mesmo total de conns (16): 1×16, 2×8, 4×4, 8×2, 16×1.
/// 3 reps × 5000 tx × 2 drivers (native + postgres pkg) = 150k samples
/// totais. Reset DB + seed entre topologias para isolation.
///
/// Output:
///   ../docker/bench/outputs/legacy/pool-topology.csv  (com coluna `topology`)
library;

import 'dart:io';
import 'dart:isolate';

import 'tpcc/metrics.dart';
import 'tpcc/multi_worker.dart';

const _outputDir = '../docker/bench/outputs';
const _outputBase = 'pool-topology';
const _outputTpsCsv = '../docker/bench/outputs/legacy/pool-topology-tps.csv';

const _topologies = [
  (workers: 1, conns: 16),
  (workers: 2, conns: 8),
  (workers: 4, conns: 4),
  (workers: 8, conns: 2),
  (workers: 16, conns: 1),
];

const _reps = 3;
const _txCount = 5000;
const _drivers = ['native', 'postgres'];

const _schemaPath = '../benchmarks/fixtures/tpcc_schema.sql';
const _seedScript = 'fixtures/tpcc_seed.dart';

Future<void> _resetDb() async {
  final psql = await Process.run(
    'bash',
    [
      '-c',
      'docker exec -i postgres-dev psql -U postgres -d teste < $_schemaPath'
    ],
  );
  if (psql.exitCode != 0) {
    throw StateError('psql reset failed: ${psql.stderr}');
  }
}

Future<void> _seedDb() async {
  final dart = await Process.run('dart', ['run', _seedScript]);
  if (dart.exitCode != 0) {
    throw StateError('seed failed: ${dart.stderr}');
  }
}

class _RepResult {
  final List<TpccSample> samples;
  final List<({int repId, int wallMs, int sampleCount, double tps})> repTimings;
  _RepResult(this.samples, this.repTimings);
}

Future<_RepResult> _runTopology({
  required String driverName,
  required int workers,
  required int conns,
  required String topologyLabel,
}) async {
  final allSamples = <TpccSample>[];
  final timings = <({int repId, int wallMs, int sampleCount, double tps})>[];
  final perWorker = _txCount ~/ workers;
  print('    workers=$workers × conns=$conns, perWorker=$perWorker tx');

  for (var rep = 1; rep <= _reps; rep++) {
    final replies = ReceivePort();
    final isolates = <Isolate>[];
    final repStart = Stopwatch()..start();

    for (var w = 0; w < workers; w++) {
      final iso = await Isolate.spawn(multiWorkerMain, WorkerStart(
        workerId: w,
        repId: rep,
        driverName: driverName,
        txCount: perWorker,
        connsPerWorker: conns,
        seed: 42 + rep * 1000 + w,
        replyPort: replies.sendPort,
        topology: topologyLabel,
      ));
      isolates.add(iso);
    }

    final results = <WorkerResult>[];
    await for (final dynamic r in replies) {
      results.add(r as WorkerResult);
      if (results.length == workers) break;
    }
    replies.close();
    for (final iso in isolates) {
      iso.kill(priority: Isolate.beforeNextEvent);
    }
    repStart.stop();

    var totalSamples = 0;
    for (final r in results) {
      allSamples.addAll(r.samples);
      totalSamples += r.samples.length;
    }
    final wallMs = repStart.elapsedMilliseconds;
    final tps = totalSamples * 1000 / wallMs;
    timings.add((
      repId: rep,
      wallMs: wallMs,
      sampleCount: totalSamples,
      tps: tps,
    ));
    print('      rep $rep: ${repStart.elapsed} samples=$totalSamples '
        'tps=${tps.toStringAsFixed(1)}');
  }

  return _RepResult(allSamples, timings);
}

Future<void> main() async {
  print('=== Pool topology sweep ===');
  print('topologies: ${_topologies.map((t) => "${t.workers}x${t.conns}").join(", ")}');
  print('drivers: $_drivers');
  print('reps=$_reps, tx_count=$_txCount per topology');
  print('total samples: ${_topologies.length * _drivers.length * _reps * _txCount}');

  final metrics = MetricsCollector();
  final allTimings =
      <({String driver, String topology, int repId, int wallMs, int sampleCount, double tps})>[];

  for (final driverName in _drivers) {
    print('\n=== driver: $driverName ===');
    for (final t in _topologies) {
      final label = '${t.workers}x${t.conns}';
      print('\n  --- topology $label ---');

      print('    [reset]');
      await _resetDb();
      print('    [seed]');
      await _seedDb();

      final r = await _runTopology(
        driverName: driverName,
        workers: t.workers,
        conns: t.conns,
        topologyLabel: label,
      );
      metrics.samples.addAll(r.samples);
      for (final t2 in r.repTimings) {
        allTimings.add((
          driver: driverName,
          topology: label,
          repId: t2.repId,
          wallMs: t2.wallMs,
          sampleCount: t2.sampleCount,
          tps: t2.tps,
        ));
      }
    }
  }

  Directory(_outputDir).createSync(recursive: true);
  await metrics.writeSamplesCsv('$_outputDir/$_outputBase.csv');
  print('\n[csv] $_outputDir/$_outputBase.csv (${metrics.samples.length} rows)');

  // Wall-clock TPS CSV (cleaner data for plot).
  final tpsCsv = StringBuffer();
  tpsCsv.writeln('driver,topology,rep_id,wall_ms,samples,tps');
  for (final t in allTimings) {
    tpsCsv.writeln(
        '${t.driver},${t.topology},${t.repId},${t.wallMs},${t.sampleCount},${t.tps.toStringAsFixed(2)}');
  }
  File(_outputTpsCsv).writeAsStringSync(tpsCsv.toString());
  print('[csv] $_outputTpsCsv (${allTimings.length} rows)');

  // Summary table.
  print('\n=== Summary ===');
  for (final driver in _drivers) {
    print('\n[$driver]');
    for (final t in _topologies) {
      final label = '${t.workers}x${t.conns}';
      final filtered = metrics.samples.where(
          (s) => s.driver == driver && s.topology == label && s.success).toList();
      final byTx = <String, List<int>>{};
      for (final s in filtered) {
        byTx.putIfAbsent(s.txType, () => []).add(s.latencyUs);
      }
      final newOrderLats = byTx['newOrder'] ?? const <int>[];
      final p99 = newOrderLats.isEmpty
          ? 0
          : (List.of(newOrderLats)..sort())[
              (newOrderLats.length * 0.99).round().clamp(0, newOrderLats.length - 1)];
      print('  $label: '
          'n=${filtered.length} newOrder_p99=${p99}us');
    }
  }
}
