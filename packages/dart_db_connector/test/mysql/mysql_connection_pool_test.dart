/// Integration test for [MysqlConnectionPool].
///
/// Requires the dev database (docker/mysql). Skips at runtime when the
/// native lib or MySQL is unavailable.
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/native/mysql_native_pool.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:dart_db_connector/src/pool/mysql_connection_pool.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

const _config = MysqlPoolConfig(
  host: '127.0.0.1',
  port: 3306,
  user: 'root',
  password: '123',
  database: 'teste',
  minSize: 3,
  maxSize: 3,
  acquireTimeout: Duration(seconds: 2),
);

void main() {
  MysqlBinding? binding;
  try {
    binding = MysqlBinding(loadNativeMysql());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
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

  // Runs a query on a pooled conn and returns the first cell as a string.
  Future<String> queryOneCell(MysqlPooledConnection c, String sql) async {
    final rp = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    try {
      final ok = b.poolSubmitQuery(c.raw, sqlPtr, rp.sendPort.nativePort, 0);
      expect(ok, 1);
      final code = await rp.first as int;
      expect(code, MysqlWorkerPortCode.ok);
      final res = b.pollResult(c.raw);
      final ptr = b.rawValue(res, 0, 0);
      final len = b.rawLength(res, 0, 0);
      final s = String.fromCharCodes(Uint8List.fromList(ptr.asTypedList(len)));
      b.clearResult(res);
      return s;
    } finally {
      malloc.free(sqlPtr);
      rp.close();
    }
  }

  MysqlConnectionPool newPool() => MysqlConnectionPool.withBinding(b, _config);

  test('start opens maxSize conns eagerly; acquire/release round-trips',
      () async {
    final pool = newPool();
    try {
      await pool.start();
    } on MysqlNativePoolStartupException {
      markTestSkipped('MySQL not reachable — run docker compose up mysql');
      return;
    }

    expect(pool.idle, 3, reason: 'all maxSize=3 conns warm');
    expect(pool.borrowed, 0);

    final c = await pool.acquire();
    expect(pool.borrowed, 1);
    expect(await queryOneCell(c, 'SELECT 7 * 6'), '42');
    await c.release();
    expect(pool.borrowed, 0);

    await pool.close();
    expect(pool.isClosed, isTrue);
  });

  test('acquire gate: the (maxSize+1)-th waits until a release', () async {
    final pool = newPool();
    try {
      await pool.start();
    } on MysqlNativePoolStartupException {
      markTestSkipped('MySQL not reachable');
      return;
    }

    final leased = [
      await pool.acquire(),
      await pool.acquire(),
      await pool.acquire(),
    ];
    expect(pool.borrowed, 3);
    expect(pool.idle, 0);

    // 4th acquire must block until we release one.
    var fourthGranted = false;
    final fourth = pool.acquire().then((c) {
      fourthGranted = true;
      return c;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fourthGranted, isFalse, reason: 'gated while pool is saturated');
    expect(pool.pending, 1);

    await leased.removeLast().release();
    final c4 = await fourth;
    expect(fourthGranted, isTrue);

    await c4.release();
    for (final c in leased) {
      await c.release();
    }
    await pool.close();
  });
}
