/// MySQL-backed query executor.
///
/// Sends one SQL statement, waits for the Native Port notification,
/// decodes the result into a [MysqlResultSet]. MySQL counterpart of
/// `postgres_query_executor.dart`.
///
/// v1 is simple-protocol only (no bound parameters): the MySQL native
/// ABI has no `PQsendQueryParams` analogue. It therefore does NOT
/// implement the shared [QueryExecutor] interface (which is typed to the
/// PostgreSQL `ResultSet` + `Param`); it returns [MysqlResultSet]. This
/// duplication is a deliberate, measured finding for the extensibility
/// synthesis: `Repository<T,K>` generalized cleanly, but the
/// executor/UoW leaked the PostgreSQL result type and needed a mirror.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../bindings/mysql_binding.dart';
import '../decoder/mysql_result_row.dart';
import '../domain/unit_of_work.dart' show QueryFailedException;
import '../native/mysql_native_pool.dart' show MysqlWorkerPortCode;

/// Executes SQL over a single pinned MySQL connection and decodes the
/// result. Bound to one `mysql_conn_t*` for a transaction's lifetime.
class MysqlQueryExecutor {
  final MysqlBinding _binding;
  final ffi.Pointer<ffi.Void> _conn;

  /// BEGIN-piggyback (2026-08-03, MySQL counterpart of the PostgreSQL P5):
  /// when true, the next dispatch fuses a `BEGIN` prefix into the
  /// transaction's first statement (one multi-statement round-trip via
  /// `poolSubmitMultiRead`), saving the dedicated BEGIN round-trip. Armed
  /// by `MysqlUnitOfWork.begin()` through the [deferredBegin] flag and
  /// consumed exactly once on the first `execute`/`executeMultiRead`/
  /// `executeBatch`.
  bool _pendingBegin;

  MysqlQueryExecutor(this._binding, this._conn, {bool deferredBegin = false})
      : _pendingBegin = deferredBegin;

  /// Builds a [QueryFailedException] carrying the REAL libmysqlclient error
  /// (message + errno) captured on the conn at the point of failure, instead
  /// of an opaque "aborted". Read on the abort path only — synchronously,
  /// before any further submit on this conn (ABI MINOR 3 contract). Falls
  /// back to [fallback] if the native message is empty.
  QueryFailedException _abortException(String sql, String fallback) {
    final errno = _binding.lastErrno(_conn);
    final msgPtr = _binding.lastError(_conn);
    final native = msgPtr == ffi.nullptr ? '' : msgPtr.toDartString();
    final message = native.isNotEmpty ? native : fallback;
    return QueryFailedException(sql, message, code: errno == 0 ? null : errno);
  }

  /// Executes [sql] via the simple query protocol. Returns the decoded
  /// result set (empty for statements that produce no row set, though
  /// DML still reports `affectedRows`).
  ///
  /// Throws [QueryFailedException] if dispatch is refused or the worker
  /// reports the query aborted.
  Future<MysqlResultSet> execute(String sql) {
    if (_pendingBegin) {
      _pendingBegin = false;
      return _executeFusedBegin(sql);
    }
    return _executeSimple(sql);
  }

  Future<MysqlResultSet> _executeSimple(String sql) async {
    final port = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    int code;
    try {
      final status =
          _binding.poolSubmitQuery(_conn, sqlPtr, port.sendPort.nativePort, 0);
      if (status != 1) {
        throw QueryFailedException(sql, 'MySQL refused to dispatch query');
      }
      code = await port.first as int;
    } finally {
      malloc.free(sqlPtr);
      port.close();
    }
    if (code == MysqlWorkerPortCode.aborted) {
      throw _abortException(sql, 'query failed or connection error');
    }
    final result = _binding.pollResult(_conn);
    if (result == ffi.nullptr) return MysqlResultSet.empty();
    return MysqlResultSet.fromResult(_binding, result);
  }

  /// BEGIN-piggyback: dispatches `BEGIN; <sql>` as one multi-statement
  /// round-trip (reusing `poolSubmitMultiRead`, no new ABI). Consumes the
  /// leading BEGIN result, then returns [sql]'s result. Saves one
  /// round-trip per transaction.
  Future<MysqlResultSet> _executeFusedBegin(String sql) async {
    final port = ReceivePort();
    final arr = malloc<ffi.Pointer<Utf8>>(2);
    final beginPtr = 'BEGIN'.toNativeUtf8();
    final sqlPtr = sql.toNativeUtf8();
    int code;
    try {
      arr[0] = beginPtr;
      arr[1] = sqlPtr;
      final status = _binding.poolSubmitMultiRead(
          _conn, arr, 2, port.sendPort.nativePort, 0);
      if (status != 1) {
        throw QueryFailedException(sql, 'MySQL refused fused BEGIN dispatch');
      }
      code = await port.first as int;
    } finally {
      malloc.free(beginPtr);
      malloc.free(sqlPtr);
      malloc.free(arr);
      port.close();
    }
    if (code == MysqlWorkerPortCode.aborted) {
      throw _abortException(sql, 'fused BEGIN failed (mid-batch error)');
    }
    // Discard the BEGIN's (empty) result, then return the statement's.
    final beginR = _binding.pollResult(_conn);
    if (beginR != ffi.nullptr) _binding.clearResult(beginR);
    final result = _binding.pollResult(_conn);
    if (result == ffi.nullptr) return MysqlResultSet.empty();
    return MysqlResultSet.fromResult(_binding, result);
  }

  /// Executes a batch of [stmts] in a SINGLE round-trip (multi-statement,
  /// ABI MINOR 1) — the MySQL analog of the PostgreSQL pipeline. Cuts N
  /// write round-trips to 1. Row data is not surfaced (batch is for writes).
  ///
  /// Throws [QueryFailedException] on dispatch refusal or a mid-batch error;
  /// callers run this inside a transaction so the failure rolls back.
  ///
  /// SECURITY: [stmts] must be **synthesized by the program** (internal /
  /// computed values), never SQL influenced by external input — multi-
  /// statement + interpolation would be an injection surface. Bound-parameter
  /// batching is separate future work.
  Future<void> executeBatch(List<String> stmts) async {
    final fused = _pendingBegin;
    _pendingBegin = false;
    if (stmts.isEmpty) {
      if (fused) (await _executeSimple('BEGIN')).release();
      return;
    }
    final port = ReceivePort();
    final n = stmts.length;
    final total = fused ? n + 1 : n;
    final arr = malloc<ffi.Pointer<Utf8>>(total);
    final allocated = <ffi.Pointer<Utf8>>[];
    int code;
    try {
      var slot = 0;
      if (fused) {
        final b = 'BEGIN'.toNativeUtf8();
        allocated.add(b);
        arr[slot++] = b;
      }
      for (var i = 0; i < n; i++) {
        final p = stmts[i].toNativeUtf8();
        allocated.add(p);
        arr[slot++] = p;
      }
      final status = _binding.poolSubmitBatch(
          _conn, arr, total, port.sendPort.nativePort, 0);
      if (status != 1) {
        throw QueryFailedException(stmts.first, 'MySQL refused batch dispatch');
      }
      code = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(arr);
      port.close();
    }
    if (code == MysqlWorkerPortCode.aborted) {
      throw _abortException(stmts.first, 'batch failed (mid-batch error)');
    }
    // Drain the empty result wrapper(s) the worker stored (BEGIN + batch).
    for (var i = 0; i < (fused ? 2 : 1); i++) {
      final result = _binding.pollResult(_conn);
      if (result != ffi.nullptr) _binding.clearResult(result);
    }
  }

  /// Runs [reads] in a SINGLE round-trip (multi-statement, ABI MINOR 2) and
  /// returns the N result sets in statement order — the MySQL analog of the
  /// PostgreSQL pipeline for reads. Cuts N read round-trips to 1.
  ///
  /// Throws [QueryFailedException] on dispatch refusal or a mid-batch error
  /// (the surrounding transaction should roll back). Caller releases each
  /// returned [MysqlResultSet].
  ///
  /// SECURITY: [reads] must be **synthesized by the program**, never SQL
  /// influenced by external input.
  Future<List<MysqlResultSet>> executeMultiRead(List<String> reads) async {
    final fused = _pendingBegin;
    _pendingBegin = false;
    if (reads.isEmpty) {
      if (fused) (await _executeSimple('BEGIN')).release();
      return const [];
    }
    final port = ReceivePort();
    final n = reads.length;
    final total = fused ? n + 1 : n;
    final arr = malloc<ffi.Pointer<Utf8>>(total);
    final allocated = <ffi.Pointer<Utf8>>[];
    int code;
    try {
      var slot = 0;
      if (fused) {
        final b = 'BEGIN'.toNativeUtf8();
        allocated.add(b);
        arr[slot++] = b;
      }
      for (var i = 0; i < n; i++) {
        final p = reads[i].toNativeUtf8();
        allocated.add(p);
        arr[slot++] = p;
      }
      final status = _binding.poolSubmitMultiRead(
          _conn, arr, total, port.sendPort.nativePort, 0);
      if (status != 1) {
        throw QueryFailedException(reads.first, 'MySQL refused multi-read');
      }
      code = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(arr);
      port.close();
    }
    if (code == MysqlWorkerPortCode.aborted) {
      throw _abortException(reads.first, 'multi-read failed (mid-batch error)');
    }
    // Discard the fused BEGIN's result before the read loop so indexing
    // maps 1:1 to `reads`.
    if (fused) {
      final beginR = _binding.pollResult(_conn);
      if (beginR != ffi.nullptr) _binding.clearResult(beginR);
    }
    // Drain the N result sets in statement order (chained on the C side).
    final out = <MysqlResultSet>[];
    for (var i = 0; i < n; i++) {
      final r = _binding.pollResult(_conn);
      out.add(r == ffi.nullptr
          ? MysqlResultSet.empty()
          : MysqlResultSet.fromResult(_binding, r));
    }
    return out;
  }
}
