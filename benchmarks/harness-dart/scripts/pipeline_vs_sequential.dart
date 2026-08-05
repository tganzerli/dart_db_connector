/// Bench dedicado: pipeline mode vs sequential para o pattern
/// `BEGIN + 10× INSERT + COMMIT`. Mede TPS de transações/segundo.
///
/// **v1 limitation:** pipeline descarta result rows. Workload deste
/// bench é write-only (INSERT command tags), portanto não é afetado.
///
/// **Internal-API usage justified:** este bench precisa instanciar
/// `PostgresBinding` diretamente para chamar `executePipeline` na
/// camada FFI sem passar pelo pool. marcou os
/// símbolos `@internal`; suprimimos o warning intencionalmente.
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:io';

import 'package:dart_db_connector/dart_db_connector.dart';

import 'tpcc/conn_info.dart';

const _outputCsv = '../docker/bench/outputs/legacy/pipeline-vs-sequential.csv';
const _outputSvg = '../docker/bench/outputs/legacy/pipeline-vs-sequential.svg';

const _reps = 3;
const _txCount = 1000;
const _opsPerTx = 10; // 10 INSERTs por transação
const _totalSqlOpsPerRep = _txCount * (_opsPerTx + 2); // +BEGIN +COMMIT

Future<void> _setup(PostgresConnectionPool pool) async {
  await withTransaction(pool, (exec) async {
    await exec.execute('DROP TABLE IF EXISTS bench_pipeline');
    await exec.execute('CREATE TABLE bench_pipeline ('
        'rep int4 NOT NULL, tx int4 NOT NULL, n int4 NOT NULL, '
        "payload text NOT NULL, PRIMARY KEY (rep, tx, n))");
  });
}

Future<int> _runSequential(
    PostgresConnectionPool pool, int rep, int txCount) async {
  final sw = Stopwatch()..start();
  for (var t = 0; t < txCount; t++) {
    await withTransaction(pool, (exec) async {
      for (var i = 0; i < _opsPerTx; i++) {
        await exec.execute(
            "INSERT INTO bench_pipeline (rep, tx, n, payload) "
            "VALUES ($rep, $t, $i, 'p${t}_$i')");
      }
    });
  }
  sw.stop();
  return sw.elapsedMicroseconds;
}

Future<int> _runPipeline(
    PostgresConnectionPool pool, int rep, int txCount) async {
  final sw = Stopwatch()..start();
  for (var t = 0; t < txCount; t++) {
    final queries = [
      for (var i = 0; i < _opsPerTx; i++)
        "INSERT INTO bench_pipeline (rep, tx, n, payload) "
            "VALUES ($rep, $t, $i, 'p${t}_$i')",
    ];
    await withPipelinedTransaction(pool, queries);
  }
  sw.stop();
  return sw.elapsedMicroseconds;
}

Future<void> main() async {
  // : simplified setup via the public API.
  final pool = PostgresConnectionPool(
    PoolConfig(connInfo: connInfo(), minSize: 1, maxSize: 1),
  );
  await pool.start();

  print('=== Pipeline vs Sequential ===');
  print('reps=$_reps, tx_count=$_txCount, ops_per_tx=$_opsPerTx');
  print('total SQL ops per rep: $_totalSqlOpsPerRep');

  final results = <Map<String, dynamic>>[];

  for (var rep = 1; rep <= _reps; rep++) {
    print('\n--- rep $rep ---');

    // Sequential
    await _setup(pool);
    print('[sequential] running $_txCount tx × $_opsPerTx ops...');
    final seqUs = await _runSequential(pool, rep, _txCount);
    final seqTps = _txCount * 1000000 / seqUs;
    final seqUsPerTx = seqUs / _txCount;
    print('  sequential: ${(seqUs / 1000).toStringAsFixed(0)}ms total, '
        '${seqTps.toStringAsFixed(1)} tps, '
        '${seqUsPerTx.toStringAsFixed(0)}us/tx');
    results.add({
      'rep': rep,
      'mode': 'sequential',
      'total_us': seqUs,
      'tps': seqTps,
      'us_per_tx': seqUsPerTx,
    });

    // Pipeline
    await _setup(pool);
    print('[pipeline] running $_txCount tx × $_opsPerTx ops...');
    final pipeUs = await _runPipeline(pool, rep, _txCount);
    final pipeTps = _txCount * 1000000 / pipeUs;
    final pipeUsPerTx = pipeUs / _txCount;
    print('  pipeline:   ${(pipeUs / 1000).toStringAsFixed(0)}ms total, '
        '${pipeTps.toStringAsFixed(1)} tps, '
        '${pipeUsPerTx.toStringAsFixed(0)}us/tx');
    print('  speedup: ${(pipeTps / seqTps).toStringAsFixed(2)}×');
    results.add({
      'rep': rep,
      'mode': 'pipeline',
      'total_us': pipeUs,
      'tps': pipeTps,
      'us_per_tx': pipeUsPerTx,
    });
  }

  await pool.close();

  // CSV
  final csv = StringBuffer();
  csv.writeln('rep,mode,total_us,tps,us_per_tx');
  for (final r in results) {
    csv.writeln('${r['rep']},${r['mode']},${r['total_us']},'
        '${(r['tps'] as double).toStringAsFixed(2)},'
        '${(r['us_per_tx'] as double).toStringAsFixed(2)}');
  }
  File(_outputCsv).writeAsStringSync(csv.toString());
  print('\n[csv] $_outputCsv');

  // Summary
  final seqTpsList =
      results.where((r) => r['mode'] == 'sequential').map((r) => r['tps'] as double).toList();
  final pipeTpsList =
      results.where((r) => r['mode'] == 'pipeline').map((r) => r['tps'] as double).toList();
  final seqMean = seqTpsList.reduce((a, b) => a + b) / seqTpsList.length;
  final pipeMean = pipeTpsList.reduce((a, b) => a + b) / pipeTpsList.length;
  final speedup = pipeMean / seqMean;

  print('\n=== Resumo ===');
  print('sequential TPS médio: ${seqMean.toStringAsFixed(1)}');
  print('pipeline TPS médio:   ${pipeMean.toStringAsFixed(1)}');
  print('speedup pipeline/sequential: ${speedup.toStringAsFixed(2)}×');

  // SVG
  File(_outputSvg).writeAsStringSync(_renderSvg(results, seqMean, pipeMean));
  print('[svg] $_outputSvg');
}

String _renderSvg(List<Map<String, dynamic>> results, double seqMean,
    double pipeMean) {
  const w = 900;
  const h = 500;
  const margin = 80;

  final maxY = seqMean > pipeMean ? seqMean * 1.2 : pipeMean * 1.2;
  final chartTop = 70.0;
  final chartBottom = h - 100.0;
  final chartH = chartBottom - chartTop;

  final svg = StringBuffer();
  svg.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h" font-family="system-ui,-apple-system,sans-serif" font-size="12">');
  svg.writeln('<rect width="$w" height="$h" fill="white"/>');
  svg.writeln(
      '<text x="${w / 2}" y="28" text-anchor="middle" font-size="18" font-weight="bold">Pipeline mode vs Sequential — TPS</text>');
  svg.writeln(
      '<text x="${w / 2}" y="48" text-anchor="middle" font-size="11" fill="#555">BEGIN + 10× INSERT + COMMIT · 1000 tx × 3 reps · macOS arm64 · Docker Postgres</text>');

  for (var i = 0; i <= 5; i++) {
    final y = chartBottom - (i / 5) * chartH;
    final v = (i / 5 * maxY).round();
    svg.writeln('<line x1="$margin" y1="$y" x2="${w - margin}" y2="$y" stroke="#eee"/>');
    svg.writeln(
        '<text x="${margin - 6}" y="${y + 4}" text-anchor="end" fill="#666">${v} TPS</text>');
  }

  const barW = 80.0;
  final centerLeft = (w - 2 * barW - 100) / 2;
  final centerRight = centerLeft + barW + 100;

  final seqH = (seqMean / maxY) * chartH;
  final pipeH = (pipeMean / maxY) * chartH;

  svg.writeln(
      '<rect x="$centerLeft" y="${chartBottom - seqH}" width="$barW" height="$seqH" fill="#e53935"/>');
  svg.writeln(
      '<text x="${centerLeft + barW / 2}" y="${chartBottom - seqH - 6}" text-anchor="middle" font-size="14" font-weight="bold">${seqMean.toStringAsFixed(0)}</text>');
  svg.writeln(
      '<text x="${centerLeft + barW / 2}" y="${chartBottom + 20}" text-anchor="middle">sequential</text>');

  svg.writeln(
      '<rect x="$centerRight" y="${chartBottom - pipeH}" width="$barW" height="$pipeH" fill="#43a047"/>');
  svg.writeln(
      '<text x="${centerRight + barW / 2}" y="${chartBottom - pipeH - 6}" text-anchor="middle" font-size="14" font-weight="bold">${pipeMean.toStringAsFixed(0)}</text>');
  svg.writeln(
      '<text x="${centerRight + barW / 2}" y="${chartBottom + 20}" text-anchor="middle">pipeline</text>');

  final speedup = pipeMean / seqMean;
  svg.writeln(
      '<text x="${w / 2}" y="${chartBottom + 50}" text-anchor="middle" font-size="14" font-weight="bold" fill="${speedup >= 1 ? '#43a047' : '#e53935'}">speedup: ${speedup.toStringAsFixed(2)}×</text>');

  svg.writeln(
      '<line x1="$margin" y1="$chartBottom" x2="${w - margin}" y2="$chartBottom" stroke="#333"/>');

  svg.writeln('</svg>');
  return svg.toString();
}
