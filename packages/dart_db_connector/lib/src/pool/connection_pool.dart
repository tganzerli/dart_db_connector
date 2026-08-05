/// PostgreSQL connection pool — Dart facade over the native pool.
///
/// ABI MAJOR 2 (2026-05-20): the pool is now a thin wrapper over the
/// C-side `native_pool_t` (`native/c/include/native_pool.h`). The C
/// pool owns the connections, the worker threads, and the libpq I/O
/// loop. The Dart side keeps a gate (`_inUse` counter + waiter queue)
/// so it never invokes the blocking `pool_acquire` — instead it calls
/// the non-blocking probe (`timeoutMs = 0`) once it knows a conn is
/// free. This avoids deadlocking the isolate's event loop when the
/// pool is briefly over-subscribed.
///
/// Public surface (`PoolConfig`, `PostgresConnectionPool`,
/// `PooledConnection`, `PoolExhaustedException`) is preserved from
/// MAJOR 1 modulo the removal of `PoolConfig.onConnectionOpen`, which
/// no longer maps cleanly onto the C pool's eager-allocation model.
/// Callers that previously ran PREPARE on each fresh conn should now
/// submit those statements through the regular execute path.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

import '../_internal/shared_binding.dart';
import '../bindings/postgres_binding.dart';
import '../native/native_pool.dart';

/// Static configuration for [PostgresConnectionPool].
///
/// Bundles the libpq connection string with sizing and timeout knobs.
/// `maxSize` is the effective concurrency ceiling — the native pool
/// eagerly allocates that many connections at startup and never grows
/// beyond it. `acquireTimeout` bounds how long [PostgresConnectionPool.acquire]
/// blocks when every connection is checked out.
///
/// Example:
/// ```dart
/// const config = PoolConfig(
///   connInfo: 'host=localhost port=5432 dbname=app user=app password=secret',
///   maxSize: 16,
///   acquireTimeout: Duration(seconds: 5),
/// );
/// final pool = PostgresConnectionPool(config);
/// ```
class PoolConfig {
  /// libpq connection string passed to `pool_create`.
  /// Example: `'host=localhost port=5432 dbname=teste user=postgres password=123'`.
  final String connInfo;

  /// Minimum connections to keep warm. Currently informational only
  /// — the native pool eagerly allocates `maxSize` conns at startup
  /// (per `native/c/src/native_pool.c`). Kept on the config surface
  /// for API stability and future warm-up policies.
  final int minSize;

  /// Maximum connections held by the pool. Matches `maxSize` passed
  /// to `pool_create`.
  final int maxSize;

  /// Maximum time `acquire()` waits when every conn is checked out.
  final Duration acquireTimeout;

  /// When true, [PostgresConnectionPool.acquire] times the wait and
  /// records queue depth, so downstream diagnostics
  /// (`pool-diagnostics-instrumentation`) can detect contention.
  /// Overhead is ≤2% TPS.
  final bool instrumentationEnabled;

  const PoolConfig({
    required this.connInfo,
    this.minSize = 2,
    this.maxSize = 10,
    this.acquireTimeout = const Duration(seconds: 5),
    this.instrumentationEnabled = false,
  })  : assert(minSize >= 0),
        assert(maxSize >= minSize),
        assert(maxSize > 0);
}

/// Thrown when [PostgresConnectionPool.acquire] cannot obtain a
/// connection within [PoolConfig.acquireTimeout].
///
/// Indicates sustained over-subscription: every connection is in use
/// and no waiter slot opened up in time. The pool stays usable —
/// callers can retry, back off, or raise `maxSize`.
class PoolExhaustedException implements Exception {
  final Duration timeout;
  PoolExhaustedException(this.timeout);

  @override
  String toString() =>
      'PoolExhaustedException: no connection available within $timeout';
}

/// A borrowed connection from a [PostgresConnectionPool].
///
/// Returned by [PostgresConnectionPool.acquire] and must be returned
/// via [release] — preferably from a `try`/`finally` to avoid leaking
/// a slot. Holding past `release()` is undefined behaviour: the slot
/// goes back to the pool and may be reissued to another caller.
///
/// Example:
/// ```dart
/// final leased = await pool.acquire();
/// try {
///   // use leased.raw via the binding
/// } finally {
///   await leased.release();
/// }
/// ```
class PooledConnection {
  /// Underlying native handle. In ABI MAJOR 2 this is a
  /// `native_conn_t*`, not a raw `PGconn*` — pass to
  /// `PostgresBinding.poolSubmitQuery` / `.pollResult` /
  /// `.poolCancel`. The Dart-side type stays `Pointer<Void>` so the
  /// existing test surface keeps compiling.
  final ffi.Pointer<ffi.Void> raw;

  /// Time waited in [PostgresConnectionPool.acquire] before this
  /// connection was obtained, in microseconds. Null when
  /// [PoolConfig.instrumentationEnabled] is false.
  final int? acquireWaitUs;

  /// Length of the waiter queue at the moment `acquire()` was called.
  /// Null when [PoolConfig.instrumentationEnabled] is false; 0 on the
  /// fast path.
  final int? queueDepthAtAcquire;

  final PostgresConnectionPool _pool;
  bool _released = false;

  PooledConnection._(
    this.raw,
    this._pool, {
    this.acquireWaitUs,
    this.queueDepthAtAcquire,
  });

  /// Returns the connection to the pool. Idempotent.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _pool._release(raw);
  }

  bool get isReleased => _released;
}

/// Pool of native conns served by a single C-side `native_pool_t`.
///
/// Lifecycle: construct → `start()` → use `acquire()` / `release()` →
/// `close()`.
///
/// Usage (recommended):
/// ```dart
/// final pool = PostgresConnectionPool(PoolConfig(connInfo: '...'));
/// await pool.start();
/// final c = await pool.acquire();
/// try {
///   // ... use c ...
/// } finally {
///   await c.release();
/// }
/// await pool.close();
/// ```
///
/// The FFI binding is resolved automatically via a per-isolate
/// `SharedBinding` singleton — consumers never need to call
/// `loadNativeDb()` or instantiate `PostgresBinding` themselves.
class PostgresConnectionPool {
  final PoolConfig config;
  final PostgresBinding _binding;

  NativePool? _nativePool;
  int _inUse = 0;

  /// Pending acquires waiting for a release. Drained FIFO so a
  /// long-blocked caller eventually wins.
  final Queue<Completer<void>> _waiters = Queue();

  bool _closed = false;

  /// Default constructor — resolves the FFI binding internally from
  /// the per-isolate `SharedBinding` singleton. This is the only
  /// constructor consumers of the public API should use.
  PostgresConnectionPool(this.config) : _binding = SharedBinding.instance();

  /// Internal constructor that accepts an explicit [PostgresBinding].
  /// Used by tests, the bench harness, and the in-isolate worker of
  /// the (deprecated) `IsolateWorkerPool`. Not part of the public API.
  @internal
  PostgresConnectionPool.withBinding(this._binding, this.config);

  /// Underlying [PostgresBinding] — internal accessor for code paths
  /// that need direct FFI access (e.g. `PostgresQueryExecutor`,
  /// `withTransaction`). Not part of the public API.
  @internal
  PostgresBinding get binding => _binding;

  /// Total connections currently managed by the C pool. Constant
  /// (`config.maxSize`) once [start] has run.
  int get currentSize => _nativePool == null ? 0 : config.maxSize;

  /// Connections currently checked out by consumers.
  int get borrowed => _inUse;

  /// Connections currently idle in the C pool (eligible for
  /// `pool_acquire(0)`).
  int get idle => _nativePool == null ? 0 : config.maxSize - _inUse;

  /// Pending `acquire()` calls waiting on a free connection.
  int get pending => _waiters.length;

  bool get isClosed => _closed;

  /// Underlying native pool. Exposed for tests and the FFI test
  /// harness; do not retain across [close].
  NativePool? get nativePool => _nativePool;

  /// Spawns the native pool (`pool_create`) with all `maxSize` conns
  /// + worker threads. Idempotent.
  Future<void> start() async {
    if (_closed) throw StateError('Pool is closed');
    if (_nativePool != null) return;
    _nativePool = NativePool.create(
      binding: _binding,
      conninfo: config.connInfo,
      minSize: config.minSize,
      maxSize: config.maxSize,
      acquireTimeout: config.acquireTimeout,
    );
  }

  /// Acquires a connection. Gates Dart-side to keep `_inUse <=
  /// maxSize` so the C-side `pool_acquire(0)` probe always succeeds
  /// immediately. Throws [PoolExhaustedException] on timeout.
  Future<PooledConnection> acquire() async {
    if (_closed) throw StateError('Pool is closed');
    final pool = _nativePool;
    if (pool == null) {
      throw StateError('Pool not started — call start() first');
    }

    final instrumented = config.instrumentationEnabled;
    final stopwatch = instrumented ? (Stopwatch()..start()) : null;
    final initialDepth = instrumented ? _waiters.length : null;

    if (_inUse >= config.maxSize) {
      final completer = Completer<void>();
      _waiters.add(completer);
      final timer = Timer(config.acquireTimeout, () {
        if (!completer.isCompleted) {
          _waiters.remove(completer);
          completer
              .completeError(PoolExhaustedException(config.acquireTimeout));
        }
      });
      try {
        await completer.future;
        timer.cancel();
      } catch (_) {
        timer.cancel();
        rethrow;
      }
    }

    _inUse++;
    final conn = pool.acquire(timeout: Duration.zero).ptr;
    stopwatch?.stop();
    return PooledConnection._(
      conn,
      this,
      acquireWaitUs: stopwatch?.elapsedMicroseconds,
      queueDepthAtAcquire: initialDepth,
    );
  }

  void _release(ffi.Pointer<ffi.Void> conn) {
    final pool = _nativePool;
    if (pool != null) {
      _binding.poolRelease(pool.ptr, conn);
    }
    _inUse--;
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  /// Closes the pool. Calls `pool_destroy` once any in-flight waiters
  /// resolve. New `acquire()` calls throw `StateError`.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(StateError('Pool is closed'));
    }

    _nativePool?.destroy();
    _nativePool = null;
  }
}
