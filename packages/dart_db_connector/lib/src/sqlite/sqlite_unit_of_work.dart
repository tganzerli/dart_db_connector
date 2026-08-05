/// SQLite-backed unit of work. Pins a [SqlitePooledConnection] for a
/// transaction's lifetime, issues BEGIN/COMMIT/ROLLBACK as SQL, and exposes
/// a [SqliteQueryExecutor]. Mirror of `mysql_unit_of_work.dart`.
///
/// Cross-driver note: unlike MongoDB, SQLite HAS SQL + transactions, so a
/// `UnitOfWork` applies (as in MySQL/Postgres). It still duplicates the
/// domain interface for the same ResultSet/Param leak reason.
library;

import '../domain/unit_of_work.dart' show TransactionStateError;
import '../pool/sqlite_connection_pool.dart';
import 'sqlite_query_executor.dart';

class SqliteUnitOfWork {
  final SqliteConnectionPool _pool;

  SqlitePooledConnection? _leased;
  SqliteQueryExecutor? _executor;
  bool _active = false;

  SqliteUnitOfWork(this._pool);

  bool get isActive => _active;

  SqliteQueryExecutor get executor {
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
    final exec = SqliteQueryExecutor(_pool.binding, leased.raw);
    try {
      (await exec.execute('BEGIN')).release();
    } catch (_) {
      await leased.release();
      rethrow;
    }
    _leased = leased;
    _executor = exec;
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
    if (leased != null) await leased.release();
  }
}
