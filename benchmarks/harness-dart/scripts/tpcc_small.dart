/// TPC-C small-scale benchmark harness.
///
/// Usage:
///   dart run scripts/tpcc_small.dart --driver native --tx-count 5000 --reps 3
///   dart run scripts/tpcc_small.dart --driver postgres --tx-count 5000 --reps 3
///
/// Output:
///   ../docker/bench/outputs/legacy/tpcc-baseline.csv        (latency samples)
///   ../docker/bench/outputs/legacy/tpcc-baseline-rss.csv    (RSS samples)
///
/// Mix: NewOrder 45 / Payment 43 / OrderStatus 4 / Delivery 4 / StockLevel 4.
/// Warmup: 500 tx (not measured). Reps × tx-count tx per run; same seeded
/// RNG per (driver, rep) → identical decision paths between drivers when
/// possible.
library;

import 'dart:io';

import 'tpcc/metrics.dart';
import 'tpcc/mix.dart';
import 'tpcc/tpcc_driver.dart';
import 'tpcc/transactions_native.dart';
import 'tpcc/transactions_native_multiread.dart';
import 'tpcc/transactions_native_psbinary.dart';
import 'tpcc/transactions_postgres.dart';

const _outputDirDefault = '../docker/bench/outputs';
const _outputBaseDefault = 'tpcc-baseline';
const int _warmupTx = 500;
const int _rssEvery = 500;

Future<void> main(List<String> args) async {
  final params = _parseArgs(args);

  final driverName = params['driver']!;
  final txCount = int.parse(params['tx-count']!);
  final reps = int.parse(params['reps']!);

  final outputDir =
      Platform.environment['BENCH_OUTPUT_DIR'] ?? _outputDirDefault;
  final outputBase = params['out-base'] ?? _outputBaseDefault;

  print('=== TPC-C small benchmark ===');
  print('driver=$driverName, tx-count=$txCount, reps=$reps');
  print('output=$outputDir/$outputBase{,-rss}.csv');

  final metrics = MetricsCollector();

  for (var rep = 1; rep <= reps; rep++) {
    print('\n--- rep $rep/$reps ---');
    final driver = _makeDriver(driverName);
    await driver.setup();

    // Seed RNG per rep so each rep is reproducible AND distinct.
    final mix = TpccMix(42 + rep * 1000);

    // Warmup (not measured).
    print('[warmup] $_warmupTx tx...');
    for (var i = 0; i < _warmupTx; i++) {
      await _runOne(driver, mix);
    }

    // Measured.
    print('[measure] $txCount tx...');
    final sw = Stopwatch()..start();
    for (var i = 0; i < txCount; i++) {
      final txType = mix.nextType();
      final txSw = Stopwatch()..start();
      var success = true;
      try {
        await _runTypedTx(driver, mix, txType);
      } catch (e) {
        success = false;
        if (i < 5) {
          print('  [err] tx $i ($txType): $e');
        }
      }
      txSw.stop();
      metrics.recordTx(TpccSample(
        rep,
        driverName,
        txType.name,
        txSw.elapsedMicroseconds,
        success,
      ));

      if (i % _rssEvery == 0) {
        metrics.recordRss(
            RssSample(rep, driverName, i, ProcessInfo.currentRss));
      }
    }
    sw.stop();
    final tps = txCount * 1000 / sw.elapsedMilliseconds;
    print('[rep $rep] wall=${sw.elapsed}, tps=${tps.toStringAsFixed(1)}');

    await driver.close();
  }

  // Persist CSVs.
  Directory(outputDir).createSync(recursive: true);
  await metrics.writeSamplesCsv('$outputDir/$outputBase.csv');
  await metrics.writeRssCsv('$outputDir/$outputBase-rss.csv');

  // Quick summary by tx type.
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

  final rssBytes =
      metrics.rssSamples.map((s) => s.rssBytes).fold<int>(0, (a, b) => a > b ? a : b);
  print('  peak RSS = ${(rssBytes / 1024 / 1024).toStringAsFixed(1)} MiB');
}

Future<void> _runOne(TpccDriver d, TpccMix mix) =>
    _runTypedTx(d, mix, mix.nextType());

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

TpccDriver _makeDriver(String name) {
  switch (name) {
    case 'native':
      return NativeTpccDriver(poolSize: 4);
    case 'native-multiread':
      return NativeMultiReadTpccDriver(poolSize: 4);
    case 'native-psbinary':
      return NativePsBinaryTpccDriver(poolSize: 4);
    case 'postgres':
      return PostgresPkgTpccDriver(poolSize: 4);
    default:
      throw ArgumentError('unknown driver: $name');
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{
    'driver': 'native',
    'tx-count': '5000',
    'reps': '3',
  };
  for (var i = 0; i < args.length; i += 2) {
    final k = args[i].replaceFirst('--', '');
    final v = args[i + 1];
    result[k] = v;
  }
  return result;
}
