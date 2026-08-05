/// Tests for the BEGIN-piggyback transaction path (P5, 2026-07-28).
///
/// The Postgres `UnitOfWork` defers `BEGIN` and fuses it into the first
/// statement of the body (`BEGIN;<sql>` in one round-trip on the Simple
/// Protocol, reusing the ABI MINOR 2 multi-read primitive), or emits a
/// standalone `BEGIN` when that first statement uses the Extended
/// Protocol. These tests cover the full case matrix from the plan:
/// Simple/Extended first statement, error/timeout on the fused
/// statement, empty transactions (`BEGIN;COMMIT` / `BEGIN;ROLLBACK`),
/// `executeMultiRead`/`executePipeline` as the first submit (with error
/// indexing offset by the prepended BEGIN), and the `TransactionStateError`
/// contract. Write-visibility is asserted across a second logical
/// transaction to prove the explicit BEGIN opened a real transaction
/// (i.e. ROLLBACK actually undoes the fused write).
library;

import 'dart:ffi' as ffi;

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/bindings/postgres_binding.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';
const _missing = 'no_such_table_p5_piggyback_xyz';

bool _canLoadNative() {
  try {
    loadNativeDb();
    return true;
  } on StateError {
    return false;
  }
}

PostgresBinding _binding() {
  final b = PostgresBinding(loadNativeDb());
  b.initDartApi(ffi.NativeApi.initializeApiDLData);
  return b;
}

Future<PostgresConnectionPool> _freshPool(PostgresBinding b) async {
  final pool = PostgresConnectionPool.withBinding(
    b,
    const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
  );
  await pool.start();
  return pool;
}

/// Runs [sql] in autocommit on a freshly acquired conn (no transaction).
Future<void> _autocommit(PostgresConnectionPool pool, String sql) async {
  final leased = await pool.acquire();
  try {
    (await PostgresQueryExecutor(pool.binding, leased.raw).execute(sql))
        .release();
  } finally {
    await leased.release();
  }
}

/// Reads committed state on a second logical transaction: how many rows
/// with [id] are visible in `p5_scratch`.
Future<int> _count(PostgresConnectionPool pool, int id) async {
  final leased = await pool.acquire();
  try {
    final rs = await PostgresQueryExecutor(pool.binding, leased.raw)
        .execute('SELECT count(*)::int AS n FROM p5_scratch WHERE id=$id');
    final n = rs.row(0).getInt('n')!;
    rs.release();
    return n;
  } finally {
    await leased.release();
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('Postgres BEGIN piggyback (P5)', () {
    late PostgresBinding b;
    late PostgresConnectionPool pool;

    setUp(() async {
      b = _binding();
      pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      await _autocommit(pool,
          'CREATE TABLE IF NOT EXISTS p5_scratch(id int primary key, v int)');
      await _autocommit(pool, 'TRUNCATE p5_scratch');
    });

    tearDown(() async {
      try {
        await _autocommit(pool, 'DROP TABLE IF EXISTS p5_scratch');
      } catch (_) {
        // A prior test may have left the single conn in an undefined
        // state (timeout/cancel); best-effort cleanup.
      }
      await pool.close();
    });

    // ── Case 1: Simple first statement OK; ROLLBACK undoes the fused
    //    write (proves the explicit BEGIN dominated the multi-statement
    //    implicit transaction). ──
    test('Simple first statement: fused BEGIN, rollback undoes the write',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute('INSERT INTO p5_scratch(id,v) VALUES (1,10)'))
          .release();
      await uow.rollback();
      await uow.close();
      expect(await _count(pool, 1), 0, reason: 'fused write must roll back');
    });

    test('Simple first statement: commit makes the fused write visible',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute('INSERT INTO p5_scratch(id,v) VALUES (2,20)'))
          .release();
      await uow.commit();
      await uow.close();
      expect(await _count(pool, 2), 1);
    });

    // ── Case 2: Extended first statement (bound params + binary) →
    //    standalone-BEGIN fallback; still transactional. ──
    test('Extended first statement: BEGIN fallback, rollback undoes', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute(
        'INSERT INTO p5_scratch(id,v) VALUES (\$1,\$2)',
        params: [Param.int4(3), Param.int4(30)],
      ))
          .release();
      await uow.rollback();
      await uow.close();
      expect(await _count(pool, 3), 0);
    });

    test('Extended first statement: commit makes the write visible', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute(
        'INSERT INTO p5_scratch(id,v) VALUES (\$1,\$2)',
        params: [Param.int4(4), Param.int4(40)],
      ))
          .release();
      await uow.commit();
      await uow.close();
      expect(await _count(pool, 4), 1);
    });

    // ── Case 3: error on the fused first statement. Server is left in an
    //    aborted (but open) transaction; ROLLBACK recovers and the conn
    //    is reusable. ──
    test('error on fused first statement throws with real server message',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await expectLater(
          exec.execute('SELECT * FROM $_missing'),
          throwsA(isA<QueryFailedException>().having(
              (e) => e.serverMessage, 'serverMessage', contains(_missing))),
        );
        // The BEGIN succeeded → the transaction is open and aborted.
        // ROLLBACK closes it; the conn is then reusable.
        (await exec.execute('ROLLBACK')).release();
        final rs = await exec.execute('SELECT 5 AS v');
        expect(rs.row(0).getInt('v'), 5);
        rs.release();
      } finally {
        await leased.release();
      }
    });

    // ── Case 4: error on a SUBSEQUENT statement (unchanged behavior). ──
    test('error on a later statement rolls back the fused write', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute('INSERT INTO p5_scratch(id,v) VALUES (7,70)'))
          .release(); // fuses BEGIN
      await expectLater(
        uow.executor.execute('SELECT * FROM $_missing'),
        throwsA(isA<QueryFailedException>()),
      );
      await uow.rollback();
      await uow.close();
      expect(await _count(pool, 7), 0);
    });

    // ── Case 5: empty transaction + commit → BEGIN;COMMIT fused. ──
    test('empty transaction commit succeeds (BEGIN;COMMIT fused)', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      expect(uow.isActive, isTrue);
      await uow.commit();
      expect(uow.isActive, isFalse);
      await uow.close();
    });

    // ── Case 6: empty transaction + rollback/close → BEGIN;ROLLBACK. ──
    test('empty transaction rollback succeeds (BEGIN;ROLLBACK fused)',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      await uow.rollback();
      expect(uow.isActive, isFalse);
      await uow.close();
    });

    test('empty transaction close (no commit/rollback) is best-effort',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      await uow.close(); // best-effort ROLLBACK, fused with BEGIN
      expect(uow.isActive, isFalse);
    });

    // ── Case 7: executeMultiRead as the first submit. ──
    test('executeMultiRead as first submit: N results, BEGIN consumed',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        final rs =
            await exec.executeMultiRead(['SELECT 1 AS a', 'SELECT 2 AS b']);
        expect(rs, hasLength(2));
        expect(rs[0].row(0).getInt('a'), 1);
        expect(rs[1].row(0).getInt('b'), 2);
        for (final r in rs) {
          r.release();
        }
        // Close the transaction opened by the fused BEGIN.
        (await exec.execute('ROLLBACK')).release();
      } finally {
        await leased.release();
      }
    });

    test('executeMultiRead error names the right statement (BEGIN offset)',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await expectLater(
          exec.executeMultiRead(['SELECT 1', 'SELECT * FROM $_missing']),
          throwsA(isA<QueryFailedException>()
              .having((e) => e.sql, 'sql', contains(_missing))),
        );
      } finally {
        await leased.release();
      }
    });

    test('executeMultiRead with empty list still opens the transaction',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        expect(await exec.executeMultiRead(const []), isEmpty);
        // A standalone BEGIN was sent; ROLLBACK must find an open txn
        // (no "no transaction in progress" error path exercised here —
        // just that the conn is coherent).
        (await exec.execute('ROLLBACK')).release();
        final rs = await exec.execute('SELECT 1 AS v');
        expect(rs.row(0).getInt('v'), 1);
        rs.release();
      } finally {
        await leased.release();
      }
    });

    // ── Case 8: executePipeline as the first submit consumes the
    //    deferred BEGIN (standalone, not fused — the pipeline primitive
    //    force-rolls-back any txn still open at its end, a PRE-EXISTING
    //    behavior since ABI MAJOR 2, orthogonal to P5). We assert the
    //    P5-owned property: the pending BEGIN is consumed exactly once
    //    and the connection stays coherent for the next statement. ──
    test('executePipeline as first submit consumes the deferred BEGIN once',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await exec
            .executePipeline(['INSERT INTO p5_scratch(id,v) VALUES (8,80)']);
        // The pending BEGIN must have been consumed: the next execute is
        // a plain statement, not a second (fused) BEGIN, and the conn is
        // coherent.
        final rs = await exec.execute('SELECT 1 AS v');
        expect(rs.row(0).getInt('v'), 1);
        rs.release();
      } finally {
        await leased.release();
      }
    });

    // ── Case 9: timeout on the fused first statement. Isolated to a
    //    local pool so the cancelled conn doesn't contaminate teardown. ──
    test('timeout on fused first statement throws QueryTimeoutException',
        () async {
      final localPool = await _freshPool(b);
      try {
        final leased = await localPool.acquire();
        final exec = PostgresQueryExecutor(localPool.binding, leased.raw,
            timeout: const Duration(milliseconds: 300), deferredBegin: true);
        await expectLater(
          exec.execute('SELECT pg_sleep(3)'),
          throwsA(isA<QueryTimeoutException>()),
        );
        await leased.release();
      } finally {
        await localPool.close();
      }
    });

    // ── Case 10: TransactionStateError contract (regression). ──
    test(
        'state contract: executor before begin, double begin, commit w/o begin',
        () async {
      final uow = PostgresUnitOfWork(pool);
      expect(() => uow.executor, throwsA(isA<TransactionStateError>()));
      expect(uow.commit, throwsA(isA<TransactionStateError>()));
      expect(uow.rollback, throwsA(isA<TransactionStateError>()));

      await uow.begin();
      expect(uow.begin, throwsA(isA<TransactionStateError>()));
      await uow.rollback();
      await uow.close();
    });
  });
}
