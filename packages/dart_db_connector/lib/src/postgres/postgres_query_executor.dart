/// Postgres-backed [QueryExecutor].
///
/// Sends one SQL statement, waits for the Native Port notification,
/// decodes the first [PGresult] into a [ResultSet], and drains any
/// additional results libpq queued (avoids "another command in
/// progress" on connection reuse — same fix as `worker.dart`).
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../bindings/postgres_binding.dart';
import '../decoder/result_row.dart';
import '../domain/unit_of_work.dart';
import 'param.dart';
import 'query_phase_diagnostics.dart';

class PostgresQueryExecutor implements QueryExecutor {
  final PostgresBinding _binding;
  final ffi.Pointer<ffi.Void> _conn;
  final Duration? _timeout;

  /// Optional per-query phase sink. When null (the default and only
  /// production path), no `Stopwatch` is allocated and the hot path pays
  /// nothing but a field read + null-check. Wired only by the
  /// `driver-us-attribution` benchmark harness.
  final QueryPhaseSink? _phaseSink;

  /// P5 (2026-07-28): when true, the next dispatch fuses a `BEGIN;`
  /// prefix into the transaction's first statement, saving the dedicated
  /// BEGIN round-trip. Armed by `PostgresUnitOfWork.begin()` through the
  /// [deferredBegin] constructor flag and consumed exactly once — on the
  /// first `execute`/`executeMultiRead`/`executePipeline` call. On the
  /// Extended path (params/binary) it degrades to a standalone BEGIN
  /// (fallback, same cost as pre-P5).
  bool _pendingBegin;

  PostgresQueryExecutor(this._binding, this._conn,
      {Duration? timeout,
      QueryPhaseSink? phaseSink,
      bool deferredBegin = false})
      : _timeout = timeout,
        _phaseSink = phaseSink,
        _pendingBegin = deferredBegin;

  @override
  Future<ResultSet> execute(
    String sql, {
    List<Param> params = const [],
    bool binaryResult = false,
  }) {
    // Fast path: zero params + text result → Simple Query Protocol
    // (no marshalling, no PQexecParams overhead). Identical to the
    // pre-ABI-MINOR-1 behaviour for backward compatibility.
    if (params.isEmpty && !binaryResult) {
      if (_pendingBegin) {
        _pendingBegin = false;
        return _executeFusedBegin(sql);
      }
      return _executeSimple(sql);
    }
    // Extended path can't carry a multi-statement `BEGIN;` prefix, so a
    // deferred BEGIN falls back to a standalone (Simple) BEGIN dispatch
    // first — transparent, same round-trip cost as the pre-P5 path.
    if (_pendingBegin) {
      _pendingBegin = false;
      return _beginThenExtended(sql, params, binaryResult);
    }
    return _executeExtended(sql, params, binaryResult);
  }

  Future<ResultSet> _beginThenExtended(
      String sql, List<Param> params, bool binaryResult) async {
    (await _executeSimple('BEGIN')).release();
    return _executeExtended(sql, params, binaryResult);
  }

  /// P5: dispatches `BEGIN; <sql>` as a single Simple-Protocol
  /// multi-statement, reusing the ABI MINOR 2 `pool_submit_multi_read`
  /// primitive (no new ABI). The head PGresult is the BEGIN's —
  /// validated (`COMMAND_OK`) and discarded; the first statement's
  /// result then flows through the standard [_drainResults] path, which
  /// already surfaces a real server error message and drains the
  /// connection clean. Saves one round-trip per transaction.
  Future<ResultSet> _executeFusedBegin(String sql) async {
    final native = malloc<ffi.Pointer<Utf8>>(2);
    final beginPtr = 'BEGIN'.toNativeUtf8();
    final sqlPtr = sql.toNativeUtf8();
    final port = ReceivePort();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    try {
      native[0] = beginPtr;
      native[1] = sqlPtr;
      final status = _binding.poolSubmitMultiRead(
          _conn, native, 2, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(
            sql, 'libpq refused to send query (fused BEGIN)');
      }
      portCode = await port.first as int;
    } finally {
      malloc.free(beginPtr);
      malloc.free(sqlPtr);
      malloc.free(native);
      port.close();
    }
    if (portCode == 2) {
      final t = _timeout;
      if (t != null) throw QueryTimeoutException(sql, t);
      throw QueryFailedException(
          sql, 'fused BEGIN aborted (connection error or shutdown)');
    }
    _consumeFusedBeginResult();
    // Next result is the first statement's — reuse the head-decode +
    // drain path (handles error-with-message + connection cleanup).
    return _drainResults(sql, binary: false);
  }

  /// Pulls and validates the leading BEGIN [PGresult] of a fused
  /// dispatch. A BEGIN error (rare — `begin()` guards against nesting)
  /// is surfaced with the real server message after draining the chain.
  void _consumeFusedBeginResult() {
    final beginR = _binding.pollResult(_conn);
    if (beginR == ffi.nullptr) return;
    final st = _binding.getResultStatus(beginR);
    if (PgExecStatus.isError(st)) {
      final msg = _binding.getErrorMessage(beginR).toDartString();
      _binding.clearResult(beginR);
      _drainRemaining();
      throw QueryFailedException('BEGIN', msg.isEmpty ? 'BEGIN failed' : msg);
    }
    _binding.clearResult(beginR);
  }

  Future<ResultSet> _executeSimple(String sql) async {
    final sink = _phaseSink;
    final sw = sink == null ? null : (Stopwatch()..start());
    final port = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    var submitUs = 0, waitUs = 0;
    try {
      final status = _binding.poolSubmitQuery(
          _conn, sqlPtr, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(sql, 'libpq refused to send query');
      }
      if (sw != null) {
        submitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
      portCode = await port.first as int;
      if (sw != null) {
        waitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
    } finally {
      malloc.free(sqlPtr);
      port.close();
    }
    if (portCode == 2) {
      // Watcher thread already issued PQcancel; the connection is in
      // an undefined state and should not be reused for poll_result.
      throw QueryTimeoutException(sql, _timeout!);
    }
    // `sw` keeps running through _drainResults → elapsed == decode phase.
    final rs = _drainResults(sql, binary: false);
    if (sink != null) {
      sink(QueryPhases(
        submitUs: submitUs,
        waitUs: waitUs,
        decodeUs: sw!.elapsedMicroseconds,
        rowCount: rs.rowCount,
        colCount: rs.colCount,
      ));
    }
    return rs;
  }

  /// Extended Query Protocol path (ABI MINOR 1, 2026-05-23).
  /// Sends [sql] with bound [params] via `pool_submit_query_params`.
  /// The native side dup-copies every buffer before returning, so we
  /// release the marshalled FFI memory immediately after dispatch.
  Future<ResultSet> _executeExtended(
      String sql, List<Param> params, bool binaryResult) async {
    final sink = _phaseSink;
    final sw = sink == null ? null : (Stopwatch()..start());
    final port = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    // `marshalled` is assigned inside the try so a throw from
    // `marshalParams` (e.g. range-check on Param.int2) still hits
    // the finally that releases sqlPtr + port without dereferencing
    // an uninitialised handle.
    MarshalledParams? marshalled;
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    var submitUs = 0, waitUs = 0;
    try {
      marshalled = marshalParams(params);
      final status = _binding.poolSubmitQueryParams(
        _conn,
        sqlPtr,
        marshalled.count,
        marshalled.types,
        marshalled.values,
        marshalled.lengths,
        marshalled.formats,
        binaryResult ? 1 : 0,
        port.sendPort.nativePort,
        timeoutMs,
      );
      if (status != 1) {
        throw QueryFailedException(sql, 'libpq refused to send query (params)');
      }
      if (sw != null) {
        // Extended-path submit also covers `marshalParams`.
        submitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
      portCode = await port.first as int;
      if (sw != null) {
        waitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
    } finally {
      // The C side dup-copied; safe to free our buffers as soon as
      // dispatch returned (even before the worker finishes).
      malloc.free(sqlPtr);
      if (marshalled != null) freeMarshalledParams(marshalled);
      port.close();
    }
    if (portCode == 2) {
      throw QueryTimeoutException(sql, _timeout!);
    }
    final rs = _drainResults(sql, binary: binaryResult);
    if (sink != null) {
      sink(QueryPhases(
        submitUs: submitUs,
        waitUs: waitUs,
        decodeUs: sw!.elapsedMicroseconds,
        rowCount: rs.rowCount,
        colCount: rs.colCount,
      ));
    }
    return rs;
  }

  /// Pulls the head [PGresult] off the conn, builds a [ResultSet] from
  /// it, and drains any trailing results (multi-statement queries) to
  /// keep the conn idle for the next dispatch. Mirrors the worker
  /// loop's drain-or-leak pattern.
  ///
  /// ABI MINOR 2: the head result's status is inspected — a SQL error
  /// (e.g. `SELECT * FROM missing_table`) previously surfaced as an
  /// empty [ResultSet]; it now throws [QueryFailedException] carrying
  /// the real server message. The connection is drained clean before
  /// throwing so the next dispatch starts fresh.
  ResultSet _drainResults(String sql, {required bool binary}) {
    final result = _binding.pollResult(_conn);
    if (result == ffi.nullptr) {
      return ResultSet.empty();
    }
    final status = _binding.getResultStatus(result);
    if (PgExecStatus.isError(status)) {
      final msg = _binding.getErrorMessage(result).toDartString();
      _binding.clearResult(result);
      _drainRemaining();
      throw QueryFailedException(sql, msg.isEmpty ? 'query failed' : msg);
    }
    final rs = ResultSet.fromResult(_binding, result, binary: binary);
    _drainRemaining();
    return rs;
  }

  /// Clears every remaining `PGresult` on the conn so it is idle for
  /// the next dispatch. Safe to call when nothing is pending.
  void _drainRemaining() {
    while (true) {
      final extra = _binding.pollResult(_conn);
      if (extra == ffi.nullptr) break;
      _binding.clearResult(extra);
    }
  }

  /// Runs [reads] in a SINGLE network round-trip (ABI MINOR 2),
  /// returning the N result sets in statement order. Amortises the
  /// ~8 µs async-machine cost plus one network RTT over N reads — the
  /// Postgres materialisation of the F1b lever already shipped for
  /// MySQL/SQLite.
  ///
  /// The statements run in the Simple Query Protocol as one
  /// multi-statement string, so they share a single implicit
  /// transaction: an error in statement K rolls back the earlier
  /// statements of this call and the server skips K+1..N (the returned
  /// list would otherwise be short — instead this throws).
  ///
  /// On an error result, every [ResultSet] already collected is
  /// released and a [QueryFailedException] is thrown naming the culprit
  /// statement and carrying the real server message. On timeout /
  /// connection abort, throws [QueryTimeoutException] (when a timeout is
  /// configured) or [QueryFailedException].
  ///
  /// The caller owns each returned [ResultSet] and must `release()` it.
  ///
  /// SECURITY: [reads] must be program-synthesized, never external
  /// input — values travel as SQL text. For untrusted values use
  /// [execute] with `params` (Extended Query Protocol), one per call.
  Future<List<ResultSet>> executeMultiRead(List<String> reads) async {
    if (reads.isEmpty) {
      // Degenerate: a deferred BEGIN with no reads still needs to open
      // the transaction so the caller's commit/rollback has a txn to
      // act on. Fall back to a standalone BEGIN.
      if (_pendingBegin) {
        _pendingBegin = false;
        (await _executeSimple('BEGIN')).release();
      }
      return const [];
    }
    // P5: fuse the deferred BEGIN as the chain's first statement.
    final fused = _pendingBegin;
    _pendingBegin = false;
    final n = reads.length;
    final total = fused ? n + 1 : n;
    final native = malloc<ffi.Pointer<Utf8>>(total);
    final allocated = <ffi.Pointer<Utf8>>[];
    final port = ReceivePort();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    try {
      var slot = 0;
      if (fused) {
        final b = 'BEGIN'.toNativeUtf8();
        allocated.add(b);
        native[slot++] = b;
      }
      for (var i = 0; i < n; i++) {
        final p = reads[i].toNativeUtf8();
        allocated.add(p);
        native[slot++] = p;
      }
      final status = _binding.poolSubmitMultiRead(
          _conn, native, total, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(reads.first,
            'multi-read dispatch failed (slot busy or libpq error)');
      }
      portCode = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(native);
      port.close();
    }
    if (portCode == 2) {
      final t = _timeout;
      if (t != null) throw QueryTimeoutException(reads.first, t);
      throw QueryFailedException(
          reads.first, 'multi-read aborted (connection error or shutdown)');
    }

    // Consume the fused BEGIN result before the statement loop so error
    // indexing below still maps 1:1 to `reads`.
    if (fused) _consumeFusedBeginResult();

    final out = <ResultSet>[];
    for (var i = 0; i < n; i++) {
      final r = _binding.pollResult(_conn);
      if (r == ffi.nullptr) break; // chain shorter than N (aborted txn)
      final status = _binding.getResultStatus(r);
      if (PgExecStatus.isError(status)) {
        final msg = _binding.getErrorMessage(r).toDartString();
        _binding.clearResult(r);
        _drainRemaining();
        for (final rs in out) {
          rs.release();
        }
        throw QueryFailedException(
            reads[i], msg.isEmpty ? 'query failed' : msg);
      }
      out.add(ResultSet.fromResult(_binding, r, binary: false));
    }
    return out;
  }

  /// Executes [queries] in libpq pipeline mode — all N queries sent
  /// in a single network round-trip; the watcher drains all results
  /// + sync point.
  ///
  /// **v1 limitation:** result rows are **not accessible** to the
  /// caller (libpq's PGresult ownership semantics conflict with our
  /// counting strategy in the watcher). Returns `Future<void>`. Best
  /// suited for bulk write patterns (`INSERT`/`UPDATE`/`DELETE`) where
  /// command tags suffice.
  ///
  /// **Composable inside an external transaction (since 2026-07-29):**
  /// a healthy open transaction survives the pipeline, so the pattern
  /// `withTransaction(pool, (exec) => exec.executePipeline(writes))`
  /// persists the writes on the outer `COMMIT`. An aborted transaction
  /// (a mid-pipeline error) is still rolled back natively before the
  /// connection returns to the pool. For a self-contained batch that
  /// owns its own `BEGIN`/`COMMIT`, prefer [withPipelinedTransaction].
  /// If you open a `BEGIN` via a raw pipeline yourself, the matching
  /// `COMMIT`/`ROLLBACK` is your responsibility.
  ///
  /// SELECTs in pipeline are **dispatched** correctly but their rows
  /// are discarded. For interactive query→decide→query patterns, use
  /// sequential `execute()`.
  ///
  /// Added in ABI MAJOR 1 MINOR 1.
  Future<void> executePipeline(List<String> queries) async {
    // A deferred BEGIN is sent standalone here rather than fused as the
    // pipeline's first query. Fusing it is a valid optimization now that
    // the pipeline primitive only rolls back an *aborted* (INERROR)
    // transaction and leaves a healthy open one alone (2026-07-29, see
    // `native_pool_worker.c`), so a fused BEGIN whose COMMIT arrives on a
    // later submit would survive — but that saving is deferred to its own
    // perf change (needs a benchmark). The common transaction shape
    // (reads via `execute` before the write pipeline) already consumes
    // the pending BEGIN on that first Simple read, keeping the P5 saving.
    if (_pendingBegin) {
      _pendingBegin = false;
      (await _executeSimple('BEGIN')).release();
    }
    if (queries.isEmpty) return;

    final n = queries.length;
    final native = malloc<ffi.Pointer<Utf8>>(n);
    final allocated = <ffi.Pointer<Utf8>>[];
    final port = ReceivePort();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    try {
      for (var i = 0; i < n; i++) {
        final p = queries[i].toNativeUtf8();
        allocated.add(p);
        native[i] = p;
      }
      final status = _binding.poolSubmitPipeline(
          _conn, native, n, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(queries.first, 'pipeline dispatch failed');
      }
      portCode = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(native);
      port.close();
    }
    if (portCode == 2) {
      throw QueryTimeoutException(queries.first, _timeout!);
    }
    // Watcher already drained N+1 PGresults; nothing for caller to do.
  }
}
