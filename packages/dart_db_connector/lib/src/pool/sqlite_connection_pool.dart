/// SQLite connection pool — Dart facade over the native pool. Mirror of
/// `mysql_connection_pool.dart`. Coordinates are a DB file [path] (+ WAL
/// busy timeout), not a network endpoint.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

import '../_internal/sqlite_shared_binding.dart';
import '../bindings/sqlite_binding.dart';
import '../native/sqlite_native_pool.dart';

class SqlitePoolConfig {
  /// Path to the SQLite database file (WAL). Use a file, not `:memory:`
  /// (each conn would get a private in-memory DB).
  final String path;
  final int minSize;
  final int maxSize;
  final Duration acquireTimeout;
  final Duration busyTimeout;

  const SqlitePoolConfig({
    required this.path,
    this.minSize = 2,
    this.maxSize = 4,
    this.acquireTimeout = const Duration(seconds: 5),
    this.busyTimeout = const Duration(seconds: 5),
  })  : assert(minSize >= 0),
        assert(maxSize >= minSize),
        assert(maxSize > 0);
}

class SqlitePoolExhaustedException implements Exception {
  final Duration timeout;
  SqlitePoolExhaustedException(this.timeout);
  @override
  String toString() =>
      'SqlitePoolExhaustedException: no connection available within $timeout';
}

class SqlitePooledConnection {
  final ffi.Pointer<ffi.Void> raw;
  final SqliteConnectionPool _pool;
  bool _released = false;

  SqlitePooledConnection._(this.raw, this._pool);

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _pool._release(raw);
  }

  bool get isReleased => _released;
}

class SqliteConnectionPool {
  final SqlitePoolConfig config;
  final SqliteBinding _binding;

  SqliteNativePool? _nativePool;
  int _inUse = 0;
  final Queue<Completer<void>> _waiters = Queue();
  bool _closed = false;

  SqliteConnectionPool(this.config) : _binding = SqliteSharedBinding.instance();

  @internal
  SqliteConnectionPool.withBinding(this._binding, this.config);

  @internal
  SqliteBinding get binding => _binding;

  int get currentSize => _nativePool == null ? 0 : config.maxSize;
  int get borrowed => _inUse;
  int get idle => _nativePool == null ? 0 : config.maxSize - _inUse;
  int get pending => _waiters.length;
  bool get isClosed => _closed;

  @internal
  SqliteNativePool? get nativePool => _nativePool;

  Future<void> start() async {
    if (_closed) throw StateError('Pool is closed');
    if (_nativePool != null) return;
    _nativePool = SqliteNativePool.create(
      binding: _binding,
      path: config.path,
      minSize: config.minSize,
      maxSize: config.maxSize,
      acquireTimeout: config.acquireTimeout,
      busyTimeout: config.busyTimeout,
    );
  }

  Future<SqlitePooledConnection> acquire() async {
    if (_closed) throw StateError('Pool is closed');
    final pool = _nativePool;
    if (pool == null) throw StateError('Pool not started — call start() first');

    if (_inUse >= config.maxSize) {
      final completer = Completer<void>();
      _waiters.add(completer);
      final timer = Timer(config.acquireTimeout, () {
        if (!completer.isCompleted) {
          _waiters.remove(completer);
          completer.completeError(
              SqlitePoolExhaustedException(config.acquireTimeout));
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
    return SqlitePooledConnection._(conn, this);
  }

  void _release(ffi.Pointer<ffi.Void> conn) {
    final pool = _nativePool;
    if (pool != null) _binding.poolRelease(pool.ptr, conn);
    _inUse--;
    if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
  }

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
