/// Integration tests for the SQLite perf primitives (batch, multi-read,
/// sync fast-path — ABI MINOR 1/2). Runs against a real WAL file.
library;

import 'dart:ffi' as ffi;
import 'dart:io';

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
    dir = Directory.systemTemp.createTempSync('sqlite_perf_');
    pool = SqliteConnectionPool.withBinding(
        b, SqlitePoolConfig(path: '${dir.path}/t.db', maxSize: 2));
    await pool.start();
  });

  tearDown(() async {
    await pool.close();
    dir.deleteSync(recursive: true);
  });

  test('executeBatch applies N writes in one round-trip', () async {
    final c = await pool.acquire();
    try {
      final ex = SqliteQueryExecutor(b, c.raw);
      (await ex.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)'))
          .release();
      await ex.executeBatch([
        'INSERT INTO kv VALUES (1, 10)',
        'INSERT INTO kv VALUES (2, 20)',
        'INSERT INTO kv VALUES (3, 30)',
      ]);
      final rs = await ex.execute('SELECT COUNT(*) c FROM kv');
      expect(rs.row(0).getInt('c'), 3);
      rs.release();
    } finally {
      await c.release();
    }
  });

  test('executeBatch mid-batch error aborts (transaction rolls back)',
      () async {
    final c = await pool.acquire();
    try {
      final ex = SqliteQueryExecutor(b, c.raw);
      (await ex.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY)')).release();
    } finally {
      await c.release();
    }
    await expectLater(
      withSqliteTransaction(pool, (ex) async {
        await ex.executeBatch([
          'INSERT INTO kv VALUES (1)',
          'INSERT INTO kv VALUES (bad_column)', // error
          'INSERT INTO kv VALUES (2)',
        ]);
      }),
      throwsA(anything),
    );
    final c2 = await pool.acquire();
    try {
      final rs = await SqliteQueryExecutor(b, c2.raw)
          .execute('SELECT COUNT(*) c FROM kv');
      expect(rs.row(0).getInt('c'), 0, reason: 'rolled back');
      rs.release();
    } finally {
      await c2.release();
    }
  });

  test('executeMultiRead returns N result sets in order', () async {
    final c = await pool.acquire();
    try {
      final ex = SqliteQueryExecutor(b, c.raw);
      (await ex.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)'))
          .release();
      await ex.executeBatch([
        'INSERT INTO kv VALUES (1, 10)',
        'INSERT INTO kv VALUES (2, 20)',
      ]);
      final results = await ex.executeMultiRead([
        'SELECT v FROM kv WHERE id=1',
        'SELECT v FROM kv WHERE id=2',
        'SELECT COUNT(*) n FROM kv',
      ]);
      try {
        expect(results, hasLength(3));
        expect(results[0].row(0).getInt('v'), 10);
        expect(results[1].row(0).getInt('v'), 20);
        expect(results[2].row(0).getInt('n'), 2);
      } finally {
        for (final r in results) {
          r.release();
        }
      }
    } finally {
      await c.release();
    }
  });

  test('executeSync returns the correct result and single path not regressed',
      () async {
    final c = await pool.acquire();
    try {
      final ex = SqliteQueryExecutor(b, c.raw);
      (await ex.execute('CREATE TABLE kv (id INTEGER PRIMARY KEY, v TEXT)'))
          .release();
      (await ex.execute("INSERT INTO kv VALUES (1, 'sync')")).release();

      // Synchronous fast-path.
      final rs = ex.executeSync('SELECT v FROM kv WHERE id=1');
      expect(rs.row(0).getString('v'), 'sync');
      rs.release();

      // Alternate async → sync → async on the same conn (no corruption).
      final a = await ex.execute('SELECT id FROM kv WHERE id=1');
      expect(a.row(0).getInt('id'), 1);
      a.release();
      final s = ex.executeSync('SELECT COUNT(*) n FROM kv');
      expect(s.row(0).getInt('n'), 1);
      s.release();
    } finally {
      await c.release();
    }
  });

  test('executeSync surfaces the real sqlite3 error', () async {
    final c = await pool.acquire();
    try {
      final ex = SqliteQueryExecutor(b, c.raw);
      expect(
        () => ex.executeSync('SELECT * FROM missing'),
        throwsA(predicate((e) => e.toString().contains('missing'))),
      );
    } finally {
      await c.release();
    }
  });
}
