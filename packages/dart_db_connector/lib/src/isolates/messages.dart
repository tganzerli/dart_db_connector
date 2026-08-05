/// Messages exchanged between the main isolate and worker isolates.
///
/// **Important:** every field used here must be SendPort-serializable —
/// primitives (`int`, `String`, `bool`, `double`), `List`, `Map`,
/// `Uint8List`, and other `SendPort`s. Native pointers (`Pointer<ffi.Void>`)
/// CANNOT cross isolate boundaries; each worker manages its own pool of
/// `PGconn*` locally.
library;

import 'dart:isolate';

import '../pool/connection_pool.dart' show PoolConfig;

/// Bootstrap config sent from main → worker on spawn.
class WorkerBootstrap {
  final SendPort mainReplyPort;
  final int workerId;
  final PoolConfig poolConfig;

  WorkerBootstrap({
    required this.mainReplyPort,
    required this.workerId,
    required this.poolConfig,
  });
}

/// Sent from worker → main once the worker is ready to accept requests.
class WorkerReady {
  final int workerId;

  /// The worker's inbound port. Main sends [WorkerCommand] / [QueryRequest]
  /// to this port.
  final SendPort inboundPort;

  WorkerReady({required this.workerId, required this.inboundPort});
}

/// Sent from main → worker. Marker types only.
sealed class WorkerCommand {}

/// Graceful stop. Worker drains current request (if any), closes pool,
/// shuts down its isolate.
class StopWorker extends WorkerCommand {}

/// A query request dispatched to a worker.
class QueryRequest {
  /// Unique identifier within the main pool. Used to match the response
  /// back to the caller's completer.
  final int id;

  /// SQL text. Simple-query protocol (no parameters yet — params arrive
  /// with the prepared-statements-binary-format task).
  final String sql;

  const QueryRequest({required this.id, required this.sql});
}

/// Worker → main response.
sealed class WorkerResponse {
  final int id;
  const WorkerResponse(this.id);
}

/// Successful result: rows materialised as `Map<String, Object?>` (each
/// row from `ResultRow.toMap()`).
class QueryResult extends WorkerResponse {
  final List<Map<String, Object?>> rows;
  final int affectedRows;
  const QueryResult(
      {required int id, required this.rows, this.affectedRows = 0})
      : super(id);
}

/// Error raised inside the worker (libpq failure, decode error, etc.).
class QueryError extends WorkerResponse {
  final String message;
  const QueryError({required int id, required this.message}) : super(id);
}
