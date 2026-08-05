/// Integration test for multi-read (ABI MINOR 2): executeMultiRead returns
/// N result sets in order, mid-batch error → abort, single non-regression.
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
      await exec.execute('DROP TABLE IF EXISTS mrkv');
      await exec.execute('CREATE TABLE mrkv (id INT PRIMARY KEY, v INT)');
      await exec.executeBatch([
        'INSERT INTO mrkv (id, v) VALUES (1, 10)',
        'INSERT INTO mrkv (id, v) VALUES (2, 20)',
        'INSERT INTO mrkv (id, v) VALUES (3, 30)',
      ]);
    });
  });

  tearDown(() async {
    if (reachable) await pool.close();
  });

  test('executeMultiRead returns N result sets in statement order', () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }
    final results = await withMysqlTransaction(pool, (exec) async {
      return exec.executeMultiRead([
        'SELECT v FROM mrkv WHERE id = 1',
        'SELECT v FROM mrkv WHERE id = 2',
        'SELECT id, v FROM mrkv WHERE id = 3',
        'SELECT COUNT(*) AS n FROM mrkv',
      ]);
    });
    try {
      expect(results, hasLength(4));
      expect(results[0].row(0).getInt('v'), 10);
      expect(results[1].row(0).getInt('v'), 20);
      expect(results[2].row(0).getInt('id'), 3);
      expect(results[2].row(0).getInt('v'), 30);
      expect(results[3].row(0).getInt('n'), 3);
    } finally {
      for (final r in results) {
        r.release();
      }
    }
  });

  test('mid-batch error aborts and rolls back', () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }
    await expectLater(
      withMysqlTransaction(pool, (exec) async {
        // 2nd statement references a non-existent column → error mid-read.
        await exec.executeMultiRead([
          'SELECT v FROM mrkv WHERE id = 1',
          'SELECT nope FROM mrkv WHERE id = 2',
          'SELECT v FROM mrkv WHERE id = 3',
        ]);
        await exec.executeBatch(['INSERT INTO mrkv (id, v) VALUES (9, 90)']);
      }),
      throwsA(anything),
    );
    // Row 9 must not have been committed.
    final has9 = await withMysqlTransaction(pool, (exec) async {
      final rs =
          await exec.execute('SELECT COUNT(*) AS n FROM mrkv WHERE id = 9');
      try {
        return rs.row(0).getInt('n')!;
      } finally {
        rs.release();
      }
    });
    expect(has9, 0, reason: 'transaction rolled back');
  });

  test('single execute still works (non-regression, chained poll_result)',
      () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }
    final v = await withMysqlTransaction<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT 6 * 7 AS n');
      try {
        return rs.row(0).getInt('n')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 42);
  });
}
