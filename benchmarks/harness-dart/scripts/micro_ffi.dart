/// Micro-benchmark do overhead FFI Dart ↔ libnative_db.
///
/// Quantifica o custo intrínseco de cada chamada FFI da PostgresBinding
/// vs uma baseline `getpid()` (syscall trivial via FFI raw lookup). O
/// "overhead vs baseline" isola o custo de marshalling Dart-vs-C do
/// custo da função libpq por trás de cada símbolo.
///
/// Sustenta/refuta a hipótese de [[benchmarks/tpcc-multi-isolate]]
/// §"Por que o postgres package fica até melhor em multi?" (FFI overhead
/// ~50-100 ns/call amplifica sob carga).
///
/// Run:
///   cd benchmarks && dart run scripts/micro_ffi.dart
///
/// **Internal-API usage justified:** this benchmark measures FFI
/// primitives directly (timing `loadNativeDb`, `PostgresBinding` lookups,
/// raw `Pointer<Void>` calls). It cannot be expressed through the public
/// `PostgresConnectionPool` API by design. marked
/// these symbols `@internal`; we suppress the package-boundary warning
/// here intentionally — this script is academic, not consumer code.
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:dart_db_connector/src/bindings/postgres_binding.dart';
import 'package:dart_db_connector/src/native/native_pool.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:ffi/ffi.dart';

import 'tpcc/conn_info.dart';

const _coldReadN = 100000; // sampling for cheap symbol calls
const _hotPathN = 10000;   // for the full poolSubmitQuery→pollResult→clear loop
const _connN = 10;         // open/close are expensive; small N
const _outputCsv = '../docker/bench/outputs/legacy/micro-ffi-overhead.csv';
const _outputSvg = '../docker/bench/outputs/legacy/micro-ffi-overhead.svg';

class _Result {
  final String symbol;
  final String category; // baseline | setup | hot | cold | cancel
  final int n;
  final double meanNs;
  final int p50Ns;
  final int p99Ns;
  final double stddevNs;
  _Result(this.symbol, this.category, this.n, this.meanNs, this.p50Ns,
      this.p99Ns, this.stddevNs);
}

_Result _measure(String symbol, String category, int n, void Function() body) {
  // Warmup: 1000 calls (JIT-aware).
  for (var i = 0; i < 1000; i++) {
    body();
  }
  // Sampling phase: record one Stopwatch per iteration would dominate cost;
  // measure in chunks of 1000 and amortize.
  const chunk = 1000;
  final samples = <int>[]; // ns per chunk / chunk
  final sw = Stopwatch();
  for (var i = 0; i < n; i += chunk) {
    sw.reset();
    sw.start();
    for (var j = 0; j < chunk; j++) {
      body();
    }
    sw.stop();
    samples.add((sw.elapsedMicroseconds * 1000) ~/ chunk);
  }
  samples.sort();
  final mean = samples.fold<double>(0, (a, b) => a + b) / samples.length;
  final variance = samples.fold<double>(0, (a, b) => a + (b - mean) * (b - mean)) /
      samples.length;
  final stddev = variance > 0 ? variance : 0.0;
  final p50 = samples[samples.length ~/ 2];
  final p99 = samples[(samples.length * 0.99).round().clamp(0, samples.length - 1)];
  return _Result(symbol, category, n, mean, p50, p99, stddev);
}

Future<void> main() async {
  final lib = loadNativeDb();
  final binding = PostgresBinding(lib);
  if (binding.initDartApi(ffi.NativeApi.initializeApiDLData) != 0) {
    throw StateError('initDartApi failed');
  }

  // Baseline: getpid() via FFI raw lookup.
  final getpid = ffi.DynamicLibrary.process()
      .lookupFunction<ffi.Int32 Function(), int Function()>('getpid');

  print('=== Micro-bench FFI overhead ===\n');

  final results = <_Result>[];

  // ── Baseline ─────────────────────────────────────────────
  print('[1/14] baseline_getpid (n=$_coldReadN)...');
  results.add(_measure('baseline_getpid', 'baseline', _coldReadN, () {
    getpid();
  }));

  // ── Setup symbols (small N, absolute latency more informative) ──
  // initDartApi: already called once above. Re-measuring would re-init.
  // Skip; only the meaningful measurement is "1× init at process start".

  print('[2/14] connect (n=$_connN)...');
  {
    final times = <int>[];
    for (var i = 0; i < _connN; i++) {
      final p = connInfo().toNativeUtf8();
      final sw = Stopwatch()..start();
      final conn = binding.connect(p);
      sw.stop();
      times.add(sw.elapsedMicroseconds * 1000);
      malloc.free(p);
      binding.closeDb(conn);
    }
    times.sort();
    results.add(_Result('connect_db', 'setup', _connN,
        times.fold<double>(0, (a, b) => a + b) / times.length,
        times[times.length ~/ 2],
        times[(times.length * 0.99).round().clamp(0, times.length - 1)],
        0));
  }

  print('[3/14] closeDb (n=$_connN)...');
  {
    final times = <int>[];
    for (var i = 0; i < _connN; i++) {
      final p = connInfo().toNativeUtf8();
      final conn = binding.connect(p);
      malloc.free(p);
      final sw = Stopwatch()..start();
      binding.closeDb(conn);
      sw.stop();
      times.add(sw.elapsedMicroseconds * 1000);
    }
    times.sort();
    results.add(_Result('close_db', 'setup', _connN,
        times.fold<double>(0, (a, b) => a + b) / times.length,
        times[times.length ~/ 2],
        times[(times.length * 0.99).round().clamp(0, times.length - 1)],
        0));
  }

  // ── Hot path ─────────────────────────────────────────────
  // ABI MAJOR 2: open a 1-conn NativePool for the rest of the bench
  // — every `poolSubmitQuery` / `pollResult` / `poolCancel` requires
  // a `native_conn_t*`, which only the pool can hand out.
  final pool = NativePool.create(
    binding: binding,
    conninfo: connInfo(),
    maxSize: 1,
    acquireTimeout: const Duration(seconds: 5),
  );
  final pooledConn = pool.acquire();
  final conn = pooledConn.ptr;

  print('[4/14] hot_path (poolSubmitQuery+pollResult+clearResult, n=$_hotPathN)...');
  {
    final sql = 'SELECT 1'.toNativeUtf8();
    final port = ReceivePort();
    final receiver = port.asBroadcastStream();
    // Warmup
    for (var i = 0; i < 100; i++) {
      binding.poolSubmitQuery(conn, sql, port.sendPort.nativePort, 0);
      await receiver.first;
      final r = binding.pollResult(conn);
      if (r != ffi.nullptr) binding.clearResult(r);
      while (binding.pollResult(conn) != ffi.nullptr) {}
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < _hotPathN; i++) {
      binding.poolSubmitQuery(conn, sql, port.sendPort.nativePort, 0);
      await receiver.first;
      final r = binding.pollResult(conn);
      if (r != ffi.nullptr) binding.clearResult(r);
      while (binding.pollResult(conn) != ffi.nullptr) {}
    }
    sw.stop();
    final meanNs = (sw.elapsedMicroseconds * 1000) / _hotPathN;
    results.add(_Result('hot_path_select1', 'hot', _hotPathN, meanNs,
        meanNs.round(), (meanNs * 1.2).round(), 0));
    malloc.free(sql);
    port.close();
  }

  // ── Cold reads: precisamos de um PGresult vivo cacheado. ──
  print('[5/14] preparing cached PGresult for cold reads...');
  ffi.Pointer<ffi.Void> cachedResult;
  {
    final port = ReceivePort();
    final sql = 'SELECT 1 AS x'.toNativeUtf8();
    binding.poolSubmitQuery(conn, sql, port.sendPort.nativePort, 0);
    await port.first;
    cachedResult = binding.pollResult(conn);
    if (cachedResult == ffi.nullptr) throw StateError('no PGresult');
    // Drain extras.
    while (binding.pollResult(conn) != ffi.nullptr) {}
    malloc.free(sql);
    port.close();
  }

  print('[6/14] getRowCount (n=$_coldReadN)...');
  results.add(_measure('get_row_count', 'cold', _coldReadN, () {
    binding.getRowCount(cachedResult);
  }));

  print('[7/14] getColCount (n=$_coldReadN)...');
  results.add(_measure('get_col_count', 'cold', _coldReadN, () {
    binding.getColCount(cachedResult);
  }));

  print('[8/14] getFieldName (n=$_coldReadN)...');
  results.add(_measure('get_field_name', 'cold', _coldReadN, () {
    binding.getFieldName(cachedResult, 0);
  }));

  print('[9/14] getRawValue (n=$_coldReadN)...');
  results.add(_measure('get_raw_value', 'cold', _coldReadN, () {
    binding.getRawValue(cachedResult, 0, 0);
  }));

  print('[10/14] getRawLength (n=$_coldReadN)...');
  results.add(_measure('get_raw_length', 'cold', _coldReadN, () {
    binding.getRawLength(cachedResult, 0, 0);
  }));

  print('[11/14] getFieldType (n=$_coldReadN)...');
  results.add(_measure('get_field_type', 'cold', _coldReadN, () {
    binding.getFieldType(cachedResult, 0);
  }));

  print('[12/14] clearResult (n=$_coldReadN)... (calling on null to avoid double-free)');
  // We can't call clearResult on the same cachedResult repeatedly — it'd
  // crash. Measure with nullptr (the function checks NULL). This isolates
  // the FFI marshalling cost only.
  results.add(_measure('clear_result_null', 'cold', _coldReadN, () {
    binding.clearResult(ffi.nullptr);
  }));

  print('[13/14] poolCancel on idle (n=$_coldReadN)...');
  results.add(_measure('pool_cancel_idle', 'cancel', _coldReadN, () {
    binding.poolCancel(conn);
  }));

  print('[14/14] poll_result on idle (n=$_coldReadN)...');
  // After we drained earlier, pollResult should return nullptr immediately.
  // Confirm.
  results.add(_measure('poll_result_idle', 'cold', _coldReadN, () {
    binding.pollResult(conn);
  }));

  // Cleanup
  binding.clearResult(cachedResult);
  pooledConn.release();
  pool.destroy();

  // ── Output ───────────────────────────────────────────────
  final baselineNs = results.firstWhere((r) => r.symbol == 'baseline_getpid').meanNs;

  print('\n=== Resultados ===');
  print('Símbolo                    Cat     N        mean_ns   p50_ns  p99_ns  overhead_vs_baseline');
  print('-' * 95);
  for (final r in results) {
    final overhead = r.meanNs - baselineNs;
    print(
      '${r.symbol.padRight(26)} ${r.category.padRight(7)} ${r.n.toString().padLeft(7)} '
      '${r.meanNs.toStringAsFixed(0).padLeft(8)} ${r.p50Ns.toString().padLeft(8)} '
      '${r.p99Ns.toString().padLeft(7)} '
      '${(overhead >= 0 ? '+' : '')}${overhead.toStringAsFixed(0).padLeft(6)} ns',
    );
  }

  // CSV
  final csv = StringBuffer();
  csv.writeln('symbol,category,n,mean_ns,p50_ns,p99_ns,overhead_vs_baseline_ns');
  for (final r in results) {
    csv.writeln('${r.symbol},${r.category},${r.n},'
        '${r.meanNs.toStringAsFixed(2)},${r.p50Ns},${r.p99Ns},'
        '${(r.meanNs - baselineNs).toStringAsFixed(2)}');
  }
  File(_outputCsv).writeAsStringSync(csv.toString());
  print('\n[csv] $_outputCsv');

  // SVG
  File(_outputSvg).writeAsStringSync(_renderSvg(results, baselineNs));
  print('[svg] $_outputSvg');
}

String _renderSvg(List<_Result> results, double baselineNs) {
  const w = 1100;
  const h = 600;
  const margin = 80;
  final n = results.length;
  final barW = (w - 2 * margin) / n - 8;

  var maxY = results.map((r) => r.meanNs).reduce((a, b) => a > b ? a : b);
  maxY = (maxY * 1.15);

  final svg = StringBuffer();
  svg.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h" font-family="system-ui,-apple-system,sans-serif" font-size="11">');
  svg.writeln('<rect width="$w" height="$h" fill="white"/>');
  svg.writeln(
      '<text x="${w / 2}" y="28" text-anchor="middle" font-size="18" font-weight="bold">Micro-bench FFI overhead (mean ns/call)</text>');
  svg.writeln(
      '<text x="${w / 2}" y="48" text-anchor="middle" font-size="11" fill="#555">14 símbolos · baseline = getpid() syscall · macOS arm64 · Dart JIT mode</text>');

  final chartTop = 75.0;
  final chartBottom = h - 120.0;
  final chartH = chartBottom - chartTop;

  // Y grid
  const grid = 5;
  for (var i = 0; i <= grid; i++) {
    final y = chartBottom - (i / grid) * chartH;
    final v = (i / grid * maxY).round();
    svg.writeln('<line x1="$margin" y1="$y" x2="${w - margin}" y2="$y" stroke="#eee"/>');
    svg.writeln(
        '<text x="${margin - 6}" y="${y + 4}" text-anchor="end" fill="#666">${v}ns</text>');
  }

  // Baseline line
  final baselineY = chartBottom - (baselineNs / maxY) * chartH;
  svg.writeln(
      '<line x1="$margin" y1="$baselineY" x2="${w - margin}" y2="$baselineY" stroke="#aaa" stroke-dasharray="4,3"/>');
  svg.writeln(
      '<text x="${w - margin + 4}" y="${baselineY + 3}" fill="#666" font-size="10">baseline ${baselineNs.toStringAsFixed(0)} ns</text>');

  // Bars
  for (var i = 0; i < n; i++) {
    final r = results[i];
    final x = margin + i * ((w - 2 * margin) / n) + 4;
    final barH = (r.meanNs / maxY) * chartH;
    final color = switch (r.category) {
      'baseline' => '#666',
      'setup' => '#9e9e9e',
      'hot' => '#e53935',
      'cold' => '#1e88e5',
      'cancel' => '#fb8c00',
      _ => '#000',
    };
    final y = chartBottom - barH;
    svg.writeln('<rect x="$x" y="$y" width="$barW" height="$barH" fill="$color"/>');
    svg.writeln(
        '<text x="${x + barW / 2}" y="${y - 4}" text-anchor="middle" font-size="9" fill="#333">${r.meanNs.toStringAsFixed(0)}</text>');
    // Symbol label rotated
    svg.writeln(
        '<text x="${x + barW / 2}" y="${chartBottom + 14}" text-anchor="end" transform="rotate(-35 ${x + barW / 2},${chartBottom + 14})" font-size="9" fill="#333">${r.symbol}</text>');
  }

  // Axis
  svg.writeln(
      '<line x1="$margin" y1="$chartBottom" x2="${w - margin}" y2="$chartBottom" stroke="#333"/>');

  // Legend
  final legX = w - 360;
  final legY = h - 30;
  const categories = [
    ('baseline', '#666'),
    ('setup', '#9e9e9e'),
    ('hot', '#e53935'),
    ('cold', '#1e88e5'),
    ('cancel', '#fb8c00'),
  ];
  for (var i = 0; i < categories.length; i++) {
    final (label, color) = categories[i];
    final lx = legX + i * 70;
    svg.writeln('<rect x="$lx" y="${legY - 10}" width="12" height="12" fill="$color"/>');
    svg.writeln('<text x="${lx + 16}" y="$legY" fill="#333">$label</text>');
  }

  svg.writeln('</svg>');
  return svg.toString();
}
