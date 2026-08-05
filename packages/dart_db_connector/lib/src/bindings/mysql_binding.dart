/// MySQL FFI binding for `libnative_mysql`.
///
/// Maps the `extern "C"` symbols declared in
/// `native/c/include/native_mysql.h` and `native/c/include/mysql_pool.h`.
/// ABI changes here MUST follow the ABI stability policy in CONTRIBUTING.md
/// (matching ADR + bump of NATIVE_MYSQL_ABI_VERSION_*).
///
/// Independent of [PostgresBinding]: a separate native library
/// (`libnative_mysql`) with its own ABI. Structurally a mirror of the
/// PostgreSQL binding, which is the demonstration that the pattern
/// generalizes (see the layered architecture in the package README).
///
/// ABI MAJOR 1 MINOR 0 (2026-07-24). Differences from the PostgreSQL
/// binding worth noting:
///   - `mysql_pool_create` takes discrete connection parameters
///     (host/user/password/db/port) rather than a single conninfo string.
///   - No pipeline / no Extended-Protocol params path in v1 (MySQL has no
///     direct libpq-pipeline analogue).
///   - Result handles are opaque wrappers (`native_mysql_result_t`);
///     Dart still sees `Pointer<Void>`.
library;

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

// ───────── Init ─────────

typedef _InitDartApiNative = ffi.IntPtr Function(ffi.Pointer<ffi.Void>);
typedef _InitDartApiDart = int Function(ffi.Pointer<ffi.Void>);

// ───────── Pool primitives ─────────

typedef _PoolCreateNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, // host
    ffi.Pointer<Utf8>, // user
    ffi.Pointer<Utf8>, // password
    ffi.Pointer<Utf8>, // db
    ffi.Uint16, // port
    ffi.Int32, // min_size
    ffi.Int32, // max_size
    ffi.Int64); // acquire_timeout_ms
typedef _PoolCreateDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    int,
    int,
    int,
    int);

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

typedef _PoolSubmitBatchNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Pointer<Utf8>>, ffi.Int32, ffi.Int64, ffi.Int64);
typedef _PoolSubmitBatchDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<Utf8>>, int, int, int);

typedef _PoolCancelNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _PoolCancelDart = void Function(ffi.Pointer<ffi.Void>);

typedef _PoolDestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _PoolDestroyDart = void Function(ffi.Pointer<ffi.Void>);

// ───────── Result retrieval + inspection ─────────

typedef _PollResultNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);
typedef _PollResultDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

typedef _RowCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _RowCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _ColCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _ColCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _AffectedRowsNative = ffi.Int64 Function(ffi.Pointer<ffi.Void>);
typedef _AffectedRowsDart = int Function(ffi.Pointer<ffi.Void>);

typedef _FieldNameNative = ffi.Pointer<Utf8> Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _FieldNameDart = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>, int);

typedef _RawValueNative = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _RawValueDart = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>, int, int);

typedef _RawLengthNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _RawLengthDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef _FieldTypeNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _FieldTypeDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _ClearResultNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ClearResultDart = void Function(ffi.Pointer<ffi.Void>);

// Error surfacing (ABI MINOR 3). Take a conn handle, not a result.
typedef _LastErrnoNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>);
typedef _LastErrnoDart = int Function(ffi.Pointer<ffi.Void>);

typedef _LastErrorNative = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _LastErrorDart = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);

/// Thin wrapper around a [ffi.DynamicLibrary] exposing all native symbols
/// of `libnative_mysql`. Construction looks up symbols eagerly so any
/// missing symbol surfaces immediately rather than at first use.
///
/// **Internal class.** Consumers of `dart_db_connector` should not import
/// or instantiate `MysqlBinding` directly — use `MysqlConnectionPool` or
/// another public entry point, which resolves the binding internally via
/// the per-isolate `MysqlSharedBinding` singleton.
@internal
class MysqlBinding {
  /// Initializes the Dart Native API by passing
  /// `NativeApi.initializeApiDLData`. Returns 0 on success.
  final int Function(ffi.Pointer<ffi.Void> data) initDartApi;

  /// Creates a `mysql_pool_t*` with `maxSize` connections + workers.
  /// Returns `nullptr` on failure. Caller must release via [poolDestroy].
  /// Connection coordinates are discrete (matching `mysql_real_connect`).
  final ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<Utf8> host,
      ffi.Pointer<Utf8> user,
      ffi.Pointer<Utf8> password,
      ffi.Pointer<Utf8> db,
      int port,
      int minSize,
      int maxSize,
      int acquireTimeoutMs) poolCreate;

  /// Blocks until a free `mysql_conn_t*` is available or `timeoutMs`
  /// elapses. Returns `nullptr` on timeout / pool shutdown.
  final ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> pool, int timeoutMs) poolAcquire;

  /// Returns a `mysql_conn_t*` to the pool. No-op on nullptr.
  final void Function(ffi.Pointer<ffi.Void> pool, ffi.Pointer<ffi.Void> conn)
      poolRelease;

  /// Submits a single SQL statement to `conn`'s worker thread.
  /// Non-blocking; result delivered on `portId` (int64 = 1 / 2).
  /// Returns 1 on dispatch success, 0 if the slot is busy.
  final int Function(ffi.Pointer<ffi.Void> conn, ffi.Pointer<Utf8> sql,
      int portId, int timeoutMs) poolSubmitQuery;

  /// Submits a batch of `count` statements in ONE round-trip
  /// (multi-statement). Same delivery contract as [poolSubmitQuery]
  /// (int64 = 1 ok / 2 aborted; aborted on a mid-batch error). Row data is
  /// not surfaced. ABI MINOR 1. `stmts` must be program-synthesized.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<ffi.Pointer<Utf8>> stmts,
      int count,
      int portId,
      int timeoutMs) poolSubmitBatch;

  /// Submits `count` READ statements in ONE round-trip, preserving the N
  /// result sets. Drain via [pollResult] × count (chained internally). Same
  /// delivery contract as [poolSubmitBatch]. ABI MINOR 2. `reads` must be
  /// program-synthesized.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<ffi.Pointer<Utf8>> reads,
      int count,
      int portId,
      int timeoutMs) poolSubmitMultiRead;

  /// Best-effort cancel of any in-flight query on `conn` (KILL QUERY).
  final void Function(ffi.Pointer<ffi.Void> conn) poolCancel;

  /// Tears down a pool: signals shutdown, joins all workers, closes
  /// every conn, frees the struct.
  final void Function(ffi.Pointer<ffi.Void> pool) poolDestroy;

  /// Retrieves the stored result handle for `conn` after the Native Port
  /// notification. Caller owns the returned handle and MUST call
  /// [clearResult]. Non-NULL even for DML (row/col counts report 0).
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void> conn) pollResult;

  /// Number of rows in a result. 0 for non-SELECT.
  final int Function(ffi.Pointer<ffi.Void> result) rowCount;

  /// Number of columns in a result. 0 for non-SELECT.
  final int Function(ffi.Pointer<ffi.Void> result) colCount;

  /// Affected-row count for the last DML statement.
  final int Function(ffi.Pointer<ffi.Void> result) affectedRows;

  /// Column name for [col]. Pointer valid until [clearResult] — DO NOT free.
  final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void> result, int col)
      fieldName;

  /// Pointer to raw bytes of cell `(row, col)`. `nullptr` when SQL NULL.
  /// Valid until [clearResult] OR the next read from a different row
  /// (the wrapper caches one row). Wrap with `.asTypedList(length)`.
  final ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Void> result, int row, int col) rawValue;

  /// Length in bytes of cell `(row, col)`. `0` when SQL NULL.
  final int Function(ffi.Pointer<ffi.Void> result, int row, int col) rawLength;

  /// MySQL `enum_field_types` code for column [col] (the decode key).
  final int Function(ffi.Pointer<ffi.Void> result, int col) fieldType;

  /// Last libmysqlclient error code captured on [conn] when its most recent
  /// statement aborted (0 on success). Read only on the abort path. ABI MINOR 3.
  final int Function(ffi.Pointer<ffi.Void> conn) lastErrno;

  /// Last libmysqlclient error message captured on [conn] (empty on success).
  /// Pointer owned by the conn, valid until its next query. ABI MINOR 3.
  final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void> conn) lastError;

  /// Frees the underlying result handle (`mysql_free_result` + wrapper).
  /// Idempotent on `nullptr`.
  final void Function(ffi.Pointer<ffi.Void> result) clearResult;

  MysqlBinding._(
    this.initDartApi,
    this.poolCreate,
    this.poolAcquire,
    this.poolRelease,
    this.poolSubmitQuery,
    this.poolSubmitBatch,
    this.poolSubmitMultiRead,
    this.poolCancel,
    this.poolDestroy,
    this.pollResult,
    this.rowCount,
    this.colCount,
    this.affectedRows,
    this.fieldName,
    this.rawValue,
    this.rawLength,
    this.fieldType,
    this.lastErrno,
    this.lastError,
    this.clearResult,
  );

  factory MysqlBinding(ffi.DynamicLibrary lib) {
    return MysqlBinding._(
      lib.lookupFunction<_InitDartApiNative, _InitDartApiDart>(
          'native_mysql_init_dart_api'),
      lib.lookupFunction<_PoolCreateNative, _PoolCreateDart>(
          'mysql_pool_create'),
      lib.lookupFunction<_PoolAcquireNative, _PoolAcquireDart>(
          'mysql_pool_acquire'),
      lib.lookupFunction<_PoolReleaseNative, _PoolReleaseDart>(
          'mysql_pool_release'),
      lib.lookupFunction<_PoolSubmitQueryNative, _PoolSubmitQueryDart>(
          'mysql_pool_submit_query'),
      lib.lookupFunction<_PoolSubmitBatchNative, _PoolSubmitBatchDart>(
          'mysql_pool_submit_batch'),
      // Same signature as submit_batch (conn, ptr array, count, port, timeout).
      lib.lookupFunction<_PoolSubmitBatchNative, _PoolSubmitBatchDart>(
          'mysql_pool_submit_multi_read'),
      lib.lookupFunction<_PoolCancelNative, _PoolCancelDart>(
          'mysql_pool_cancel'),
      lib.lookupFunction<_PoolDestroyNative, _PoolDestroyDart>(
          'mysql_pool_destroy'),
      lib.lookupFunction<_PollResultNative, _PollResultDart>(
          'native_mysql_poll_result'),
      lib.lookupFunction<_RowCountNative, _RowCountDart>(
          'native_mysql_row_count'),
      lib.lookupFunction<_ColCountNative, _ColCountDart>(
          'native_mysql_col_count'),
      lib.lookupFunction<_AffectedRowsNative, _AffectedRowsDart>(
          'native_mysql_affected_rows'),
      lib.lookupFunction<_FieldNameNative, _FieldNameDart>(
          'native_mysql_field_name'),
      lib.lookupFunction<_RawValueNative, _RawValueDart>(
          'native_mysql_raw_value'),
      lib.lookupFunction<_RawLengthNative, _RawLengthDart>(
          'native_mysql_raw_length'),
      lib.lookupFunction<_FieldTypeNative, _FieldTypeDart>(
          'native_mysql_field_type'),
      lib.lookupFunction<_LastErrnoNative, _LastErrnoDart>(
          'native_mysql_last_errno'),
      lib.lookupFunction<_LastErrorNative, _LastErrorDart>(
          'native_mysql_last_error'),
      lib.lookupFunction<_ClearResultNative, _ClearResultDart>(
          'native_mysql_clear_result'),
    );
  }
}
