/// Integration tests for the SQLite driver. Exercises the full
/// stack against a real on-disk WAL database (no server needed). Skips if
/// the native lib is not built.
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/bindings/sqlite_binding.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:test/test.dart';

void main() {
  SqliteBinding? binding;
  try {
    binding = SqliteBinding(loadNativeSqlite());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }

  if (binding == null) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_sqlite not available');
    });
    return;
  }

  final b = binding;
  late Directory dir;
  late SqliteConnectionPool pool;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sqlite_test_');
    pool = SqliteConnectionPool.withBinding(
      b,
      SqlitePoolConfig(path: '${dir.path}/t.db', maxSize: 2),
    );
    await pool.start();
  });

  tearDown(() async {
    await pool.close();
    dir.deleteSync(recursive: true);
  });

  Future<SqliteResultSet> runSql(String sql) async {
    final c = await pool.acquire();
    try {
      return await SqliteQueryExecutor(b, c.raw).execute(sql);
    } finally {
      await c.release();
    }
  }

  test('decode of every SQLite storage class', () async {
    (await runSql(
            'CREATE TABLE t (i INTEGER, r REAL, s TEXT, bl BLOB, n TEXT)'))
        .release();
    (await runSql("INSERT INTO t VALUES (42, 3.5, 'héllo', x'DEADBEEF', NULL)"))
        .release();
    final rs = await runSql('SELECT i, r, s, bl, n FROM t');
    try {
      final row = rs.row(0);
      expect(row.getInt('i'), 42);
      expect(row.getDouble('r'), 3.5);
      expect(row.getString('s'), 'héllo');
      expect(row['bl'], equals(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])));
      expect(row['n'], isNull);
    } finally {
      rs.release();
    }
  });

  test('transaction commit and rollback', () async {
    (await runSql('CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)'))
        .release();

    await withSqliteTransaction(pool, (exec) async {
      (await exec.execute('INSERT INTO kv VALUES (1, 10)')).release();
    });
    expect((await runSql('SELECT COUNT(*) c FROM kv')).row(0).getInt('c'), 1);

    // Rollback path: throw inside the transaction.
    await expectLater(
      withSqliteTransaction(pool, (exec) async {
        (await exec.execute('INSERT INTO kv VALUES (2, 20)')).release();
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect((await runSql('SELECT COUNT(*) c FROM kv')).row(0).getInt('c'), 1);
  });

  test('error propagation carries the real sqlite3 message', () async {
    try {
      await runSql('SELECT * FROM does_not_exist');
      fail('expected a QueryFailedException');
    } catch (e) {
      expect(e.toString(), contains('does_not_exist'));
    }
  });

  test('WAL: a second connection reads a committed write', () async {
    (await runSql('CREATE TABLE w (id INTEGER)')).release();
    final c1 = await pool.acquire();
    final c2 = await pool.acquire();
    try {
      (await SqliteQueryExecutor(b, c1.raw).execute('INSERT INTO w VALUES (7)'))
          .release();
      final rs =
          await SqliteQueryExecutor(b, c2.raw).execute('SELECT id FROM w');
      try {
        expect(rs.row(0).getInt('id'), 7);
      } finally {
        rs.release();
      }
    } finally {
      await c1.release();
      await c2.release();
    }
  });

  test('SqliteRepository<T,K> reuses the agnostic Repository contract',
      () async {
    (await runSql('CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT)'))
        .release();
    await withSqliteTransaction(pool, (exec) async {
      final repo = _PersonRepo(exec);
      await repo.insert(const _Person(1, 'Ada'));
      await repo.insert(const _Person(2, 'Grace'));
      expect((await repo.findById(1))!.name, 'Ada');
      expect(await repo.findAll(), hasLength(2));
      await repo.update(const _Person(1, 'Ada Lovelace'));
      expect((await repo.findById(1))!.name, 'Ada Lovelace');
      await repo.delete(2);
      expect(await repo.findById(2), isNull);
    });
  });

  // Composition parity with the PG executePipeline guard
  // (tpcc_persistence_regression_test.dart). Not a force-rollback
  // regression guard — the SQLite batch worker (sqlite_pool_worker.c:172)
  // issues no BEGIN/COMMIT/ROLLBACK, so that class of bug cannot occur
  // here; this pins the positive invariant that was otherwise untested:
  // executeBatch inside withSqliteTransaction (including several batches
  // in one transaction) persists on the outer commit.
  test(
      'executeBatch inside withSqliteTransaction persists on commit '
      '(composition parity with PG executePipeline)', () async {
    (await runSql('CREATE TABLE batch_txn (id INTEGER PRIMARY KEY, v INTEGER)'))
        .release();

    await withSqliteTransaction(pool, (exec) async {
      await exec.executeBatch([
        'INSERT INTO batch_txn VALUES (1, 10)',
        'INSERT INTO batch_txn VALUES (2, 20)',
      ]);
      // Second batch in the SAME transaction (parity with the PG
      // multi-batch case).
      await exec.executeBatch([
        'UPDATE batch_txn SET v = v + 1 WHERE id = 1',
        'DELETE FROM batch_txn WHERE id = 2',
      ]);
    });

    // Read back on another pooled connection (maxSize: 2; the WAL test
    // above already proves cross-connection visibility).
    final rs =
        await runSql('SELECT COUNT(*) AS c, MAX(v) AS mv FROM batch_txn');
    try {
      expect(rs.row(0).getInt('c'), 1);
      expect(rs.row(0).getInt('mv'), 11);
    } finally {
      rs.release();
    }
  });
}

class _Person {
  final int id;
  final String name;
  const _Person(this.id, this.name);
}

class _PersonRepo extends SqliteRepository<_Person, int> {
  _PersonRepo(SqliteQueryExecutor exec)
      : super(exec, (r) => _Person(r.getInt('id')!, r.getString('name')!));
  @override
  String get tableName => 'person';
  @override
  String get idColumn => 'id';
  @override
  String selectAllSql() => 'SELECT id, name FROM person';
  @override
  String selectByIdSql(int id) => 'SELECT id, name FROM person WHERE id = $id';
  @override
  String insertSql(_Person p) =>
      "INSERT INTO person (id, name) VALUES (${p.id}, '${p.name}')";
  @override
  String updateSql(_Person p) =>
      "UPDATE person SET name = '${p.name}' WHERE id = ${p.id}";
  @override
  String deleteSql(int id) => 'DELETE FROM person WHERE id = $id';
}
