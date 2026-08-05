/// Isolated decode micro-benchmark (task P3, 2026-07-29).
///
/// Measures only the **L6 decode** cost — no network, no Docker, no strict isolation.
/// It runs one query, RETAINS the resulting `PGresult`, and then loops
/// over the decode work in-process, isolating two sub-costs the
/// codec-plan task (P2) targets:
///
///  1. **metadata build** — what `ResultSet.fromResult` does per query:
///     `getColCount` + `getRowCount` + per-column `getFieldName`
///     (`toDartString`) + `getFieldType`.
///  2. **cell decode** — per-cell `ResultRow[col]`: `getRawValue` +
///     `getRawLength` + `decodeByOid`.
///
/// Together they approximate `decode_us` from the attribution harness,
/// but split into "shape setup" vs "per-cell" so P2 knows which to
/// attack. Reported per-resultset, per-row, per-cell (comparable across
/// shapes).
///
/// The retained `PGresult` is freed exactly once (`clearResult` at the
/// end), so there is no finalizer double-free from the decode loop.
///
/// **P2 A/B (`--plan-cache on|off`):** the codec-plan task reuses this
/// harness to compare the old decode path against the new one on the same
/// machine. `off` replicates the pre-codec-plan bodies (metadata:
/// per-col `toDartString` + name→index map; cell: `asTypedList` +
/// `decodeByOid` switch); `on` exercises the codec plan (metadata:
/// `PostgresPlanCache` hit; cell: per-column decoder vector + pointer
/// parsers). Both isolate the decode call (no `ResultRow` allocation) for
/// a clean A1/A2/A4 delta.
///
/// Run (from `benchmarks/`):
///   dart run scripts/micro_decode.dart --shapes narrow,wide1,wide100 \
///     --n 200000 --plan-cache on \
///     --out outputs/decode-plan-codec-cache-on.csv
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:dart_db_connector/src/bindings/postgres_binding.dart';
// ignore: implementation_imports
import 'package:dart_db_connector/src/decoder/decode_plan.dart';
// ignore: implementation_imports
import 'package:dart_db_connector/src/decoder/_decoder.dart' show decodeByOid;
import 'package:dart_db_connector/src/native/native_pool.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:ffi/ffi.dart';

import 'tpcc/conn_info.dart';

String _wideSql(int n) =>
    'SELECT g AS c_int4, g::bigint AS c_int8, g::text AS c_text, '
    '(g*1.5)::float8 AS c_f8, (g%2=0) AS c_bool, md5(g::text) AS c_md5, '
    'now() AS c_ts, (g*1.01)::numeric(12,2) AS c_num, '
    "('row-'||g) AS c_label, (g*3)::int AS c_int4b, "
    '(g/2.0)::float8 AS c_f8b, (g%7)::int AS c_mod '
    'FROM generate_series(1, $n) g';

final Map<String, String> _shapes = {
  'narrow': 'SELECT g AS id, (g*7)::int AS n FROM generate_series(1,1) g',
  'wide1': _wideSql(1),
  'wide100': _wideSql(100),
};

/// Target total cell-decodes per shape so wide/narrow are comparable.
const _cellBudget = 5000000;

Map<String, String> _parseArgs(List<String> args) {
  final m = <String, String>{
    'shapes': 'wide1,wide100',
    'n': '100000',
    'plan-cache': 'on',
    'out': 'outputs/driver-us-attribution-decode.csv',
  };
  for (var i = 0; i < args.length - 1; i += 2) {
    m[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  return m;
}

Future<void> main(List<String> args) async {
  final p = _parseArgs(args);
  final shapeNames = p['shapes']!.split(',');
  final maxIters = int.parse(p['n']!);
  final usePlanCache = p['plan-cache']! == 'on';
  final outPath = p['out']!;
  print('plan-cache: ${usePlanCache ? "ON (new path)" : "OFF (old path)"}');

  final lib = loadNativeDb();
  final binding = PostgresBinding(lib);
  if (binding.initDartApi(ffi.NativeApi.initializeApiDLData) != 0) {
    throw StateError('initDartApi failed');
  }
  final pool = NativePool.create(
    binding: binding,
    conninfo: connInfo(),
    maxSize: 1,
    acquireTimeout: const Duration(seconds: 5),
  );
  final conn = pool.acquire().ptr;

  print('=== isolated decode micro-bench ===\n');
  final rows = <String>[
    'shape,rows,cols,iters,plan_cache,metadata_ns,cell_ns,per_resultset_ns'
  ];

  for (final shapeName in shapeNames) {
    final sql = _shapes[shapeName];
    if (sql == null) throw ArgumentError('unknown shape: $shapeName');
    final r = await _measureShape(binding, conn, shapeName, sql, maxIters,
        usePlanCache: usePlanCache);
    rows.add(r);
  }

  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString('${rows.join('\n')}\n');
  print('\nwrote ${rows.length - 1} rows → $outPath');
}

Future<String> _measureShape(PostgresBinding binding,
    ffi.Pointer<ffi.Void> conn, String shapeName, String sql, int maxIters,
    {required bool usePlanCache}) async {
  // Run the query once and RETAIN its PGresult.
  final sqlPtr = sql.toNativeUtf8();
  final port = ReceivePort();
  final receiver = port.asBroadcastStream();
  binding.poolSubmitQuery(conn, sqlPtr, port.sendPort.nativePort, 0);
  await receiver.first;
  malloc.free(sqlPtr);
  final result = binding.pollResult(conn);
  if (result == ffi.nullptr) {
    port.close();
    throw StateError('no result for $shapeName');
  }

  final cols = binding.getColCount(result);
  final rowCount = binding.getRowCount(result);
  final cellsPerIter = (rowCount * cols).clamp(1, 1 << 30);
  final iters = (_cellBudget ~/ cellsPerIter).clamp(1000, maxIters);

  // Per-column OIDs (needed by the OLD cell-decode path).
  final oids = [for (var c = 0; c < cols; c++) binding.getFieldType(result, c)];

  // ── (1) metadata build ──
  //   ON  : PostgresPlanCache hit (fingerprint + byte-verify, no alloc).
  //   OFF : old ResultSet.fromResult body (per-col toDartString + map).
  final cache = PostgresPlanCache();
  void metaStep() {
    if (usePlanCache) {
      cache.planFor(binding, result, cols, false); // miss once, then hits
    } else {
      _metadataBuildOld(binding, result, cols);
    }
  }

  for (var w = 0; w < 1000; w++) {
    metaStep();
  }
  final swMeta = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    metaStep();
  }
  swMeta.stop();
  final metaNs = swMeta.elapsedMicroseconds * 1000 / iters;

  // ── (2) cell decode (N passes over all cells) ──
  //   ON  : plan decoder vector (A2) + pointer parsers (A4).
  //   OFF : old ResultRow[] path (getRawValue+getRawLength+asTypedList+switch).
  final plan = DecodePlan.buildPostgres(binding, result, cols, binary: false);
  void cellStep() {
    if (usePlanCache) {
      _decodeAllCellsNew(binding, result, plan, rowCount, cols);
    } else {
      _decodeAllCellsOld(binding, result, oids, rowCount, cols);
    }
  }

  for (var w = 0; w < 100; w++) {
    cellStep();
  }
  final swCell = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    cellStep();
  }
  swCell.stop();
  final cellNs = swCell.elapsedMicroseconds * 1000 / (iters * cellsPerIter);

  // Drain the rest of the chain and free the retained result exactly once.
  binding.clearResult(result);
  while (binding.pollResult(conn) != ffi.nullptr) {}
  port.close();

  final tag = usePlanCache ? 'on' : 'off';
  final perResultset = metaNs + cellNs * cellsPerIter;
  print(
      '--- $shapeName (${rowCount}x$cols, iters=$iters, plan-cache=$tag) ---');
  print('  metadata build : ${metaNs.toStringAsFixed(1)} ns/query');
  print('  cell decode    : ${cellNs.toStringAsFixed(1)} ns/cell');
  print('  per resultset  : ${perResultset.toStringAsFixed(1)} ns '
      '(${(perResultset / 1000).toStringAsFixed(2)} us)\n');

  return '$shapeName,$rowCount,$cols,$iters,$tag,${metaNs.toStringAsFixed(1)},'
      '${cellNs.toStringAsFixed(2)},${perResultset.toStringAsFixed(1)}';
}

/// OLD metadata path: replicates the pre-codec-plan `ResultSet.fromResult`
/// body (per-col `toDartString` + OID read + name→index map), without
/// attaching a finalizer.
void _metadataBuildOld(
    PostgresBinding binding, ffi.Pointer<ffi.Void> result, int cols) {
  binding.getRowCount(result);
  final names = <String>[];
  final nameToIndex = <String, int>{};
  for (var c = 0; c < cols; c++) {
    final name = binding.getFieldName(result, c).toDartString();
    names.add(name);
    binding.getFieldType(result, c);
    nameToIndex[name] = c;
  }
}

/// NEW cell-decode path: per-column decoder resolved once (A2), parsed
/// straight from the pointer (A4). Isolates the decode call itself (no
/// ResultRow allocation), matching the OLD helper's granularity.
void _decodeAllCellsNew(PostgresBinding binding, ffi.Pointer<ffi.Void> result,
    DecodePlan plan, int rowCount, int cols) {
  for (var r = 0; r < rowCount; r++) {
    for (var c = 0; c < cols; c++) {
      final ptr = binding.getRawValue(result, r, c);
      if (ptr == ffi.nullptr) continue;
      final len = binding.getRawLength(result, r, c);
      plan.decoders[c](ptr, len);
    }
  }
}

/// OLD cell-decode path: getRawValue + getRawLength + asTypedList +
/// `decodeByOid` switch + intermediate String — the pre-codec-plan
/// `ResultRow[]` body.
void _decodeAllCellsOld(PostgresBinding binding, ffi.Pointer<ffi.Void> result,
    List<int> oids, int rowCount, int cols) {
  for (var r = 0; r < rowCount; r++) {
    for (var c = 0; c < cols; c++) {
      final ptr = binding.getRawValue(result, r, c);
      if (ptr == ffi.nullptr) continue;
      final len = binding.getRawLength(result, r, c);
      decodeByOid(ptr.asTypedList(len), oids[c]);
    }
  }
}
