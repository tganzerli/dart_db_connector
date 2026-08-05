/// Worker isolate entry point.
///
/// Each worker:
///   1. Loads `libnative_db` locally (DynamicLibrary is per-isolate).
///   2. Initialises the Dart Native API for this isolate.
///   3. Starts a [PostgresConnectionPool].
///   4. Listens on its inbound [ReceivePort] for [QueryRequest] / [StopWorker].
///   5. Executes each query via FFI + Native Port notification, decodes
///      the result with [ResultSet], and replies on the main port.
///
/// Workers are short-lived during dev but long-lived in production (spawned
/// once at startup, processing many requests).
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../bindings/postgres_binding.dart';
import '../decoder/result_row.dart';
import '../pool/connection_pool.dart';
import 'messages.dart';

/// Top-level worker entry point (must be top-level for `Isolate.spawn`).
Future<void> workerMain(WorkerBootstrap bootstrap) async {
  // Each isolate has its own `SharedBinding` singleton (Dart statics
  // are per-isolate). `PostgresConnectionPool(...)` resolves it lazily
  // on construction — FFI is internal to the package.
  final pool = PostgresConnectionPool(bootstrap.poolConfig);
  final binding = pool.binding;
  await pool.start();

  final inbound = ReceivePort();
  bootstrap.mainReplyPort.send(WorkerReady(
    workerId: bootstrap.workerId,
    inboundPort: inbound.sendPort,
  ));

  // Fire-and-forget _processQuery futures, tracked so StopWorker can
  // await them before tearing the native pool down. Without this,
  // pool.close() (= pool_destroy → PQfinish) races against any
  // in-flight `_executeQuery` that is between `await port.first` and
  // `binding.pollResult` — a libpq use-after-free in MAJOR 2.
  final inFlight = <Future<void>>{};

  await for (final dynamic message in inbound) {
    if (message is StopWorker) {
      if (inFlight.isNotEmpty) {
        await Future.wait(inFlight);
      }
      await pool.close();
      inbound.close();
      return;
    }
    if (message is QueryRequest) {
      // Don't await — process concurrently so the worker can interleave
      // multiple in-flight queries (limited by its local pool size).
      final f = _processQuery(binding, pool, message, bootstrap.mainReplyPort);
      inFlight.add(f);
      f.whenComplete(() => inFlight.remove(f));
    }
  }
}

Future<void> _processQuery(
  PostgresBinding binding,
  PostgresConnectionPool pool,
  QueryRequest request,
  SendPort mainPort,
) async {
  PooledConnection? leased;
  try {
    leased = await pool.acquire();
    final rows = await _executeQuery(binding, leased.raw, request.sql);
    mainPort.send(QueryResult(id: request.id, rows: rows));
  } catch (e) {
    mainPort.send(QueryError(id: request.id, message: e.toString()));
  } finally {
    await leased?.release();
  }
}

/// Issues `sql` on the given `PGconn*`, waits for the notification, and
/// decodes the result into a `List<Map<String, Object?>>` using
/// [ResultSet] / [ResultRow]. Uses a per-call [ReceivePort] so multiple
/// queries on the same worker can run concurrently without confusing
/// notifications.
Future<List<Map<String, Object?>>> _executeQuery(
  PostgresBinding binding,
  ffi.Pointer<ffi.Void> conn,
  String sql,
) async {
  final port = ReceivePort();
  final sqlPtr = sql.toNativeUtf8();
  try {
    // ABI MAJOR 2 (retro B1): IsolateWorkerPool is deprecated as a
    // pattern but stays functional by delegating to the native pool.
    final status = binding.poolSubmitQuery(
        conn, sqlPtr, port.sendPort.nativePort, 0); // 0 = no timeout
    if (status != 1) {
      throw StateError('pool_submit_query returned 0 for: $sql');
    }
    final code = await port.first as int;
    if (code == 2) {
      throw StateError('worker query timed out: $sql');
    }
  } finally {
    malloc.free(sqlPtr);
    port.close();
  }

  // Consume the first PGresult, decode its rows, then drain any
  // additional PGresult objects libpq has queued (multi-statement
  // queries can produce N results). Failing to drain leaves the
  // connection in "another command in progress" state, breaking the
  // next acquire() that lands on it.
  final result = binding.pollResult(conn);
  if (result == ffi.nullptr) {
    return const [];
  }
  final rs = ResultSet.fromResult(binding, result);
  final rows = [for (final row in rs.rows) row.toMap()];
  // Rows are now materialized into Dart heap (Strings, ints, etc.);
  // the underlying PGresult buffer is no longer needed.
  rs.release();

  // Drain remaining results and free them eagerly — they never leave
  // this function, so no caller depends on their lifetime.
  while (true) {
    final extra = binding.pollResult(conn);
    if (extra == ffi.nullptr) break;
    binding.clearResult(extra);
  }

  return rows;
}
