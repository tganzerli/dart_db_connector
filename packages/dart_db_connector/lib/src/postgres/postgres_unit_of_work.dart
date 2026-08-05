/// Postgres-backed [UnitOfWork] implementation.
///
/// Pins a single [PooledConnection] for the lifetime of a transaction,
/// issues `COMMIT` / `ROLLBACK` as SQL, and exposes a
/// [PostgresQueryExecutor] over the same connection while the
/// transaction is active. The `BEGIN` is deferred (P5, 2026-07-28) and
/// fused into the first statement of the body to save one round-trip;
/// see [PostgresUnitOfWork.begin].
library;

import '../domain/unit_of_work.dart';
import '../pool/connection_pool.dart';
import 'postgres_query_executor.dart';

/// Postgres-backed [UnitOfWork] over a [PostgresConnectionPool].
///
/// Acquires a single [PooledConnection] on [begin], pins it for the
/// transaction's lifetime, defers `BEGIN` into the first body statement
/// (P5), issues `COMMIT` / `ROLLBACK` as plain SQL, and releases the
/// connection back to the pool on terminal transitions. Most callers
/// should use [withTransaction] instead — it wraps the full lifecycle.
///
/// Example:
/// ```dart
/// final uow = PostgresUnitOfWork(pool);
/// await uow.begin();
/// try {
///   await UserRepository(uow.executor).insert(user);
///   await uow.commit();
/// } catch (_) {
///   await uow.rollback();
///   rethrow;
/// } finally {
///   await uow.close();
/// }
/// ```
class PostgresUnitOfWork implements UnitOfWork {
  final PostgresConnectionPool _pool;

  PooledConnection? _leased;
  PostgresQueryExecutor? _executor;
  bool _active = false;

  /// Builds a unit of work over the given pool. The binding is resolved
  /// internally from the pool — consumers no longer need to pass it
  /// explicitly.
  PostgresUnitOfWork(this._pool);

  @override
  bool get isActive => _active;

  @override
  QueryExecutor get executor {
    final e = _executor;
    if (e == null || !_active) {
      throw TransactionStateError(
          'No active transaction; call begin() before executor.');
    }
    return e;
  }

  @override
  Future<void> begin() async {
    if (_active) {
      throw TransactionStateError(
          'Transaction already active; nested begin() is not supported.');
    }
    final leased = await _pool.acquire();
    // P5 (2026-07-28): the BEGIN is deferred and fused into the first
    // statement of the body (`BEGIN;<sql>` in one round-trip via the
    // Simple Protocol), or sent standalone on the Extended path. A body
    // that never executes anything still opens+closes the transaction:
    // commit()/rollback()/close() call execute('COMMIT'|'ROLLBACK'),
    // which the executor fuses with the pending BEGIN. This removes one
    // round-trip per transaction versus the previous eager BEGIN.
    _leased = leased;
    _executor =
        PostgresQueryExecutor(_pool.binding, leased.raw, deferredBegin: true);
    _active = true;
  }

  @override
  Future<void> commit() async {
    if (!_active) {
      throw TransactionStateError(
          'No active transaction; commit() without begin().');
    }
    try {
      (await _executor!.execute('COMMIT')).release();
    } finally {
      await _releaseConnection();
    }
  }

  @override
  Future<void> rollback() async {
    if (!_active) {
      throw TransactionStateError(
          'No active transaction; rollback() without begin().');
    }
    try {
      (await _executor!.execute('ROLLBACK')).release();
    } finally {
      await _releaseConnection();
    }
  }

  @override
  Future<void> close() async {
    if (!_active) return;
    try {
      (await _executor!.execute('ROLLBACK')).release();
    } catch (_) {
      // best-effort
    } finally {
      await _releaseConnection();
    }
  }

  Future<void> _releaseConnection() async {
    final leased = _leased;
    _leased = null;
    _executor = null;
    _active = false;
    if (leased != null) {
      await leased.release();
    }
  }
}
