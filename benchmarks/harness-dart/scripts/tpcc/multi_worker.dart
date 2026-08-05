/// Worker-isolate function for the multi-isolate TPC-C benchmark.
///
/// Each spawned isolate calls [multiWorkerMain] with a [WorkerStart]
/// describing which driver to use, how many transactions to run, and
/// where to send the [WorkerResult]. Messages are restricted to
/// SendPort-serializable types — no `Pointer<Void>` crosses isolate
/// boundaries (mirrors the pattern in `dart/lib/src/isolates/messages.dart`).
library;

import 'dart:io';
import 'dart:isolate';

import 'metrics.dart';
import 'mix.dart';
import 'tpcc_driver.dart';
import 'transactions_native.dart';
import 'transactions_native_multiread.dart';
import 'transactions_native_psbinary.dart';
import 'transactions_postgres.dart';

class WorkerStart {
  final int workerId;
  final int repId;
  final String driverName;
  final int txCount;
  final int connsPerWorker;
  final int seed;
  final SendPort replyPort;
  final String? topology; // set during pool-topology-sweep runs
  const WorkerStart({
    required this.workerId,
    required this.repId,
    required this.driverName,
    required this.txCount,
    required this.connsPerWorker,
    required this.seed,
    required this.replyPort,
    this.topology,
  });
}

class WorkerResult {
  final int workerId;
  final List<TpccSample> samples;
  final int peakRssBytes;
  final int wallTimeUs;
  const WorkerResult({
    required this.workerId,
    required this.samples,
    required this.peakRssBytes,
    required this.wallTimeUs,
  });
}

/// Top-level (required for `Isolate.spawn`).
Future<void> multiWorkerMain(WorkerStart start) async {
  final driver = _makeDriver(start.driverName, start.connsPerWorker);
  await driver.setup();

  final mix = TpccMix(start.seed);

  // Local warmup, not measured.
  const warmup = 100;
  for (var i = 0; i < warmup; i++) {
    try {
      await _runTypedTx(driver, mix, mix.nextType());
    } catch (_) {
      // tolerate warmup errors (cold pool)
    }
  }

  final samples = <TpccSample>[];
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
    samples.add(TpccSample(
      start.repId,
      start.driverName,
      t.name,
      sw.elapsedMicroseconds,
      success,
      workerId: start.workerId,
      topology: start.topology,
    ));
    if (i % 500 == 0) {
      final rss = ProcessInfo.currentRss;
      if (rss > peakRss) peakRss = rss;
    }
  }
  wall.stop();
  await driver.close();

  start.replyPort.send(WorkerResult(
    workerId: start.workerId,
    samples: samples,
    peakRssBytes: peakRss,
    wallTimeUs: wall.elapsedMicroseconds,
  ));
}

TpccDriver _makeDriver(String name, int poolSize) {
  switch (name) {
    case 'native':
      return NativeTpccDriver(poolSize: poolSize);
    case 'native-multiread':
      // F1b-PG (2026-07-28): read phase via executeMultiRead (ABI MINOR 2).
      return NativeMultiReadTpccDriver(poolSize: poolSize);
    case 'native-psbinary':
      // L (2026-05-23): Extended Protocol path via pool_submit_query_params.
      return NativePsBinaryTpccDriver(poolSize: poolSize);
    case 'postgres':
      return PostgresPkgTpccDriver(poolSize: poolSize);
    default:
      throw ArgumentError('unknown driver: $name');
  }
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
