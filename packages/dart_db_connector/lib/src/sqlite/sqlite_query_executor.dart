/// SQLite-backed query executor.
///
/// SQLite counterpart of `mysql_query_executor.dart`. Sends one SQL statement,
/// awaits the Native Port notification, decodes into a [SqliteResultSet].
///
/// Cross-driver note: like the MySQL executor, this DUPLICATES the domain
/// `QueryExecutor` (`../domain/unit_of_work.dart`) rather than implementing
/// it, because that interface is typed to the PostgreSQL `ResultSet`/`Param`.
/// The duplication has the SAME root cause across MySQL and SQLite (the SQL
/// seam leaks Postgres types), isolating that the cause is the SQL-execution
/// abstraction, not the topology (network vs embedded).
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../bindings/sqlite_binding.dart';
import '../decoder/sqlite_result_row.dart';
import '../domain/unit_of_work.dart' show QueryFailedException;
import '../native/sqlite_native_pool.dart' show SqliteWorkerPortCode;

/// Executes SQL over a single pinned SQLite connection and decodes the
/// materialised result.
class SqliteQueryExecutor {
  final SqliteBinding _binding;
  final ffi.Pointer<ffi.Void> _conn;

  SqliteQueryExecutor(this._binding, this._conn);

  /// Executes [sql]. Returns the decoded result set (empty for statements
  /// with no row set; DML still reports `affectedRows`). Throws
  /// [QueryFailedException] on dispatch refusal or a worker abort, carrying
  /// the real `sqlite3_errmsg`.
  Future<SqliteResultSet> execute(String sql) async {
    final port = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    int code;
    try {
      final status =
          _binding.poolSubmitQuery(_conn, sqlPtr, port.sendPort.nativePort, 0);
      if (status != 1) {
        throw QueryFailedException(sql, 'SQLite refused to dispatch query');
      }
      code = await port.first as int;
    } finally {
      malloc.free(sqlPtr);
      port.close();
    }
    if (code == SqliteWorkerPortCode.aborted) {
      final msg = _binding.lastError(_conn).toDartString();
      throw QueryFailedException(sql, msg.isEmpty ? 'query failed' : msg);
    }
    final result = _binding.pollResult(_conn);
    if (result == ffi.nullptr) return SqliteResultSet.empty();
    return SqliteResultSet.fromResult(_binding, result);
  }

  /// Runs [stmts] as a WRITE batch in a SINGLE round-trip (ABI MINOR 1),
  /// amortising the ~8µs Native Port overhead over N statements. Rows are not
  /// surfaced. Throws [QueryFailedException] on dispatch refusal or a mid-batch
  /// error (the surrounding transaction should roll back).
  ///
  /// SECURITY: [stmts] must be program-synthesized, never external input.
  Future<void> executeBatch(List<String> stmts) async {
    if (stmts.isEmpty) return;
    final port = ReceivePort();
    final n = stmts.length;
    final arr = malloc<ffi.Pointer<Utf8>>(n);
    final allocated = <ffi.Pointer<Utf8>>[];
    int code;
    try {
      for (var i = 0; i < n; i++) {
        final p = stmts[i].toNativeUtf8();
        allocated.add(p);
        arr[i] = p;
      }
      final status =
          _binding.poolSubmitBatch(_conn, arr, n, port.sendPort.nativePort, 0);
      if (status != 1) {
        throw QueryFailedException(
            stmts.first, 'SQLite refused batch dispatch');
      }
      code = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(arr);
      port.close();
    }
    if (code == SqliteWorkerPortCode.aborted) {
      final msg = _binding.lastError(_conn).toDartString();
      throw QueryFailedException(
          stmts.first, msg.isEmpty ? 'batch failed' : msg);
    }
    final r = _binding.pollResult(_conn);
    if (r != ffi.nullptr) _binding.clearResult(r);
  }

  /// Runs [reads] in a SINGLE round-trip (ABI MINOR 1), returning the N result
  /// sets in order. Amortises the port overhead. Throws [QueryFailedException]
  /// on refusal or a mid-batch error. Caller releases each result.
  ///
  /// SECURITY: [reads] must be program-synthesized.
  Future<List<SqliteResultSet>> executeMultiRead(List<String> reads) async {
    if (reads.isEmpty) return const [];
    final port = ReceivePort();
    final n = reads.length;
    final arr = malloc<ffi.Pointer<Utf8>>(n);
    final allocated = <ffi.Pointer<Utf8>>[];
    int code;
    try {
      for (var i = 0; i < n; i++) {
        final p = reads[i].toNativeUtf8();
        allocated.add(p);
        arr[i] = p;
      }
      final status = _binding.poolSubmitMultiRead(
          _conn, arr, n, port.sendPort.nativePort, 0);
      if (status != 1) {
        throw QueryFailedException(reads.first, 'SQLite refused multi-read');
      }
      code = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(arr);
      port.close();
    }
    if (code == SqliteWorkerPortCode.aborted) {
      final msg = _binding.lastError(_conn).toDartString();
      throw QueryFailedException(
          reads.first, msg.isEmpty ? 'multi-read failed' : msg);
    }
    final out = <SqliteResultSet>[];
    for (var i = 0; i < n; i++) {
      final r = _binding.pollResult(_conn);
      out.add(r == ffi.nullptr
          ? SqliteResultSet.empty()
          : SqliteResultSet.fromResult(_binding, r));
    }
    return out;
  }

  /// SYNCHRONOUS fast-path (ABI MINOR 2) for LIGHT queries: runs [sql] on the
  /// calling thread, skipping the Native Port + worker thread hop (the ~8µs
  /// machinery). Returns the result **synchronously** (not a `Future`).
  ///
  /// Blocks the isolate for the query's duration — use ONLY for cheap queries
  /// (point-reads); use [execute] for heavy scans (which stay off the isolate).
  /// Throws [StateError] if an async op is still pending on this connection
  /// (the sync path is refused; await your pending [execute] first).
  SqliteResultSet executeSync(String sql) {
    final sqlPtr = sql.toNativeUtf8();
    int code;
    try {
      code = _binding.execSync(_conn, sqlPtr);
    } finally {
      malloc.free(sqlPtr);
    }
    if (code == 0) {
      throw StateError(
          'executeSync refused: an async op is pending on this connection.');
    }
    if (code == SqliteWorkerPortCode.aborted) {
      final msg = _binding.lastError(_conn).toDartString();
      throw QueryFailedException(sql, msg.isEmpty ? 'query failed' : msg);
    }
    final result = _binding.pollResult(_conn);
    if (result == ffi.nullptr) return SqliteResultSet.empty();
    return SqliteResultSet.fromResult(_binding, result);
  }
}
