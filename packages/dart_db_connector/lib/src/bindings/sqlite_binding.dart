/// SQLite FFI binding for `libnative_sqlite`.
///
/// Maps the `extern "C"` symbols of `native/c/include/native_sqlite.h` and
/// `sqlite_pool.h`. Independent of the other drivers' bindings (separate
/// native lib + ABI).  — the EMBEDDED driver. Structurally
/// a mirror of [MysqlBinding] (relational, simple-query), differing only in:
///   - `sqlite_pool_create` takes a FILE PATH (+ busy_timeout), not a URI or
///     discrete host params.
///   - the result is materialised: `cellType(result, row, col)` is per-cell
///     (SQLite is dynamically typed), and `lastError` carries the real
///     `sqlite3_errmsg`.
library;

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

typedef _InitDartApiNative = ffi.IntPtr Function(ffi.Pointer<ffi.Void>);
typedef _InitDartApiDart = int Function(ffi.Pointer<ffi.Void>);

typedef _PoolCreateNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, ffi.Int32, ffi.Int32, ffi.Int64, ffi.Int32);
typedef _PoolCreateDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, int, int, int, int);

typedef _PoolAcquireNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, ffi.Int64);
typedef _PoolAcquireDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, int);

typedef _PoolReleaseNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _PoolReleaseDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

typedef _PoolSubmitQueryNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Int64, ffi.Int64);
typedef _PoolSubmitQueryDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, int, int);

typedef _PoolDestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _PoolDestroyDart = void Function(ffi.Pointer<ffi.Void>);

// MINOR 1 — batch / multi-read: (conn, ptr-array, count, port, timeout).
typedef _SubmitJoinedNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Pointer<Utf8>>, ffi.Int32, ffi.Int64, ffi.Int64);
typedef _SubmitJoinedDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<Utf8>>, int, int, int);

// MINOR 2 — synchronous fast-path: (conn, sql) → 1 ok / 2 aborted / 0 refused.
typedef _ExecSyncNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef _ExecSyncDart = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);

typedef _PollResultNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);
typedef _PollResultDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

typedef _RowCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _RowCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _ColCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _ColCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _AffectedRowsNative = ffi.Int64 Function(ffi.Pointer<ffi.Void>);
typedef _AffectedRowsDart = int Function(ffi.Pointer<ffi.Void>);

typedef _ColNameNative = ffi.Pointer<Utf8> Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _ColNameDart = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>, int);

typedef _CellTypeNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _CellTypeDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef _RawValueNative = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _RawValueDart = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>, int, int);

typedef _RawLengthNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _RawLengthDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef _LastErrorNative = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _LastErrorDart = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);

typedef _LastErrorCodeNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _LastErrorCodeDart = int Function(ffi.Pointer<ffi.Void>);

typedef _ClearResultNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ClearResultDart = void Function(ffi.Pointer<ffi.Void>);

/// Thin wrapper over the `libnative_sqlite` symbols. Eager lookup.
///
/// **Internal.** Use `SqliteConnectionPool` — it resolves the binding via
/// the per-isolate `SqliteSharedBinding` singleton.
@internal
class SqliteBinding {
  final int Function(ffi.Pointer<ffi.Void> data) initDartApi;

  /// Creates a `sqlite_pool_t*` over the DB file [path] with `maxSize`
  /// connections (WAL) + workers. `busyTimeoutMs` bounds `SQLITE_BUSY`.
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8> path, int minSize,
      int maxSize, int acquireTimeoutMs, int busyTimeoutMs) poolCreate;

  final ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> pool, int timeoutMs) poolAcquire;

  final void Function(ffi.Pointer<ffi.Void> pool, ffi.Pointer<ffi.Void> conn)
      poolRelease;

  /// Submits one SQL statement. Result on `portId` (int64 = 1 / 2).
  final int Function(ffi.Pointer<ffi.Void> conn, ffi.Pointer<Utf8> sql,
      int portId, int timeoutMs) poolSubmitQuery;

  final void Function(ffi.Pointer<ffi.Void> pool) poolDestroy;

  /// Submits N ';'-joined write statements in one round-trip (MINOR 1).
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<ffi.Pointer<Utf8>> stmts,
      int count,
      int portId,
      int timeoutMs) poolSubmitBatch;

  /// Submits N reads in one round-trip, preserving N chained results (MINOR 1).
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<ffi.Pointer<Utf8>> reads,
      int count,
      int portId,
      int timeoutMs) poolSubmitMultiRead;

  /// Synchronous fast-path (MINOR 2): runs `sql` on the calling thread.
  /// Returns 1 (ok, drain via [pollResult]) / 2 (aborted) / 0 (refused —
  /// async op pending; fall back to the async path).
  final int Function(ffi.Pointer<ffi.Void> conn, ffi.Pointer<Utf8> sql)
      execSync;

  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void> conn) pollResult;

  final int Function(ffi.Pointer<ffi.Void> result) rowCount;
  final int Function(ffi.Pointer<ffi.Void> result) colCount;
  final int Function(ffi.Pointer<ffi.Void> result) affectedRows;
  final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void> result, int col)
      colName;

  /// SQLite dynamic type of cell (row, col): 1=INT 2=FLOAT 3=TEXT 4=BLOB
  /// 5=NULL. Per-cell (SQLite is dynamically typed).
  final int Function(ffi.Pointer<ffi.Void> result, int row, int col) cellType;

  /// Raw bytes of cell (row, col); `nullptr` on SQL NULL. INTEGER/FLOAT are
  /// 8-byte host-endian; TEXT/BLOB as-is. Wrap with `.asTypedList(length)`.
  final ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Void> result, int row, int col) rawValue;

  final int Function(ffi.Pointer<ffi.Void> result, int row, int col) rawLength;

  /// Message of the last failed op on `conn` (`sqlite3_errmsg`), or "".
  final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void> conn) lastError;
  final int Function(ffi.Pointer<ffi.Void> conn) lastErrorCode;

  final void Function(ffi.Pointer<ffi.Void> result) clearResult;

  SqliteBinding._(
    this.initDartApi,
    this.poolCreate,
    this.poolAcquire,
    this.poolRelease,
    this.poolSubmitQuery,
    this.poolDestroy,
    this.poolSubmitBatch,
    this.poolSubmitMultiRead,
    this.execSync,
    this.pollResult,
    this.rowCount,
    this.colCount,
    this.affectedRows,
    this.colName,
    this.cellType,
    this.rawValue,
    this.rawLength,
    this.lastError,
    this.lastErrorCode,
    this.clearResult,
  );

  factory SqliteBinding(ffi.DynamicLibrary lib) {
    return SqliteBinding._(
      lib.lookupFunction<_InitDartApiNative, _InitDartApiDart>(
          'native_sqlite_init_dart_api'),
      lib.lookupFunction<_PoolCreateNative, _PoolCreateDart>(
          'sqlite_pool_create'),
      lib.lookupFunction<_PoolAcquireNative, _PoolAcquireDart>(
          'sqlite_pool_acquire'),
      lib.lookupFunction<_PoolReleaseNative, _PoolReleaseDart>(
          'sqlite_pool_release'),
      lib.lookupFunction<_PoolSubmitQueryNative, _PoolSubmitQueryDart>(
          'sqlite_pool_submit_query'),
      lib.lookupFunction<_PoolDestroyNative, _PoolDestroyDart>(
          'sqlite_pool_destroy'),
      lib.lookupFunction<_SubmitJoinedNative, _SubmitJoinedDart>(
          'sqlite_pool_submit_batch'),
      lib.lookupFunction<_SubmitJoinedNative, _SubmitJoinedDart>(
          'sqlite_pool_submit_multi_read'),
      lib.lookupFunction<_ExecSyncNative, _ExecSyncDart>(
          'sqlite_conn_exec_sync'),
      lib.lookupFunction<_PollResultNative, _PollResultDart>(
          'native_sqlite_poll_result'),
      lib.lookupFunction<_RowCountNative, _RowCountDart>(
          'native_sqlite_row_count'),
      lib.lookupFunction<_ColCountNative, _ColCountDart>(
          'native_sqlite_col_count'),
      lib.lookupFunction<_AffectedRowsNative, _AffectedRowsDart>(
          'native_sqlite_affected_rows'),
      lib.lookupFunction<_ColNameNative, _ColNameDart>(
          'native_sqlite_col_name'),
      lib.lookupFunction<_CellTypeNative, _CellTypeDart>(
          'native_sqlite_cell_type'),
      lib.lookupFunction<_RawValueNative, _RawValueDart>(
          'native_sqlite_raw_value'),
      lib.lookupFunction<_RawLengthNative, _RawLengthDart>(
          'native_sqlite_raw_length'),
      lib.lookupFunction<_LastErrorNative, _LastErrorDart>(
          'native_sqlite_last_error'),
      lib.lookupFunction<_LastErrorCodeNative, _LastErrorCodeDart>(
          'native_sqlite_last_error_code'),
      lib.lookupFunction<_ClearResultNative, _ClearResultDart>(
          'native_sqlite_clear_result'),
    );
  }
}
