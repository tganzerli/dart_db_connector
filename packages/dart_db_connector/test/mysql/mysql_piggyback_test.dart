/// Integration tests for the MySQL BEGIN-piggyback (deferred BEGIN fused into
/// the transaction's first statement) and the non-transactional fast-path
/// [withMysqlConnection]. Counterpart of the PostgreSQL P5 behaviour.
///
/// Key invariants exercised:
///  * The fused BEGIN really opens a transaction — a body that writes then
///    rolls back must NOT persist (proves BEGIN was sent, not autocommit).
///  * A committed transaction persists; an empty transaction commits cleanly
///    (BEGIN fused into the COMMIT).
///  * The fusion works whether the first statement is `execute`,
///    `executeMultiRead` or `executeBatch`, and a mid-batch error still rolls
///    back.
///  * [withMysqlConnection] runs without a transaction (autocommit): a write
///    persists with no explicit commit.
library;

import 'dart:ffi' as ffi;

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/mysql/with_mysql_connection.dart';
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
      await exec.execute('DROP TABLE IF EXISTS pgb');
      await exec.execute('CREATE TABLE pgb (id INT PRIMARY KEY, v INT)');
    });
  });

  tearDown(() async {
    if (reachable) await pool.close();
  });

  Future<Map<int, int>> readAll() async {
    return withMysqlConnection(pool, (exec) async {
      final rs = await exec.execute('SELECT id, v FROM pgb ORDER BY id');
      try {
        return {for (final r in rs.rows) r.getInt('id')!: r.getInt('v')!};
      } finally {
        rs.release();
      }
    });
  }

  // ── BEGIN-piggyback ──────────────────────────────────────────────────

  test('committed transaction persists (fused BEGIN + batch + COMMIT)',
      () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    await withMysqlTransaction(pool, (exec) async {
      await exec.executeBatch([
        'INSERT INTO pgb (id, v) VALUES (1, 10)',
        'INSERT INTO pgb (id, v) VALUES (2, 20)',
      ]);
    });
    expect(await readAll(), {1: 10, 2: 20});
  });

  test('the fused BEGIN really opens a txn — rollback undoes the write',
      () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    // If BEGIN had NOT been sent, the insert would autocommit and survive the
    // rollback. It must not.
    await expectLater(
      withMysqlTransaction(pool, (exec) async {
        await exec.executeBatch(['INSERT INTO pgb (id, v) VALUES (1, 10)']);
        throw StateError('force rollback');
      }),
      throwsA(anything),
    );
    expect(await readAll(), isEmpty,
        reason: 'fused BEGIN + rollback → no write');
  });

  test('empty transaction commits cleanly (BEGIN fused into COMMIT)', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    // Body executes nothing; commit must still succeed and leave the
    // connection healthy for the next dispatch.
    await withMysqlTransaction(pool, (exec) async {});
    // Connection still usable:
    final v = await withMysqlConnection<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT 6 * 7 AS n');
      try {
        return rs.row(0).getInt('n')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 42);
  });

  test('first statement = execute (read): fused BEGIN returns the row',
      () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final v = await withMysqlTransaction<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT 3 * 14 AS n');
      try {
        return rs.row(0).getInt('n')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 42);
  });

  test('first statement = executeMultiRead: fused BEGIN keeps 1:1 indexing',
      () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    await withMysqlConnection(pool, (exec) async {
      await exec.executeBatch([
        'INSERT INTO pgb (id, v) VALUES (1, 11)',
        'INSERT INTO pgb (id, v) VALUES (2, 22)',
      ]);
    });
    final results = await withMysqlTransaction(pool, (exec) {
      return exec.executeMultiRead([
        'SELECT v FROM pgb WHERE id = 1',
        'SELECT v FROM pgb WHERE id = 2',
      ]);
    });
    try {
      expect(results, hasLength(2));
      expect(results[0].row(0).getInt('v'), 11);
      expect(results[1].row(0).getInt('v'), 22);
    } finally {
      for (final r in results) {
        r.release();
      }
    }
  });

  test('mid-batch error inside a fused-BEGIN txn rolls back', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    await expectLater(
      withMysqlTransaction(pool, (exec) async {
        await exec.executeBatch([
          'INSERT INTO pgb (id, v) VALUES (5, 50)',
          'INSERT INTO pgb (id, v) VALUES (5, 50)', // duplicate PK → error
        ]);
      }),
      throwsA(anything),
    );
    expect(await readAll(), isEmpty, reason: 'error rolled the txn back');
  });

  // ── withMysqlConnection (non-transactional fast-path) ────────────────

  test('withMysqlConnection reads without a transaction', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final v = await withMysqlConnection<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT 9 * 5 AS n');
      try {
        return rs.row(0).getInt('n')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 45);
  });

  test('withMysqlConnection write autocommits (no explicit commit)', () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    await withMysqlConnection(pool, (exec) async {
      await exec.execute('INSERT INTO pgb (id, v) VALUES (7, 70)');
    });
    // No transaction was opened; the write is visible on a fresh read.
    expect(await readAll(), {7: 70});
  });

  test('withMysqlConnection + executeMultiRead returns N sets in order',
      () async {
    if (!reachable) return markTestSkipped('MySQL not reachable');
    final results = await withMysqlConnection(pool, (exec) {
      return exec.executeMultiRead([
        'SELECT 1 AS a',
        'SELECT 2 AS a',
        'SELECT 3 AS a',
      ]);
    });
    try {
      expect(results.map((r) => r.row(0).getInt('a')), [1, 2, 3]);
    } finally {
      for (final r in results) {
        r.release();
      }
    }
  });
}
