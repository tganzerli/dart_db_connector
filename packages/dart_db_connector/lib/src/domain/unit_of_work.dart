/// Transaction boundary abstractions.
///
/// A [UnitOfWork] frames a sequence of [QueryExecutor] calls inside a
/// single database transaction (`BEGIN` / `COMMIT` / `ROLLBACK`).
/// [Repository] implementations consume the [QueryExecutor] handed out
/// by an active UoW; they do not know about transactions directly.
library;

import '../decoder/result_row.dart';
import '../postgres/param.dart';

/// Executes SQL against an underlying connection and returns the
/// decoded [ResultSet]. Implementations are expected to be bound to a
/// single connection for the duration of a transaction.
abstract interface class QueryExecutor {
  /// Executes [sql]. Returns the decoded result set (empty for statements
  /// like `BEGIN` / `COMMIT` that produce no rows).
  ///
  /// When [params] is empty (default) the simple query protocol is used —
  /// same low-overhead path as before ABI MINOR 1. When [params] is
  /// non-empty, the Extended Query Protocol (libpq `PQsendQueryParams`)
  /// is used: values travel separately from the SQL text, so SQL
  /// injection through bound parameters is structurally impossible.
  /// Use `$1`, `$2`, … placeholders in [sql].
  ///
  /// [binaryResult] requests rows in binary wire format (4-byte BE ints,
  /// IEEE 754 BE floats, etc.) — typically ~20% fewer bytes on wire and
  /// no text→typed conversion. Only honored when the Extended Protocol
  /// is used (`params.isEmpty == false`, or pass an explicit empty list
  /// alongside `binaryResult: true` to force the extended path).
  ///
  /// Throws [QueryFailedException] if libpq refuses to send the query or
  /// the connection enters an error state during dispatch.
  Future<ResultSet> execute(
    String sql, {
    List<Param> params,
    bool binaryResult,
  });
}

/// Frame for a single database transaction.
///
/// Lifecycle: `begin → executor.execute(...) ×N → commit | rollback → close`.
/// `close()` is idempotent and rolls back if the transaction is still
/// active, so callers can rely on `try/finally` for cleanup.
abstract interface class UnitOfWork {
  /// `true` while a transaction is open (between [begin] and a
  /// terminating [commit]/[rollback]/[close]).
  bool get isActive;

  /// The executor pinned to the transaction's connection. Reading this
  /// before [begin] throws [TransactionStateError].
  QueryExecutor get executor;

  /// Opens the transaction on a pooled connection.
  ///
  /// Implementations may **defer** the physical `BEGIN`: the Postgres
  /// implementation (P5, 2026-07-28) sends no `BEGIN` here and instead
  /// fuses it into the first statement of the body (`BEGIN;<sql>` in a
  /// single round-trip on the Simple Protocol), or emits a standalone
  /// `BEGIN` when that first statement uses the Extended Protocol
  /// (bound params or binary results). Either way the transaction
  /// exists server-side from the first [QueryExecutor.execute] onward,
  /// and [isActive] reads `true` from `begin()` — it tracks the
  /// *logical* transaction (pinned connection + valid executor), not the
  /// moment the server opened it.
  ///
  /// Error semantics of the deferred/fused BEGIN: a failure in the first
  /// body statement leaves the server in an aborted-transaction state
  /// and surfaces as [QueryFailedException] carrying the real server
  /// message; the transaction's [rollback] (or [close]) then cleans up
  /// correctly and the connection is reusable. A connection failure that
  /// a previous eager `BEGIN` would have raised here now surfaces on the
  /// first body statement instead — [withTransaction] already routes
  /// that through rollback + rethrow.
  ///
  /// Throws [TransactionStateError] if a transaction is already active.
  Future<void> begin();

  /// Commits the transaction (`COMMIT`) and releases the connection.
  /// Throws [TransactionStateError] if no transaction is active.
  Future<void> commit();

  /// Rolls back the transaction (`ROLLBACK`) and releases the connection.
  /// Throws [TransactionStateError] if no transaction is active.
  Future<void> rollback();

  /// Idempotent shutdown. If a transaction is still active, performs a
  /// best-effort rollback before releasing the connection. Calling twice
  /// is a no-op.
  Future<void> close();
}

/// Signals an attempt to drive a [UnitOfWork] outside the lifecycle
/// states it allows.
///
/// Raised on illegal transitions: `commit` or `rollback` without a
/// preceding `begin`, double `begin`, or accessing [UnitOfWork.executor]
/// before the transaction is open. Wraps Dart's [StateError] for
/// `is`/`catch` compatibility with generic state-machine handling.
class TransactionStateError extends StateError {
  TransactionStateError(super.message);
}

/// Signals a SQL/protocol failure surfaced by libpq during
/// [QueryExecutor.execute].
///
/// The native side refused dispatch (`PQsendQuery` returned 0) or the
/// connection entered an error state mid-query. [serverMessage] holds
/// the libpq diagnostic when available. The connection is left in an
/// undefined state — most callers should `rollback()` the transaction
/// (or release + reopen the pool) before retrying.
class QueryFailedException implements Exception {
  final String sql;
  final String? serverMessage;

  /// Native error code when available (e.g. libmysqlclient `mysql_errno`).
  /// `null` for failures with no numeric code (dispatch refusals, PG paths).
  final int? code;

  QueryFailedException(this.sql, this.serverMessage, {this.code});

  @override
  String toString() {
    final detail = serverMessage ?? 'no detail';
    final codePart = code != null ? ' [code $code]' : '';
    return 'QueryFailedException($detail)$codePart while executing: $sql';
  }
}

/// Signals that a query exceeded its configured wall-clock timeout
/// (`timeout_ms` in the native ABI). The watcher thread issued
/// `PQcancel` before throwing; the underlying connection state is
/// undefined and the caller should close + reconnect.
///
/// Added in ABI MAJOR 1.
class QueryTimeoutException implements Exception {
  final String sql;
  final Duration timeout;
  QueryTimeoutException(this.sql, this.timeout);

  @override
  String toString() =>
      'QueryTimeoutException after ${timeout.inMilliseconds}ms: $sql';
}
