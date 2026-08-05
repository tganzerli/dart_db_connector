/// TPC-C single-isolate-multi-conn benchmark harness — .
///
/// Runs N concurrent "tx slots" inside **one Dart isolate**, sharing a
/// connection pool of N conns dispatched via `Future.wait`. Bypasses the
/// multi-isolate harness (`tpcc_multi.dart`) to isolate the contribution
/// of the isolate boundary itself to the lead-single/lose-multi gap.
///
/// Hypothesis under test: H3 in
///
/// Topologies: 1×4, 1×8, 1×16 (configured via `--conns`).
///
/// Drivers: `native` (Dart developed FFI Tier 6) or `postgres` (Dart pkg
/// pub.dev 3.5.11) — both share the same `TpccDriver` interface.
///
/// Each slot runs an independent `TpccMix` seeded with `42 + rep*1000 +
/// slot*7` for reproducibility + independence.
///
/// Usage:
///   dart run scripts/tpcc_single_isolate.dart --driver native \
///     --conns 16 --tx-count 5000 --reps 3 \
///     --out-base isolated_f1a_dart-developed_1x16
///
/// Output: BENCH_OUTPUT_DIR/<out-base>.csv (latency rows; topology
/// column = "1xN").
library;

import 'dart:async';
import 'dart:io';

import 'tpcc/metrics.dart';
import 'tpcc/mix.dart';
import 'tpcc/tpcc_driver.dart';
import 'tpcc/transactions_native.dart';
import 'tpcc/transactions_native_multiread.dart';
import 'tpcc/transactions_native_psbinary.dart';
import 'tpcc/transactions_postgres.dart';

const _outputDirDefault = '../docker/bench/outputs';
const _outputBaseDefault = 'tpcc_single_isolate';

Future<void> main(List<String> args) async {
  final params = _parseArgs(args);

  final driverName = params['driver']!;
  final conns = int.parse(params['conns']!);
  final totalTx = int.parse(params['tx-count']!);
  final reps = int.parse(params['reps']!);
  final perSlot = totalTx ~/ conns;
  final actualTotal = perSlot * conns;
  if (actualTotal != totalTx) {
    print('[warn] tx-count $totalTx not divisible by conns $conns; '
        'actual per-rep total = $actualTotal');
  }

  final outputDir =
      Platform.environment['BENCH_OUTPUT_DIR'] ?? _outputDirDefault;
  final outputBase = params['out-base'] ?? _outputBaseDefault;
  final topology = '1x$conns';

  print('=== TPC-C single-isolate-multi-conn benchmark ===');
  print('driver=$driverName, topology=$topology, slots=$conns × tx=$perSlot '
      '= $actualTotal tx/rep, reps=$reps');
  print('output=$outputDir/$outputBase.csv');

  final metrics = MetricsCollector();
  final repTps = <double>[];

  for (var rep = 1; rep <= reps; rep++) {
    print('\n--- rep $rep/$reps ---');

    final driver = _makeDriver(driverName, conns);
    await driver.setup();

    // Per-slot warmup (small, just enough to amortize cold pool / cold
    // prepared statements). Each slot warms its own RNG path.
    const warmupPerSlot = 50;
    final warmupFutures = <Future<void>>[];
    for (var slot = 0; slot < conns; slot++) {
      final mix = TpccMix(7777 + rep * 1000 + slot * 7);
      warmupFutures.add(_runSlot(driver, mix, warmupPerSlot,
          collect: null,
          rep: rep,
          slot: slot,
          topology: topology,
          driverName: driverName));
    }
    await Future.wait(warmupFutures);

    // Measured window. Wall-clock per P10 of `benchmark_protocol_rule`.
    final wall = Stopwatch()..start();
    final slotFutures = <Future<void>>[];
    final perSlotSamples = <List<TpccSample>>[];
    for (var slot = 0; slot < conns; slot++) {
      final slotSamples = <TpccSample>[];
      perSlotSamples.add(slotSamples);
      final mix = TpccMix(42 + rep * 1000 + slot * 7);
      slotFutures.add(_runSlot(driver, mix, perSlot,
          collect: slotSamples,
          rep: rep,
          slot: slot,
          topology: topology,
          driverName: driverName));
    }
    await Future.wait(slotFutures);
    wall.stop();

    var totalSamples = 0;
    for (final list in perSlotSamples) {
      metrics.samples.addAll(list);
      totalSamples += list.length;
    }

    final tps = totalSamples * 1000 / wall.elapsedMilliseconds;
    repTps.add(tps);
    final rss = ProcessInfo.currentRss;
    print('[rep $rep] wall=${wall.elapsed}, samples=$totalSamples, '
        'tps=${tps.toStringAsFixed(1)}, '
        'RSS=${(rss / 1024 / 1024).toStringAsFixed(1)}MiB');

    await driver.close();
  }

  Directory(outputDir).createSync(recursive: true);
  await metrics.writeSamplesCsv('$outputDir/$outputBase.csv');

  // Summary by tx_type.
  print('\n=== summary ($driverName, $topology) ===');
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

/// One slot's body: `count` transactions back-to-back against the shared
/// pool, each measured and (optionally) collected into [collect]. When
/// [collect] is null this is a warmup loop (no measurement persisted).
Future<void> _runSlot(
  TpccDriver driver,
  TpccMix mix,
  int count, {
  required List<TpccSample>? collect,
  required int rep,
  required int slot,
  required String topology,
  required String driverName,
}) async {
  for (var i = 0; i < count; i++) {
    final t = mix.nextType();
    final sw = Stopwatch()..start();
    var success = true;
    try {
      await _runTypedTx(driver, mix, t);
    } catch (_) {
      success = false;
    }
    sw.stop();
    if (collect != null) {
      collect.add(TpccSample(
        rep,
        driverName,
        t.name,
        sw.elapsedMicroseconds,
        success,
        workerId: slot,
        topology: topology,
      ));
    }
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

TpccDriver _makeDriver(String name, int poolSize) {
  switch (name) {
    case 'native':
      return NativeTpccDriver(poolSize: poolSize);
    case 'native-multiread':
      return NativeMultiReadTpccDriver(poolSize: poolSize);
    case 'native-psbinary':
      return NativePsBinaryTpccDriver(poolSize: poolSize);
    case 'postgres':
      return PostgresPkgTpccDriver(poolSize: poolSize);
    default:
      throw ArgumentError('unknown driver: $name');
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final r = <String, String>{
    'driver': 'native',
    'conns': '16',
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
