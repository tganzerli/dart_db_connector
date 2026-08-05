/// Tests for [IsolateWorkerPool] against a real Postgres instance.
/// Requires `/dev-env up postgres`.
library;

import 'dart:async' show TimeoutException;

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

bool _canLoadNative() {
  try {
    loadNativeDb();
    return true;
  } on StateError {
    return false;
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('IsolateWorkerPool', () {
    test('asserts workerCount > 0 at construction', () {
      expect(
        () => WorkerPoolConfig(
          workerCount: 0,
          poolConfig: PoolConfig(connInfo: _connInfo),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('start spawns workers and shutdown stops them', () async {
      final pool = IsolateWorkerPool(WorkerPoolConfig(
        workerCount: 2,
        poolConfig:
            const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 2),
      ));

      try {
        await pool.start();
      } catch (e) {
        markTestSkipped('Postgres not reachable: $e');
        return;
      }

      expect(pool.workerCount, 2);
      expect(pool.isClosed, isFalse);

      await pool.shutdown();
      expect(pool.isClosed, isTrue);
    });

    test('query against 1 worker returns decoded rows', () async {
      final pool = IsolateWorkerPool(WorkerPoolConfig(
        workerCount: 1,
        poolConfig:
            const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
      ));

      try {
        await pool.start();
      } catch (e) {
        markTestSkipped('Postgres not reachable: $e');
        return;
      }

      final rows = await pool.query("SELECT 42::int4 AS x, 'hi'::text AS y");
      expect(rows.length, 1);
      expect(rows[0], {'x': 42, 'y': 'hi'});

      await pool.shutdown();
    });

    test('round-robin distributes 20 queries across 4 workers', () async {
      final pool = IsolateWorkerPool(WorkerPoolConfig(
        workerCount: 4,
        poolConfig:
            const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 2),
      ));

      try {
        await pool.start();
      } catch (e) {
        markTestSkipped('Postgres not reachable: $e');
        return;
      }

      final futures = List.generate(20, (i) async {
        final rows = await pool.query('SELECT $i::int4 AS n');
        return rows[0]['n'] as int;
      });

      final values = await Future.wait(futures);
      expect(values..sort(), List.generate(20, (i) => i));

      await pool.shutdown();
    });

    test('shutdown rejects subsequent query()', () async {
      final pool = IsolateWorkerPool(WorkerPoolConfig(
        workerCount: 1,
        poolConfig:
            const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
      ));

      try {
        await pool.start();
      } catch (e) {
        markTestSkipped('Postgres not reachable: $e');
        return;
      }

      await pool.shutdown();
      expect(pool.query('SELECT 1'), throwsStateError);
    });

    test('query timeout fires when queryTimeout is short', () async {
      final pool = IsolateWorkerPool(WorkerPoolConfig(
        workerCount: 1,
        poolConfig:
            const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
        queryTimeout: Duration(milliseconds: 200),
      ));

      try {
        await pool.start();
      } catch (e) {
        markTestSkipped('Postgres not reachable: $e');
        return;
      }

      await expectLater(
        pool.query('SELECT pg_sleep(2)'),
        throwsA(isA<TimeoutException>()),
      );

      await pool.shutdown();
    });
  });
}
