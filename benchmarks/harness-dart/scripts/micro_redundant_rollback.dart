/// Micro-A/B: custo isolado do `ROLLBACK` redundante pós-`executePipeline`
/// (critério 2 da task tpcc-rebaseline-persistence).
///
/// **Motivação.** Pré-fix (`native_pool_worker.c`, `INTRANS || INERROR`),
/// cada `executePipeline` dentro de uma transação externa disparava um
/// `ROLLBACK` síncrono extra na worker thread. No TPC-C esse efeito estava
/// confundido com (a) o write-set nunca commitado e (b) a mudança de carga
/// (tabelas vazias vs populadas). Este micro-bench isola **exatamente uma**
/// variável: o custo do round-trip do `ROLLBACK` redundante, mantendo o
/// COMMIT constante nos dois braços.
///
/// - **CLEAN:**    `BEGIN; executePipeline(writes); COMMIT`  (como pós-fix).
/// - **ROLLBACK:** idem + **um `ROLLBACK` extra** ao final — no-op numa conn
///   já commitada, reproduzindo o RTT redundante que o worker pré-fix pagava.
///
/// Δlatência(ROLLBACK − CLEAN) = custo puro do rollback redundante por
/// transação. Ambos commitam → o confound de WAL/commit fica constante.
///
/// **Ameaça à validade (declarada na página):** o `ROLLBACK` é injetado pelo
/// caminho normal de `execute` em Dart, não pela rotina interna do worker
/// pré-fix. Mede o custo-RTT de um comando extra (a grandeza correta), não é
/// bit-idêntico ao path nativo antigo.
///
/// **Internal-API usage justified:** instancia `PostgresQueryExecutor`
/// diretamente sobre a conn arrendada para controlar o ponto exato de
/// injeção do rollback (mesmo padrão de `pipeline_vs_sequential.dart`).
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:io';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';

import 'tpcc/conn_info.dart';
import 'tpcc/metrics.dart';

/// Write-set representativo (mesma ordem de grandeza do batch terminal de
/// NewOrder: ~10 statements de INSERT/UPDATE). O conteúdo é irrelevante para
/// o Δ (o rollback extra é um custo aditivo constante por transação); o que
/// importa é ser idêntico nos dois braços.
List<String> _writes(int arm, int rep, int i, int nWrites) {
  return [
    for (var n = 0; n < nWrites; n++)
      "INSERT INTO bench_rollback_micro (arm, rep, i, n, payload) "
          "VALUES ($arm, $rep, $i, $n, 'p${i}_$n')",
  ];
}

Future<void> _release(dynamic rs) async {
  try {
    rs.release();
  } catch (_) {
    // command-tag results (BEGIN/COMMIT/ROLLBACK) podem não expor release;
    // ignorar defensivamente.
  }
}

Future<void> _setup(PostgresConnectionPool pool) async {
  await withTransaction(pool, (exec) async {
    await exec.execute('DROP TABLE IF EXISTS bench_rollback_micro');
    await exec.execute('CREATE TABLE bench_rollback_micro ('
        'arm int4 NOT NULL, rep int4 NOT NULL, i int4 NOT NULL, '
        'n int4 NOT NULL, payload text NOT NULL)');
  });
}

/// Uma transação do braço. Se [injectRollback], adiciona o RTT redundante.
/// Retorna a latência em microssegundos.
Future<int> _oneTx(PostgresQueryExecutor exec, int arm, int rep, int i,
    int nWrites, bool injectRollback) async {
  final writes = _writes(arm, rep, i, nWrites);
  final sw = Stopwatch()..start();
  await _release(await exec.execute('BEGIN'));
  await exec.executePipeline(writes);
  await _release(await exec.execute('COMMIT'));
  if (injectRollback) {
    // No-op numa conn já commitada — WARNING "no transaction in progress"
    // no servidor, mas paga o round-trip: exatamente a alavanca medida.
    await _release(await exec.execute('ROLLBACK'));
  }
  sw.stop();
  return sw.elapsedMicroseconds;
}

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final outputDir =
      Platform.environment['BENCH_OUTPUT_DIR'] ?? '../docker/bench/outputs';
  Directory(outputDir).createSync(recursive: true);
  final csvPath = '$outputDir/${opts.outBase}.csv';

  // out-base datado é único, mas o bind-mount sobrevive a `down -v`:
  // remove o CSV antigo para não acumular (metrics.dart usa append).
  final oldCsv = File(csvPath);
  if (oldCsv.existsSync()) oldCsv.deleteSync();

  final pool = PostgresConnectionPool(
    PoolConfig(connInfo: connInfo(), minSize: 1, maxSize: 1),
  );
  await pool.start();
  await _setup(pool);

  // Conn warm única, reutilizada em todas as iterações — exclui
  // acquire/release da região temporizada (isola o RTT do rollback).
  final leased = await pool.acquire();
  final exec = PostgresQueryExecutor(pool.binding, leased.raw);

  print('=== Micro-A/B: custo do ROLLBACK redundante ===');
  print('reps=${opts.reps}, n=${opts.n}, warmup=${opts.warmup}, '
      'writes/tx=${opts.writes}');

  final collector = MetricsCollector();

  // Warmup (descartado): roda ambos os braços.
  for (var i = 0; i < opts.warmup; i++) {
    await _oneTx(exec, 0, 0, i, opts.writes, false);
    await _oneTx(exec, 1, 0, i, opts.writes, true);
  }

  var runId = 0;
  for (var rep = 1; rep <= opts.reps; rep++) {
    // Interleaving: alterna a ordem dos braços por rep p/ cancelar deriva.
    final cleanFirst = rep.isOdd;
    print(
        '--- rep $rep (${cleanFirst ? "clean→rollback" : "rollback→clean"}) ---');

    Future<void> runArm(String name, bool injectRollback, int arm) async {
      final lat = <int>[];
      for (var i = 0; i < opts.n; i++) {
        final us = await _oneTx(exec, arm, rep, i, opts.writes, injectRollback);
        lat.add(us);
        collector.recordTx(
            TpccSample(runId++, 'native', name, us, true, topology: 'micro'));
      }
      final p = percentiles(List.of(lat));
      print('  $name: p50=${p['p50']}us p95=${p['p95']}us p99=${p['p99']}us');
    }

    if (cleanFirst) {
      await runArm('clean', false, 0);
      await runArm('rollback', true, 1);
    } else {
      await runArm('rollback', true, 1);
      await runArm('clean', false, 0);
    }
  }

  await leased.release();
  await pool.close();

  await collector.writeSamplesCsv(csvPath);
  print('[csv] $csvPath');

  // Resumo pooled (todas as reps agregadas) + Δ.
  final cleanLat = collector.samples
      .where((s) => s.txType == 'clean')
      .map((s) => s.latencyUs)
      .toList();
  final rollbackLat = collector.samples
      .where((s) => s.txType == 'rollback')
      .map((s) => s.latencyUs)
      .toList();
  final pc = percentiles(List.of(cleanLat));
  final pr = percentiles(List.of(rollbackLat));
  final meanClean = cleanLat.reduce((a, b) => a + b) / cleanLat.length;
  final meanRollback = rollbackLat.reduce((a, b) => a + b) / rollbackLat.length;
  print('\n=== Resumo pooled (${cleanLat.length} amostras/braço) ===');
  print('clean:    p50=${pc['p50']}us p95=${pc['p95']}us p99=${pc['p99']}us '
      'mean=${meanClean.toStringAsFixed(1)}us');
  print('rollback: p50=${pr['p50']}us p95=${pr['p95']}us p99=${pr['p99']}us '
      'mean=${meanRollback.toStringAsFixed(1)}us');
  print('delta_p50=${pr['p50']! - pc['p50']!}us  '
      'delta_mean=${(meanRollback - meanClean).toStringAsFixed(1)}us  '
      '(= custo do ROLLBACK redundante por transação)');
}

class _Opts {
  final int reps;
  final int n;
  final int warmup;
  final int writes;
  final String outBase;
  _Opts(this.reps, this.n, this.warmup, this.writes, this.outBase);
}

_Opts _parseArgs(List<String> args) {
  var reps = 3;
  var n = 5000;
  var warmup = 500;
  var writes = 10;
  var outBase = 'tpcc-rollback-micro';
  for (var i = 0; i < args.length - 1; i++) {
    switch (args[i]) {
      case '--reps':
        reps = int.parse(args[i + 1]);
      case '--n':
        n = int.parse(args[i + 1]);
      case '--warmup':
        warmup = int.parse(args[i + 1]);
      case '--writes':
        writes = int.parse(args[i + 1]);
      case '--out-base':
        outBase = args[i + 1];
    }
  }
  return _Opts(reps, n, warmup, writes, outBase);
}
