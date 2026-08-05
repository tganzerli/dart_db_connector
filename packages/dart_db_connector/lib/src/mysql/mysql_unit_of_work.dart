/// MySQL-backed unit of work.
///
/// Pins a single [MysqlPooledConnection] for a transaction's lifetime,
/// issues `BEGIN` / `COMMIT` / `ROLLBACK` as plain SQL, and exposes a
/// [MysqlQueryExecutor] over the same connection. Mirror of
/// `postgres_unit_of_work.dart`.
library;

import '../domain/unit_of_work.dart' show TransactionStateError;
import '../pool/mysql_connection_pool.dart';
import 'mysql_query_executor.dart';

/// Frames a single MySQL transaction over a [MysqlConnectionPool].
///
/// Lifecycle: `begin → executor.execute(...) ×N → commit | rollback →
/// close`. `close()` is idempotent and rolls back if still active, so
/// callers can rely on `try/finally`. Most callers should use
/// [withMysqlTransaction] instead.
class MysqlUnitOfWork {
  final MysqlConnectionPool _pool;

  MysqlPooledConnection? _leased;
  MysqlQueryExecutor? _executor;
  bool _active = false;

  MysqlUnitOfWork(this._pool);

  /// `true` while a transaction is open.
  bool get isActive => _active;

  /// The executor pinned to the transaction's connection. Throws
  /// [TransactionStateError] before [begin].
  MysqlQueryExecutor get executor {
    final e = _executor;
    if (e == null || !_active) {
      throw TransactionStateError(
          'No active transaction; call begin() before executor.');
    }
    return e;
  }

  Future<void> begin() async {
    if (_active) {
      throw TransactionStateError(
          'Transaction already active; nested begin() is not supported.');
    }
    final leased = await _pool.acquire();
    // BEGIN-piggyback (2026-08-03): the BEGIN is deferred and fused into the
    // first statement of the body (`BEGIN;<sql>` in one round-trip), or into
    // the COMMIT/ROLLBACK if the body executes nothing. Removes one round-trip
    // per transaction versus the previous eager BEGIN. Mirror of
    // `PostgresUnitOfWork.begin()`.
    _leased = leased;
    _executor =
        MysqlQueryExecutor(_pool.binding, leased.raw, deferredBegin: true);
    _active = true;
  }

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
