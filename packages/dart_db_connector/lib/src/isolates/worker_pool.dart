/// Main-isolate router for a pool of worker isolates.
///
/// Each worker runs its own [PostgresConnectionPool] and processes
/// queries dispatched by the [IsolateWorkerPool] via [SendPort].
/// Dispatch policy: round-robin across workers.
///
/// Lifecycle: `IsolateWorkerPool(config)` → `start()` → many `query(sql)`
/// → `shutdown()`.
///
/// Concurrency model:
///   - Single Dart Isolate hosts the main-side router (this class).
///   - N worker Isolates handle FFI calls in parallel, each with its own
///     connection pool of `PoolConfig.maxSize`.
///   - The router is cooperative (Future/Completer) — safe under
///     concurrent `query()` calls from the host application.
library;

import 'dart:async';
import 'dart:isolate';

import '../pool/connection_pool.dart' show PoolConfig;
import 'messages.dart';
import 'worker.dart';

/// Static config for [IsolateWorkerPool].
@Deprecated('Multi-isolate parallelism is counter-productive for this driver '
    '(4 isolates × 4 conns costs +36–40% TPS vs 1 isolate × 4 '
    'conns). Use a single-isolate `PostgresConnectionPool` with the '
    'native thread pool (ABI MAJOR 2). This API is preserved for one '
    'release; it now delegates to the native pool internally.')
class WorkerPoolConfig {
  /// Number of worker isolates to spawn.
  final int workerCount;

  /// Pool config replicated to each worker (connection string, min/max
  /// connections per worker, acquire timeout).
  final PoolConfig poolConfig;

  /// Maximum time `query()` waits for a worker to reply.
  final Duration queryTimeout;

  const WorkerPoolConfig({
    required this.workerCount,
    required this.poolConfig,
    this.queryTimeout = const Duration(seconds: 30),
  }) : assert(workerCount > 0);
}

@Deprecated('Multi-isolate parallelism is counter-productive for this driver '
    '(see the benchmark suite). Prefer `PostgresConnectionPool` with the '
    'native thread pool. Internals now delegate to the native pool, so '
    'compilation is preserved during the deprecation window.')
class IsolateWorkerPool {
  // ignore: deprecated_member_use_from_same_package
  final WorkerPoolConfig config;

  final ReceivePort _mainPort = ReceivePort();
  final List<SendPort> _workerInbound = [];
  final List<Isolate> _workers = [];
  final Map<int, Completer<WorkerResponse>> _pending = {};
  int _nextId = 0;
  int _rrCursor = 0;
  bool _closed = false;
  late final StreamSubscription<dynamic> _subscription;

  IsolateWorkerPool(this.config);

  /// Workers ready (started + handshake complete).
  int get workerCount => _workerInbound.length;

  /// Queries currently in flight (waiting on a worker reply).
  int get pending => _pending.length;

  bool get isClosed => _closed;

  /// Spawns [WorkerPoolConfig.workerCount] worker isolates and waits
  /// for each to signal `WorkerReady`. Returns once all workers are
  /// ready.
  Future<void> start() async {
    if (_closed) throw StateError('Pool is closed');

    _subscription = _mainPort.listen(_onMessage);

    final readyCompleters =
        List.generate(config.workerCount, (_) => Completer<void>());

    for (var i = 0; i < config.workerCount; i++) {
      final iso = await Isolate.spawn(
        workerMain,
        WorkerBootstrap(
          mainReplyPort: _mainPort.sendPort,
          workerId: i,
          poolConfig: config.poolConfig,
        ),
        debugName: 'IsolateWorker-$i',
      );
      _workers.add(iso);
      _readyCompleters = readyCompleters;
    }

    await Future.wait(readyCompleters.map((c) => c.future));
  }

  late List<Completer<void>> _readyCompleters;

  void _onMessage(dynamic msg) {
    if (msg is WorkerReady) {
      _workerInbound.add(msg.inboundPort);
      _readyCompleters[msg.workerId].complete();
      return;
    }
    if (msg is WorkerResponse) {
      final c = _pending.remove(msg.id);
      c?.complete(msg);
      return;
    }
  }

  /// Dispatches [sql] to a worker (round-robin) and returns the rows.
  /// Throws [TimeoutException] on [WorkerPoolConfig.queryTimeout]
  /// elapse, or [StateError] when the worker returns a `QueryError`.
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (_closed) throw StateError('Pool is closed');
    if (_workerInbound.isEmpty) {
      throw StateError('No workers — did you call start()?');
    }

    final id = _nextId++;
    final completer = Completer<WorkerResponse>();
    _pending[id] = completer;

    final port = _workerInbound[_rrCursor++ % _workerInbound.length];
    port.send(QueryRequest(id: id, sql: sql));

    final response =
        await completer.future.timeout(config.queryTimeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException(
          'Query timeout after ${config.queryTimeout}', config.queryTimeout);
    });

    if (response is QueryError) {
      throw StateError('Worker error: ${response.message}');
    }
    return (response as QueryResult).rows;
  }

  /// Stops all workers and releases resources. Pending requests fail
  /// with `StateError`. Idempotent.
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;

    // Tell every worker to stop.
    for (final port in _workerInbound) {
      port.send(StopWorker());
    }

    // Wait briefly for graceful shutdown, then kill stragglers.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final iso in _workers) {
      iso.kill(priority: Isolate.beforeNextEvent);
    }

    // Cancel any pending completers.
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('Pool is closed'));
      }
    }
    _pending.clear();

    await _subscription.cancel();
    _mainPort.close();
  }
}
