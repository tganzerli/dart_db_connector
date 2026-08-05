/// MongoDB connection pool — Dart facade over the native pool.
///
/// Mirror of `mysql_connection_pool.dart` for the MongoDB driver. The C pool
/// owns the connections, worker threads, and the blocking libmongoc I/O; the
/// Dart side gates with an `_inUse` counter + waiter queue so it only ever
/// calls the non-blocking `mongo_pool_acquire(0)` probe.
///
/// Unlike the relational pools, a borrowed [MongoPooledConnection] exposes
/// document operations through [collection]; there is no SQL executor.
library;

import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import '../_internal/mongo_shared_binding.dart';
import '../bindings/mongo_binding.dart';
import '../mongo/mongo_collection.dart';
import '../native/mongo_native_pool.dart';

/// Static configuration for [MongoConnectionPool]. Coordinates are a single
/// MongoDB URI (e.g. `mongodb://user:pass@host:27017/?authSource=admin`).
class MongoPoolConfig {
  /// MongoDB connection string.
  final String uri;

  /// Informational only — the native pool eagerly allocates `maxSize`.
  final int minSize;

  /// Maximum connections held by the pool (= `maxSize` for the native pool).
  final int maxSize;

  /// Maximum time `acquire()` waits when every conn is checked out.
  final Duration acquireTimeout;

  const MongoPoolConfig({
    required this.uri,
    this.minSize = 2,
    this.maxSize = 10,
    this.acquireTimeout = const Duration(seconds: 5),
  })  : assert(minSize >= 0),
        assert(maxSize >= minSize),
        assert(maxSize > 0);
}

/// Thrown when [MongoConnectionPool.acquire] cannot obtain a connection
/// within [MongoPoolConfig.acquireTimeout].
class MongoPoolExhaustedException implements Exception {
  final Duration timeout;
  MongoPoolExhaustedException(this.timeout);

  @override
  String toString() =>
      'MongoPoolExhaustedException: no connection available within $timeout';
}

/// A borrowed connection from a [MongoConnectionPool]. Obtain a
/// [MongoCollection] via [collection]; return the conn via [release].
class MongoPooledConnection {
  final MongoConn _conn;
  final MongoConnectionPool _pool;
  bool _released = false;

  MongoPooledConnection._(this._conn, this._pool);

  /// A handle to `db.coll` document operations on this connection.
  MongoCollection collection(String db, String coll) =>
      MongoCollection(_conn, db, coll);

  /// The low-level typed connection (for driver internals / advanced use).
  MongoConn get raw => _conn;

  /// Returns the connection to the pool. Idempotent.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _conn.release();
    _pool._afterRelease();
  }

  bool get isReleased => _released;
}

/// Pool of native conns served by a single C-side `mongo_pool_t`.
///
/// Lifecycle: construct → `start()` → `acquire()` / `release()` → `close()`.
/// The FFI binding resolves automatically via the per-isolate
/// `MongoSharedBinding` singleton.
class MongoConnectionPool {
  final MongoPoolConfig config;
  final MongoBinding _binding;

  MongoNativePool? _nativePool;
  int _inUse = 0;
  final Queue<Completer<void>> _waiters = Queue();
  bool _closed = false;

  /// Default constructor — resolves the FFI binding from the per-isolate
  /// `MongoSharedBinding` singleton.
  MongoConnectionPool(this.config) : _binding = MongoSharedBinding.instance();

  /// Internal constructor accepting an explicit [MongoBinding] — tests/bench.
  @internal
  MongoConnectionPool.withBinding(this._binding, this.config);

  int get currentSize => _nativePool == null ? 0 : config.maxSize;
  int get borrowed => _inUse;
  int get idle => _nativePool == null ? 0 : config.maxSize - _inUse;
  int get pending => _waiters.length;
  bool get isClosed => _closed;

  @internal
  MongoNativePool? get nativePool => _nativePool;

  /// Spawns the native pool (`mongo_pool_create`). Idempotent.
  Future<void> start() async {
    if (_closed) throw StateError('Pool is closed');
    if (_nativePool != null) return;
    _nativePool = MongoNativePool.create(
      binding: _binding,
      uri: config.uri,
      minSize: config.minSize,
      maxSize: config.maxSize,
      acquireTimeout: config.acquireTimeout,
    );
  }

  /// Acquires a connection, gating Dart-side so `_inUse <= maxSize`. Throws
  /// [MongoPoolExhaustedException] on timeout.
  Future<MongoPooledConnection> acquire() async {
    if (_closed) throw StateError('Pool is closed');
    final pool = _nativePool;
    if (pool == null) {
      throw StateError('Pool not started — call start() first');
    }

    if (_inUse >= config.maxSize) {
      final completer = Completer<void>();
      _waiters.add(completer);
      final timer = Timer(config.acquireTimeout, () {
        if (!completer.isCompleted) {
          _waiters.remove(completer);
          completer.completeError(
              MongoPoolExhaustedException(config.acquireTimeout));
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
    final conn = pool.acquire(timeout: Duration.zero);
    return MongoPooledConnection._(conn, this);
  }

  /// Convenience: acquire → run [body] → release (even on error).
  Future<T> withConnection<T>(
      Future<T> Function(MongoPooledConnection conn) body) async {
    final conn = await acquire();
    try {
      return await body(conn);
    } finally {
      await conn.release();
    }
  }

  void _afterRelease() {
    _inUse--;
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  /// Closes the pool (`mongo_pool_destroy`). New `acquire()` calls throw.
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
