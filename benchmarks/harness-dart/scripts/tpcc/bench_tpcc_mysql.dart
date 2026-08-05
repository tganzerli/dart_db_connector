/// Single-process TPC-C runner for the developed MySQL driver.
///
/// Runs the canonical TPC-C mix against MySQL and reports throughput by
/// **wall-clock** (transactions ÷ wall seconds), per benchmark_protocol_rule
/// P10. Concurrency is `--conns` independent transaction loops sharing one
/// pool (a 1×N topology). Schema must already be applied (runner does it via
/// the mysql CLI); pass `--seed-db` to populate data first.
///
/// Usage:
///   dart run benchmarks/scripts/tpcc/bench_tpcc_mysql.dart \
///     --conns 4 --tx-count 5000 --reps 3 [--seed-db] [--csv out.csv]
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_connector/dart_db_connector.dart';

import 'mix.dart';
import 'mysql_conn_info.dart';
import 'tpcc_driver.dart';
import 'tpcc_seed_mysql.dart';
import 'transactions_mysql_pkg.dart';
import 'transactions_native_mysql.dart';
import 'transactions_native_mysql_batched.dart';
import 'transactions_native_mysql_readmulti.dart';

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
  final txCount = _argInt(args, '--tx-count', 5000);
  final reps = _argInt(args, '--reps', 3);
  final warmup = _argInt(args, '--warmup', 200);
  final baseSeed = _argInt(args, '--seed', 12345);
  final csvPath = _argStr(args, '--csv');
  final driverName = _argStr(args, '--driver') ?? 'native-mysql';
  final topology = _argStr(args, '--topology') ?? '';
  final seedDb = args.contains('--seed-db');

  if (seedDb) {
    final c = mysqlConn();
    final seedPool = MysqlConnectionPool(MysqlPoolConfig(
      host: c.host, port: c.port, user: c.user,
      password: c.password, database: c.database, minSize: 1, maxSize: 1,
    ));
    await seedPool.start();
    stderr.writeln('[seed] populating (kWarehouses=$kWarehouses)…');
    await seedMysql(seedPool);
    await seedPool.close();
  }

  // Seed-only mode: `--seed-db --tx-count 0` populates the DB and exits, so
  // the strict isolation runner can seed once per session then run any driver (the Go and
  // mysql_client baselines have no seeder of their own).
  if (txCount <= 0) {
    stderr.writeln('[seed-only] tx-count=0 → done seeding, no measured run.');
    return;
  }

  // Per-tx samples in the standard cross-driver CSV format so the same
  // aggregator (docker/bench/aggregate.py) consumes Dart + Go uniformly.
  final samples = <String>[
    'run_id,driver,tx_type,latency_us,success,worker_id,topology'
  ];
  for (var rep = 1; rep <= reps; rep++) {
    final driver = _makeDriver(driverName, conns);
    await driver.setup();

    // Warmup (unmeasured).
    final warmMix = TpccMix(baseSeed);
    for (var i = 0; i < warmup; i++) {
      try {
        await _runTx(driver, warmMix, warmMix.nextType());
      } catch (_) {}
    }

    // Measured: `conns` concurrent loops (a 1×N topology in one isolate).
    final perLoop = (txCount / conns).ceil();
    final wall = Stopwatch()..start();
    var failed = 0;
    final perLoopRows = await Future.wait([
      for (var k = 0; k < conns; k++)
        () async {
          final mix = TpccMix(baseSeed + rep * 1000 + k);
          final rows = <String>[];
          for (var i = 0; i < perLoop; i++) {
            final t = mix.nextType();
            final sw = Stopwatch()..start();
            var ok = true;
            try {
              await _runTx(driver, mix, t);
            } catch (_) {
              ok = false;
              failed++;
            }
            sw.stop();
            rows.add('$rep,$driverName,${t.name},${sw.elapsedMicroseconds},'
                '${ok ? 1 : 0},$k,$topology');
          }
          return rows;
        }(),
    ]);
    wall.stop();
    await driver.close();

    final done = perLoop * conns;
    for (final r in perLoopRows) {
      samples.addAll(r);
    }
    final wallMs = wall.elapsedMilliseconds;
    final tps = done * 1000.0 / wallMs;
    stdout.writeln('rep $rep: driver=$driverName conns=$conns tx=$done '
        'wall=${wallMs}ms TPS=${tps.toStringAsFixed(1)} failed=$failed');
  }

  if (csvPath != null) {
    File(csvPath).writeAsStringSync('${samples.join('\n')}\n');
    stderr.writeln('[csv] wrote $csvPath (${samples.length - 1} samples)');
  }
}

TpccDriver _makeDriver(String name, int poolSize) {
  switch (name) {
    case 'native-mysql':
      return NativeMysqlTpccDriver(poolSize: poolSize);
    case 'native-mysql-batched':
      return NativeMysqlBatchedTpccDriver(poolSize: poolSize);
    case 'native-mysql-readmulti':
      return NativeMysqlReadMultiTpccDriver(poolSize: poolSize);
    case 'mysql-pkg':
      return MysqlPkgTpccDriver(poolSize: poolSize);
    default:
      throw ArgumentError('unknown driver: $name '
          '(expected native-mysql | native-mysql-batched | '
          'native-mysql-readmulti | mysql-pkg)');
  }
}

Future<void> _runTx(TpccDriver d, TpccMix mix, TxType t) {
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
