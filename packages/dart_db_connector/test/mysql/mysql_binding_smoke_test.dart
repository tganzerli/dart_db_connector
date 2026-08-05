/// End-to-end smoke test for the MySQL FFI binding.
///
/// Exercises the whole native + binding stack against a live MySQL:
/// loadNativeMysql (resolver + ABI check) → MysqlBinding (every symbol
/// resolves) → initDartApi → pool_create → acquire → submit_query →
/// Native Port notification → poll_result → zero-copy inspection.
///
/// Requires the dev database: `docker compose -f docker/mysql/... up -d`.
/// Skips itself at runtime when the native lib or MySQL is unavailable.
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  MysqlBinding? binding;
  try {
    binding = MysqlBinding(loadNativeMysql());
  } on StateError {
    binding = null;
  }

  if (binding == null) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_mysql not available — build native/c/');
    });
    return;
  }

  final b = binding;

  test('binding resolves all symbols and initializes the Dart Native API', () {
    expect(b.initDartApi(ffi.NativeApi.initializeApiDLData), 0);
  });

  test('SELECT round-trip: create → acquire → submit → notify → decode',
      () async {
    b.initDartApi(ffi.NativeApi.initializeApiDLData);

    final host = '127.0.0.1'.toNativeUtf8();
    final user = 'root'.toNativeUtf8();
    final pass = '123'.toNativeUtf8();
    final db = 'teste'.toNativeUtf8();
    final pool = b.poolCreate(host, user, pass, db, 3306, 1, 2, 5000);
    malloc.free(host);
    malloc.free(user);
    malloc.free(pass);
    malloc.free(db);

    if (pool == ffi.nullptr) {
      markTestSkipped('MySQL not reachable — run docker compose up mysql');
      return;
    }

    try {
      final conn = b.poolAcquire(pool, 5000);
      expect(conn, isNot(ffi.nullptr));

      final rp = ReceivePort();
      final sql = "SELECT 1 + 1 AS two, 'hi' AS greeting".toNativeUtf8();
      final dispatched =
          b.poolSubmitQuery(conn, sql, rp.sendPort.nativePort, 0);
      malloc.free(sql);
      expect(dispatched, 1, reason: 'dispatch accepted');

      final code = await rp.first as int;
      rp.close();
      expect(code, 1, reason: 'WORKER_PORT_OK');

      final result = b.pollResult(conn);
      expect(result, isNot(ffi.nullptr));

      expect(b.rowCount(result), 1);
      expect(b.colCount(result), 2);
      expect(b.fieldName(result, 0).toDartString(), 'two');
      expect(b.fieldName(result, 1).toDartString(), 'greeting');

      // Zero-copy cell reads (text protocol → ASCII bytes).
      String cell(int row, int col) {
        final ptr = b.rawValue(result, row, col);
        final len = b.rawLength(result, row, col);
        final bytes = Uint8List.fromList(ptr.asTypedList(len));
        return String.fromCharCodes(bytes);
      }

      expect(cell(0, 0), '2');
      expect(cell(0, 1), 'hi');

      b.clearResult(result);
      b.poolRelease(pool, conn);
    } finally {
      b.poolDestroy(pool);
    }
  });
}
