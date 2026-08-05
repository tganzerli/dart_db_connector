/// Integration tests for MySQL native error surfacing (ABI MINOR 3).
///
/// A failing query must throw a [QueryFailedException] carrying the REAL
/// libmysqlclient message + errno, not the old opaque "query failed or
/// connection error". Needs a reachable MySQL (127.0.0.1:3306, root/123,
/// db `teste`).
library;

import 'dart:ffi' as ffi;

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/domain/unit_of_work.dart'
    show QueryFailedException;
import 'package:dart_db_connector/src/mysql/mysql_query_executor.dart';
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

  test('unknown table → real message ("doesn\'t exist") + errno 1146',
      () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final exec = MysqlQueryExecutor(b, conn);
    try {
      await exec.execute('SELECT * FROM definitely_no_such_table_xyz');
      fail('expected QueryFailedException');
    } on QueryFailedException catch (e) {
      // Real libmysqlclient text, not the opaque fallback.
      expect(e.serverMessage, isNot('query failed or connection error'));
      expect(e.serverMessage!.toLowerCase(), contains("doesn't exist"));
      expect(e.code, 1146, reason: 'ER_NO_SUCH_TABLE');
    }
  });

  test('syntax error → real message + errno 1064', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final exec = MysqlQueryExecutor(b, conn);
    try {
      await exec.execute('SELCT bogus FROM');
      fail('expected QueryFailedException');
    } on QueryFailedException catch (e) {
      expect(e.serverMessage!.toLowerCase(), contains('sql syntax'));
      expect(e.code, 1064, reason: 'ER_PARSE_ERROR');
    }
  });

  test('a successful query after an error clears the error state', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final exec = MysqlQueryExecutor(b, conn);
    // Trigger an error first.
    try {
      await exec.execute('SELECT * FROM still_no_such_table_abc');
      fail('expected failure');
    } on QueryFailedException {
      // expected
    }
    // A subsequent success must not carry a stale error, and last_errno
    // resets (verified indirectly: the success returns a real row).
    final rs = await exec.execute('SELECT 1 AS ok');
    try {
      expect(rs.row(0).getInt('ok'), 1);
      expect(b.lastErrno(conn), 0, reason: 'error state reset on success');
    } finally {
      rs.release();
    }
  });
}
