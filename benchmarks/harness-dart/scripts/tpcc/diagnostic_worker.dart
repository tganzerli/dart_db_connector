/// Worker-isolate function for the pool-diagnostics-instrumentation
/// benchmark (task J). Mirrors [multi_worker] but emits per-tx
/// [TxDiagnostics] records alongside the regular [TpccSample]s.
///
/// Only the native driver is supported here (postgres-pkg is not the
/// subject of task J).
library;

import 'dart:io';
import 'dart:isolate';

import 'package:dart_db_connector/dart_db_connector.dart';

import 'metrics.dart';
import 'mix.dart';
import 'tpcc_driver.dart';
import 'transactions_native.dart';

class DiagWorkerStart {
  final int workerId;
  final int repId;
  final int txCount;
  final int connsPerWorker;
  final int seed;
  final SendPort replyPort;
  final String topology; // '4x4', '4x2', '1x1' etc.
  const DiagWorkerStart({
    required this.workerId,
    required this.repId,
    required this.txCount,
    required this.connsPerWorker,
    required this.seed,
    required this.replyPort,
    required this.topology,
  });
}

/// Per-tx record combining latency + pool diagnostics.
class DiagSample {
  final int repId;
  final int workerId;
  final String txType;
  final int latencyUs;
  final bool success;
  final String topology;
  final int acquireWaitUs;
  final int queueDepthAtAcquire;
  final int beginUs;
  final int workUs;
  final int commitUs;
  const DiagSample(
    this.repId,
    this.workerId,
    this.txType,
    this.latencyUs,
    this.success,
    this.topology,
    this.acquireWaitUs,
    this.queueDepthAtAcquire,
    this.beginUs,
    this.workUs,
    this.commitUs,
  );
}

class DiagWorkerResult {
  final int workerId;
  final List<DiagSample> samples;
  final int peakRssBytes;
  final int wallTimeUs;
  const DiagWorkerResult({
    required this.workerId,
    required this.samples,
    required this.peakRssBytes,
    required this.wallTimeUs,
  });
}

Future<void> diagnosticWorkerMain(DiagWorkerStart start) async {
  // Sink stores the most recent diagnostics; consumed per-tx after the
  // call returns. Dart isolate single-threading guarantees no race.
  TxDiagnostics? lastDiag;
  final driver = NativeTpccDriver(
    poolSize: start.connsPerWorker,
    diagnosticsSink: (diag) => lastDiag = diag,
  );
  await driver.setup();

  final mix = TpccMix(start.seed);

  // Warmup (not recorded). Drain lastDiag after each.
  const warmup = 100;
  for (var i = 0; i < warmup; i++) {
    try {
      await _runTypedTx(driver, mix, mix.nextType());
    } catch (_) {}
    lastDiag = null;
  }

  final samples = <DiagSample>[];
  var peakRss = ProcessInfo.currentRss;
  final wall = Stopwatch()..start();

  for (var i = 0; i < start.txCount; i++) {
    final t = mix.nextType();
    final sw = Stopwatch()..start();
    var success = true;
    try {
      await _runTypedTx(driver, mix, t);
    } catch (_) {
      success = false;
    }
    sw.stop();
    final d = lastDiag;
    lastDiag = null;
    samples.add(DiagSample(
      start.repId,
      start.workerId,
      t.name,
      sw.elapsedMicroseconds,
      success,
      start.topology,
      d?.acquireWaitUs ?? -1,
      d?.queueDepthAtAcquire ?? -1,
      d?.beginUs ?? -1,
      d?.workUs ?? -1,
      d?.commitUs ?? -1,
    ));
    if (i % 500 == 0) {
      final rss = ProcessInfo.currentRss;
      if (rss > peakRss) peakRss = rss;
    }
  }
  wall.stop();
  await driver.close();

  start.replyPort.send(DiagWorkerResult(
    workerId: start.workerId,
    samples: samples,
    peakRssBytes: peakRss,
    wallTimeUs: wall.elapsedMicroseconds,
  ));
}

Future<void> _runTypedTx(TpccDriver d, TpccMix mix, TxType t) {
  switch (t) {
    case TxType.newOrder:
      return d.newOrder(mix.newOrderParams());
    case TxType.payment:
      return d.payment(mix.paymentParams());
    case TxType.orderStatus:
      return d.orderStatus(mix.orderStatusParams());
    case TxType.delivery:
      return d.delivery(mix.deliveryParams());
    case TxType.stockLevel:
      return d.stockLevel(mix.stockLevelParams());
  }
}

/// Writes a header + N rows in the diagnostic CSV format.
Future<void> writeDiagCsv(String path, List<DiagSample> samples) async {
  final file = File(path);
  final exists = file.existsSync();
  final sink = file.openWrite(mode: FileMode.append);
  if (!exists) {
    sink.writeln('run_id,driver,tx_type,latency_us,success,worker_id,topology,'
        'acquire_wait_us,queue_depth_at_acquire,begin_us,work_us,commit_us');
  }
  for (final s in samples) {
    sink.writeln(
        '${s.repId},native,${s.txType},${s.latencyUs},${s.success ? 1 : 0},'
        '${s.workerId},${s.topology},'
        '${s.acquireWaitUs},${s.queueDepthAtAcquire},'
        '${s.beginUs},${s.workUs},${s.commitUs}');
  }
  await sink.close();
}

/// Compatibility shim for the metrics module — same percentile
/// function works on raw int latencies.
Map<String, int> percentilesOf(List<int> values) => percentiles(values);
