/// Integration test for multi-statement batching (ABI MINOR 1):
/// executeBatch correctness, mid-batch error → rollback, single non-regression.
library;

import 'dart:ffi' as ffi;

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/mysql/with_mysql_transaction.dart';
import 'package:dart_db_connector/src/native/mysql_native_pool.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:dart_db_connector/src/pool/mysql_connection_pool.dart';
import 'package:test/test.dart';

const _config = MysqlPoolConfig(
  host: '127.0.0.1',
  user: 'root',
  password: '123',
  database: 'teste',
  maxSize: 2,
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
      markTestSkipped('libnative_mysql not available');
    });
    return;
  }

  final b = binding;
  late MysqlConnectionPool pool;
  var reachable = true;

  setUp(() async {
    pool = MysqlConnectionPool.withBinding(b, _config);
    try {
      await pool.start();
    } on MysqlNativePoolStartupException {
      reachable = false;
      return;
    }
    await withMysqlTransaction(pool, (exec) async {
      await exec.execute('DROP TABLE IF EXISTS kv');
      await exec.execute('CREATE TABLE kv (id INT PRIMARY KEY, v INT)');
    });
  });

  tearDown(() async {
    if (reachable) await pool.close();
  });

  Future<Map<int, int>> readAll() async {
    return withMysqlTransaction(pool, (exec) async {
      final rs = await exec.execute('SELECT id, v FROM kv ORDER BY id');
      try {
        return {for (final r in rs.rows) r.getInt('id')!: r.getInt('v')!};
      } finally {
        rs.release();
      }
    });
  }

  test('executeBatch applies all writes in one round-trip', () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }
    await withMysqlTransaction(pool, (exec) async {
      await exec.executeBatch([
        'INSERT INTO kv (id, v) VALUES (1, 10)',
        'INSERT INTO kv (id, v) VALUES (2, 20)',
        'UPDATE kv SET v = 99 WHERE id = 1',
      ]);
    });
    expect(await readAll(), {1: 99, 2: 20});
  });

  test('mid-batch error aborts and the whole transaction rolls back', () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }
    await expectLater(
      withMysqlTransaction(pool, (exec) async {
        await exec.executeBatch([
          'INSERT INTO kv (id, v) VALUES (3, 30)',
          'INSERT INTO kv (id, v) VALUES (3, 30)', // duplicate PK → error
          'INSERT INTO kv (id, v) VALUES (4, 40)',
        ]);
      }),
      throwsA(anything),
    );
    expect(await readAll(), isEmpty, reason: 'batch failure rolled back');
  });

  test('single execute still works (non-regression with MULTI_STATEMENTS on)',
      () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }
    final v = await withMysqlTransaction<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT 7 * 6 AS n');
      try {
        return rs.row(0).getInt('n')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 42);
  });
}
