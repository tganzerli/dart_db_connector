/// Isolated MySQL decode micro-benchmark (perf-v2 Etapa B, codec plan).
///
/// Mirror of `micro_decode.dart` (Postgres) over the MySQL binding. Measures
/// only the **decode** cost — no network in the loop, no Docker, no strict isolation. It
/// runs one query per shape, RETAINS the result handle, then loops the decode
/// work in-process, isolating the two sub-costs the codec plan targets:
///
///  1. **metadata build** — per query: `MysqlResultSet.fromResult`'s work.
///     `off` = old path (per-col `fieldName().toDartString()` + `fieldType()`
///     + name→index map). `on` = `MysqlPlanCache` hit (fingerprint + byte
///     name check, zero-alloc).
///  2. **cell decode** — per cell: `off` = `rawValue`+`rawLength`+
///     `asTypedList`+`decodeByFieldType` switch; `on` = per-column decoder
///     vector + int-from-pointer parser.
///
/// Both isolate the decode call (no `MysqlResultRow` allocation) for a clean
/// A1/A2/A4 delta.
///
/// Run (from `benchmarks/`, MySQL on 127.0.0.1:3306 with a seeded `world`):
///   export DART_DB_CONNECTOR_MYSQL_NATIVE_LIB_PATH=/abs/build-macos/libnative_mysql.dylib
///   dart run scripts/micro_decode_mysql.dart --shapes narrow,wide1,wide100 \
///     --n 200000 --plan-cache on --out outputs/mysql-codec-plan-on.csv
// ignore_for_file: invalid_use_of_internal_member
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
// ignore: implementation_imports
import 'package:dart_db_connector/src/decoder/mysql_decode_plan.dart';
// ignore: implementation_imports
import 'package:dart_db_connector/src/decoder/mysql_decoder.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:ffi/ffi.dart';

const _narrowSql = 'SELECT id, randomnumber FROM world WHERE id = 1';

String _wideSql(int n) =>
    'WITH RECURSIVE seq(g) AS (SELECT 1 UNION ALL SELECT g+1 FROM seq WHERE g < $n) '
    'SELECT g AS c_int4, CAST(g AS SIGNED) AS c_int8, CAST(g AS CHAR) AS c_text, '
    'g*1.5 AS c_f8, (g%2=0) AS c_bool, MD5(CAST(g AS CHAR)) AS c_md5, '
    'NOW() AS c_ts, CAST(g*1.01 AS DECIMAL(12,2)) AS c_num, '
    "CONCAT('row-', g) AS c_label, g*3 AS c_int4b, g/2.0 AS c_f8b, g%7 AS c_mod "
    'FROM seq';

String _sqlFor(String shape) => switch (shape) {
      'narrow' => _narrowSql,
      'wide1' => _wideSql(1),
      'wide100' => _wideSql(100),
      _ => throw ArgumentError('unknown shape: $shape'),
    };

void main(List<String> args) async {
  final opts = _parseArgs(args);
  final b = MysqlBinding(loadNativeMysql());
  b.initDartApi(ffi.NativeApi.initializeApiDLData);

  final host = '127.0.0.1'.toNativeUtf8();
  final user = 'root'.toNativeUtf8();
  final pass = '123'.toNativeUtf8();
  final db = 'teste'.toNativeUtf8();
  final pool = b.poolCreate(host, user, pass, db, 3306, 1, 1, 5000);
  malloc.free(host);
  malloc.free(user);
  malloc.free(pass);
  malloc.free(db);
  if (pool == ffi.nullptr) {
    stderr.writeln('[fatal] MySQL pool create failed (is it up on :3306?)');
    exit(1);
  }
  final conn = b.poolAcquire(pool, 5000);
  if (conn == ffi.nullptr) {
    stderr.writeln('[fatal] acquire failed');
    exit(1);
  }

  final rows = <String>[
    'shape,mode,rows,cols,metadata_ns_per_query,cell_ns_per_cell,resultset_ns'
  ];

  for (final shape in opts.shapes) {
    final res = await _runSelect(b, conn, _sqlFor(shape));
    final cols = b.colCount(res);
    final nrows = b.rowCount(res);
    stdout.writeln('[$shape] cols=$cols rows=$nrows mode=${opts.mode} n=${opts.n}');

    final metaNs = _benchMetadata(b, res, cols, opts);
    final cellNs = _benchCells(b, res, cols, nrows, opts);
    final perResultset = metaNs + cellNs * cols * nrows;
    rows.add('$shape,${opts.mode},$nrows,$cols,'
        '${metaNs.toStringAsFixed(1)},${cellNs.toStringAsFixed(2)},'
        '${perResultset.toStringAsFixed(0)}');
    stdout.writeln('  metadata=${metaNs.toStringAsFixed(1)} ns/query  '
        'cell=${cellNs.toStringAsFixed(2)} ns/cell  '
        'resultset=${perResultset.toStringAsFixed(0)} ns');

    b.clearResult(res);
  }

  b.poolRelease(pool, conn);
  b.poolDestroy(pool);

  // Read the sink so the decode loops cannot be optimised away.
  if (_sinkAcc == 0x7fffffffffffffff) stderr.writeln('');

  if (opts.out != null) {
    File(opts.out!).writeAsStringSync(rows.join('\n') + '\n');
    stdout.writeln('[out] ${opts.out}');
  }
}

/// Metadata-build ns/query. `off` replicates the pre-plan `fromResult` loop;
/// `on` measures a `MysqlPlanCache` hit (pre-warmed).
double _benchMetadata(
    MysqlBinding b, ffi.Pointer<ffi.Void> res, int cols, _Opts opts) {
  const warmup = 1000;
  if (opts.mode == 'on') {
    final cache = MysqlPlanCache();
    cache.planFor(b, res, cols); // warm the single plan → subsequent = hits
    for (var i = 0; i < warmup; i++) {
      cache.planFor(b, res, cols);
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < opts.n; i++) {
      cache.planFor(b, res, cols);
    }
    sw.stop();
    return sw.elapsedMicroseconds * 1000 / opts.n;
  } else {
    for (var i = 0; i < warmup; i++) {
      _buildMetadataOld(b, res, cols);
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < opts.n; i++) {
      _buildMetadataOld(b, res, cols);
    }
    sw.stop();
    return sw.elapsedMicroseconds * 1000 / opts.n;
  }
}

/// The pre-codec-plan `MysqlResultSet.fromResult` metadata work.
void _buildMetadataOld(MysqlBinding b, ffi.Pointer<ffi.Void> res, int cols) {
  final names = <String>[];
  final types = <int>[];
  for (var c = 0; c < cols; c++) {
    names.add(b.fieldName(res, c).toDartString());
    types.add(b.fieldType(res, c));
  }
  final nameToIndex = <String, int>{
    for (var i = 0; i < names.length; i++) names[i]: i
  };
  // Touch the map so the compiler cannot elide the build.
  if (nameToIndex.length != cols || types.length != cols) {
    throw StateError('unreachable');
  }
}

/// Cell-decode ns/cell over all cells of the result. `off` = asTypedList +
/// `decodeByFieldType` switch; `on` = per-column decoder vector.
double _benchCells(MysqlBinding b, ffi.Pointer<ffi.Void> res, int cols,
    int nrows, _Opts opts) {
  const warmup = 100;
  final totalCells = cols * nrows;
  if (totalCells == 0) return 0;
  // Iterations scaled so total cell decodes ≈ opts.n regardless of shape.
  final iters = (opts.n / totalCells).ceil().clamp(1, opts.n);

  Object? sink;
  if (opts.mode == 'on') {
    final plan = MysqlDecodePlan.buildMysql(b, res, cols);
    for (var w = 0; w < warmup; w++) {
      for (var r = 0; r < nrows; r++) {
        for (var c = 0; c < cols; c++) {
          sink = _decodeOnePlan(b, res, plan, r, c);
        }
      }
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < iters; i++) {
      for (var r = 0; r < nrows; r++) {
        for (var c = 0; c < cols; c++) {
          sink = _decodeOnePlan(b, res, plan, r, c);
        }
      }
    }
    sw.stop();
    _blackhole(sink);
    return sw.elapsedMicroseconds * 1000 / (iters * totalCells);
  } else {
    final codes = [for (var c = 0; c < cols; c++) b.fieldType(res, c)];
    for (var w = 0; w < warmup; w++) {
      for (var r = 0; r < nrows; r++) {
        for (var c = 0; c < cols; c++) {
          sink = _decodeOneOld(b, res, codes[c], r, c);
        }
      }
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < iters; i++) {
      for (var r = 0; r < nrows; r++) {
        for (var c = 0; c < cols; c++) {
          sink = _decodeOneOld(b, res, codes[c], r, c);
        }
      }
    }
    sw.stop();
    _blackhole(sink);
    return sw.elapsedMicroseconds * 1000 / (iters * totalCells);
  }
}

Object? _decodeOnePlan(MysqlBinding b, ffi.Pointer<ffi.Void> res,
    MysqlDecodePlan plan, int row, int col) {
  final ptr = b.rawValue(res, row, col);
  if (ptr == ffi.nullptr) return null;
  final len = b.rawLength(res, row, col);
  return plan.decoders[col](ptr, len);
}

Object? _decodeOneOld(MysqlBinding b, ffi.Pointer<ffi.Void> res, int code,
    int row, int col) {
  final ptr = b.rawValue(res, row, col);
  if (ptr == ffi.nullptr) return null;
  final len = b.rawLength(res, row, col);
  return decodeByFieldType(ptr.asTypedList(len), code);
}

int _sinkAcc = 0;
void _blackhole(Object? v) {
  if (v != null) _sinkAcc ^= v.hashCode;
}

Future<ffi.Pointer<ffi.Void>> _runSelect(
    MysqlBinding b, ffi.Pointer<ffi.Void> conn, String sql) async {
  final s = sql.toNativeUtf8();
  final rp = ReceivePort();
  b.poolSubmitQuery(conn, s, rp.sendPort.nativePort, 0);
  malloc.free(s);
  final rc = await rp.first as int;
  rp.close();
  if (rc != 1) throw StateError('query failed ($rc): $sql');
  return b.pollResult(conn);
}

class _Opts {
  final List<String> shapes;
  final int n;
  final String mode; // 'on' | 'off'
  final String? out;
  _Opts(this.shapes, this.n, this.mode, this.out);
}

_Opts _parseArgs(List<String> args) {
  var shapes = ['narrow', 'wide1', 'wide100'];
  var n = 200000;
  var mode = 'on';
  String? out;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--shapes':
        shapes = args[++i].split(',');
      case '--n':
        n = int.parse(args[++i]);
      case '--plan-cache':
        mode = args[++i];
      case '--out':
        out = args[++i];
    }
  }
  if (mode != 'on' && mode != 'off') {
    throw ArgumentError('--plan-cache must be on|off');
  }
  return _Opts(shapes, n, mode, out);
}
