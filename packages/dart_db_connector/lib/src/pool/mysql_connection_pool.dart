/// MySQL connection pool — Dart facade over the native pool.
///
/// Mirror of `connection_pool.dart` (PostgreSQL) for the MySQL driver.
/// The C pool owns the connections, worker threads, and the blocking
/// libmysqlclient I/O. The Dart side keeps a gate (`_inUse` counter +
/// waiter queue) so it never invokes the blocking `mysql_pool_acquire` —
/// it calls the non-blocking probe (`timeoutMs = 0`) once it knows a
/// conn is free.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

import '../_internal/mysql_shared_binding.dart';
import '../bindings/mysql_binding.dart';
import '../native/mysql_native_pool.dart';

/// Static configuration for [MysqlConnectionPool].
///
/// Unlike [PoolConfig] (a single libpq conninfo string), MySQL
/// coordinates are discrete, matching `mysql_real_connect`.
///
/// Example:
/// ```dart
/// const config = MysqlPoolConfig(
///   host: 'localhost',
///   user: 'app',
///   password: 'secret',
///   database: 'app',
///   maxSize: 16,
/// );
/// final pool = MysqlConnectionPool(config);
/// ```
class MysqlPoolConfig {
  /// MySQL server host passed to `mysql_real_connect`.
  final String host;

  /// TCP port (default 3306).
  final int port;

  /// Login user.
  final String user;

  /// Login password.
  final String password;

  /// Default schema to select on connect. Null selects none.
  final String? database;

  /// Minimum connections to keep warm. Informational only — the native
  /// pool eagerly allocates `maxSize` conns at startup.
  final int minSize;

  /// Maximum connections held by the pool. Matches `maxSize` passed to
  /// `mysql_pool_create`.
  final int maxSize;

  /// Maximum time `acquire()` waits when every conn is checked out.
  final Duration acquireTimeout;

  /// When true, [MysqlConnectionPool.acquire] times the wait and records
  /// queue depth for downstream diagnostics. Overhead is ≤2% TPS.
  final bool instrumentationEnabled;

  const MysqlPoolConfig({
    required this.host,
    required this.user,
    required this.password,
    this.database,
    this.port = 3306,
    this.minSize = 2,
    this.maxSize = 10,
    this.acquireTimeout = const Duration(seconds: 5),
    this.instrumentationEnabled = false,
  })  : assert(minSize >= 0),
        assert(maxSize >= minSize),
        assert(maxSize > 0);
}

/// Thrown when [MysqlConnectionPool.acquire] cannot obtain a connection
/// within [MysqlPoolConfig.acquireTimeout].
class MysqlPoolExhaustedException implements Exception {
  final Duration timeout;
  MysqlPoolExhaustedException(this.timeout);

  @override
  String toString() =>
      'MysqlPoolExhaustedException: no connection available within $timeout';
}

/// A borrowed connection from a [MysqlConnectionPool]. Return via
/// [release] — preferably from a `try`/`finally`.
class MysqlPooledConnection {
  /// Underlying `mysql_conn_t*` — pass to `MysqlBinding.poolSubmitQuery`
  /// / `.pollResult` / `.poolCancel`. Dart-side type is `Pointer<Void>`.
  final ffi.Pointer<ffi.Void> raw;

  /// Time waited in `acquire()` before this conn was obtained, in
  /// microseconds. Null when instrumentation is disabled.
  final int? acquireWaitUs;

  /// Waiter-queue length when `acquire()` was called. Null when
  /// instrumentation is disabled; 0 on the fast path.
  final int? queueDepthAtAcquire;

  final MysqlConnectionPool _pool;
  bool _released = false;

  MysqlPooledConnection._(
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

/// Pool of native conns served by a single C-side `mysql_pool_t`.
///
/// Lifecycle: construct → `start()` → `acquire()` / `release()` →
/// `close()`. The FFI binding is resolved automatically via a
/// per-isolate `MysqlSharedBinding` singleton.
class MysqlConnectionPool {
  final MysqlPoolConfig config;
  final MysqlBinding _binding;

  MysqlNativePool? _nativePool;
  int _inUse = 0;

  final Queue<Completer<void>> _waiters = Queue();

  bool _closed = false;

  /// Default constructor — resolves the FFI binding internally from the
  /// per-isolate `MysqlSharedBinding` singleton.
  MysqlConnectionPool(this.config) : _binding = MysqlSharedBinding.instance();

  /// Internal constructor that accepts an explicit [MysqlBinding]. Used
  /// by tests and the bench harness. Not part of the public API.
  @internal
  MysqlConnectionPool.withBinding(this._binding, this.config);

  /// Underlying [MysqlBinding] — internal accessor for code paths that
  /// need direct FFI access (e.g. `MysqlQueryExecutor`).
  @internal
  MysqlBinding get binding => _binding;

  /// Total connections managed by the C pool (`config.maxSize` once
  /// started).
  int get currentSize => _nativePool == null ? 0 : config.maxSize;

  /// Connections currently checked out by consumers.
  int get borrowed => _inUse;

  /// Connections currently idle in the C pool.
  int get idle => _nativePool == null ? 0 : config.maxSize - _inUse;

  /// Pending `acquire()` calls waiting on a free connection.
  int get pending => _waiters.length;

  bool get isClosed => _closed;

  /// Underlying native pool. Exposed for tests; do not retain across
  /// [close].
  MysqlNativePool? get nativePool => _nativePool;

  /// Spawns the native pool (`mysql_pool_create`) with all `maxSize`
  /// conns + worker threads. Idempotent.
  Future<void> start() async {
    if (_closed) throw StateError('Pool is closed');
    if (_nativePool != null) return;
    _nativePool = MysqlNativePool.create(
      binding: _binding,
      host: config.host,
      user: config.user,
      password: config.password,
      database: config.database,
      port: config.port,
      minSize: config.minSize,
      maxSize: config.maxSize,
      acquireTimeout: config.acquireTimeout,
    );
  }

  /// Acquires a connection. Gates Dart-side to keep `_inUse <= maxSize`
  /// so the C-side `mysql_pool_acquire(0)` probe always succeeds
  /// immediately. Throws [MysqlPoolExhaustedException] on timeout.
  Future<MysqlPooledConnection> acquire() async {
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
          completer.completeError(
              MysqlPoolExhaustedException(config.acquireTimeout));
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
    return MysqlPooledConnection._(
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

  /// Closes the pool. Calls `mysql_pool_destroy` once any in-flight
  /// waiters resolve. New `acquire()` calls throw `StateError`.
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
