/// Correctness tests for the MySQL codec plan (perf-v2 Etapa B).
///
/// The plan must be a pure optimisation: every value it decodes must equal
/// what the canonical [decodeByFieldType] produces for the same bytes, and
/// the shape cache must never alias two different shapes. Integration tests
/// need a reachable MySQL (127.0.0.1:3306, root/123, db `teste`).
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/decoder/mysql_decode_plan.dart';
import 'package:dart_db_connector/src/decoder/mysql_decoder.dart';
import 'package:dart_db_connector/src/decoder/mysql_result_row.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  MysqlBinding? binding;
  try {
    binding = MysqlBinding(loadNativeMysql());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }

  if (binding == null) {
    test('skipped (libnative_mysql not built)', () {
      markTestSkipped('libnative_mysql not available');
    });
    return;
  }
  final b = binding;

  // ── Pool + single connection shared across the integration tests ──
  ffi.Pointer<ffi.Void> pool = ffi.nullptr;
  ffi.Pointer<ffi.Void> conn = ffi.nullptr;
  var reachable = false;

  setUpAll(() {
    final host = '127.0.0.1'.toNativeUtf8();
    final user = 'root'.toNativeUtf8();
    final pass = '123'.toNativeUtf8();
    final db = 'teste'.toNativeUtf8();
    pool = b.poolCreate(host, user, pass, db, 3306, 1, 1, 5000);
    malloc.free(host);
    malloc.free(user);
    malloc.free(pass);
    malloc.free(db);
    if (pool == ffi.nullptr) return;
    conn = b.poolAcquire(pool, 5000);
    reachable = conn != ffi.nullptr;
  });

  tearDownAll(() {
    if (pool != ffi.nullptr) {
      if (conn != ffi.nullptr) b.poolRelease(pool, conn);
      b.poolDestroy(pool);
    }
  });

  // Runs [sql] on the shared conn, returns the raw result handle. Caller
  // owns it (must clearResult).
  Future<ffi.Pointer<ffi.Void>> runSelect(String sql) async {
    final s = sql.toNativeUtf8();
    final rp = ReceivePort();
    b.poolSubmitQuery(conn, s, rp.sendPort.nativePort, 0);
    malloc.free(s);
    final rc = await rp.first as int;
    rp.close();
    expect(rc, 1, reason: 'query failed: $sql');
    return b.pollResult(conn);
  }

  test('plan decoders equal the canonical decodeByFieldType, cell by cell',
      () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final res = await runSelect(
      "SELECT CAST(42 AS SIGNED) AS a, CAST(-7 AS SIGNED) AS b, "
      "CAST(0 AS SIGNED) AS c, CAST(9000000000 AS SIGNED) AS big, "
      "3.5 AS d, 'açaí' AS s, DATE('2026-07-24') AS day, NULL AS nada",
    );
    final rs = MysqlResultSet.fromResult(b, res);
    try {
      expect(rs.rowCount, 1);
      final row = rs.row(0);
      for (var col = 0; col < rs.colCount; col++) {
        final planValue = row[col];
        // Oracle: decode the same raw bytes with the canonical decoder.
        final ptr = b.rawValue(res, 0, col);
        final Object? oracle;
        if (ptr == ffi.nullptr) {
          oracle = null;
        } else {
          final len = b.rawLength(res, 0, col);
          oracle =
              decodeByFieldType(ptr.asTypedList(len), rs.columnTypeCodes[col]);
        }
        expect(planValue, oracle,
            reason: 'col $col (${rs.columnNames[col]}) diverged');
      }
      // Spot-check the int fast-path values explicitly.
      expect(row.getInt('a'), 42);
      expect(row.getInt('b'), -7);
      expect(row.getInt('c'), 0);
      expect(row.getInt('big'), 9000000000);
      expect(row['nada'], isNull);
    } finally {
      rs.release();
    }
  });

  test('cache: same shape hits once, different names do not alias', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final cache = MysqlPlanCache();

    final r1 = await runSelect('SELECT 1 AS x, 2 AS y');
    final p1 = cache.planFor(b, r1, b.colCount(r1));
    final p1b = cache.planFor(b, r1, b.colCount(r1));
    expect(identical(p1, p1b), isTrue, reason: 'same handle → same plan');
    expect(cache.size, 1);
    b.clearResult(r1);

    // Same types + same names, different query text → still a hit.
    final r2 = await runSelect('SELECT 10 AS x, 20 AS y');
    cache.planFor(b, r2, b.colCount(r2));
    expect(cache.size, 1, reason: 'identical shape must reuse the plan');
    b.clearResult(r2);

    // Same types, DIFFERENT names → a new plan (byte-exact name check).
    final r3 = await runSelect('SELECT 1 AS p, 2 AS q');
    cache.planFor(b, r3, b.colCount(r3));
    expect(cache.size, 2, reason: 'different names must not alias');
    b.clearResult(r3);
  });

  test('multi-row decode via plan stays correct', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final res = await runSelect(
      'SELECT n, n * -1 AS neg FROM '
      '(SELECT 1 AS n UNION SELECT 2 UNION SELECT 3) t ORDER BY n',
    );
    final rs = MysqlResultSet.fromResult(b, res);
    try {
      expect(rs.rowCount, 3);
      expect([for (final r in rs.rows) r.getInt('n')], [1, 2, 3]);
      expect([for (final r in rs.rows) r.getInt('neg')], [-1, -2, -3]);
    } finally {
      rs.release();
    }
  });

  test('usePlanCache:false builds an equivalent fresh plan', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final res = await runSelect("SELECT 5 AS n, 'hi' AS s");
    final rs = MysqlResultSet.fromResult(b, res, usePlanCache: false);
    try {
      expect(rs.row(0).getInt('n'), 5);
      expect(rs.row(0).getString('s'), 'hi');
      expect(rs.columnNames, ['n', 's']);
    } finally {
      rs.release();
    }
  });
}
