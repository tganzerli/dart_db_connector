/// Dart wrapper around the C-side `mysql_pool_t` / `mysql_conn_t`
/// primitives declared in `native/c/include/mysql_pool.h`.
///
/// Mirror of `native_pool.dart` (PostgreSQL) for the MySQL driver. Same
/// misuse rules: call from the creating isolate only; pair every
/// [acquire] with a [MysqlConn.release]; [destroy] requires all conns
/// released first.
///
/// Notification protocol (matches `mysql_pool_worker.c`):
///   - port message int64 = 1 → result available; drain via
///     `MysqlBinding.pollResult(conn.ptr)`.
///   - port message int64 = 2 → dispatch error / query failed. Treat the
///     conn as suspect.
///
/// v1 difference from the PostgreSQL wrapper: no pipeline path (MySQL has
/// no direct libpq-pipeline analogue) and no Extended-Protocol params.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../bindings/mysql_binding.dart';

/// Result codes posted by a worker after one submit completes.
class MysqlWorkerPortCode {
  /// The result handle for the caller is ready (drain via `pollResult`).
  static const int ok = 1;

  /// Dispatch failed / query errored; the connection is suspect.
  static const int aborted = 2;
}

/// Thrown when [MysqlNativePool.create] cannot open all connections
/// (invalid credentials or MySQL unreachable).
class MysqlNativePoolStartupException implements Exception {
  final String host;
  final int port;
  MysqlNativePoolStartupException(this.host, this.port);

  @override
  String toString() =>
      'MysqlNativePoolStartupException: mysql_pool_create returned null '
      'for $host:$port (check MySQL reachability and credentials)';
}

/// Thrown when [MysqlNativePool.acquire] returns null because the wait
/// budget expired.
class MysqlNativePoolAcquireTimeoutException implements Exception {
  final Duration timeout;
  MysqlNativePoolAcquireTimeoutException(this.timeout);

  @override
  String toString() =>
      'MysqlNativePoolAcquireTimeoutException: no connection available '
      'within $timeout';
}

/// Thin handle around a `mysql_pool_t*`.
class MysqlNativePool {
  final MysqlBinding binding;
  final ffi.Pointer<ffi.Void> _ptr;
  final Duration _defaultAcquireTimeout;

  bool _destroyed = false;

  /// Underlying `mysql_pool_t*`. Exposed for tests + the Dart-side
  /// wrapper layer (`MysqlConnectionPool`).
  ffi.Pointer<ffi.Void> get ptr => _ptr;

  MysqlNativePool._(this.binding, this._ptr, this._defaultAcquireTimeout);

  /// Spawns a `mysql_pool_t` with `maxSize` worker threads + conns.
  /// Throws [MysqlNativePoolStartupException] if `mysql_pool_create`
  /// returns null on the C side.
  factory MysqlNativePool.create({
    required MysqlBinding binding,
    required String host,
    required String user,
    required String password,
    String? database,
    int port = 3306,
    int minSize = 0,
    required int maxSize,
    required Duration acquireTimeout,
  }) {
    final hostP = host.toNativeUtf8();
    final userP = user.toNativeUtf8();
    final passP = password.toNativeUtf8();
    final dbP = (database == null) ? ffi.nullptr : database.toNativeUtf8();
    try {
      final ptr = binding.poolCreate(
        hostP,
        userP,
        passP,
        dbP.cast(),
        port,
        minSize,
        maxSize,
        acquireTimeout.inMilliseconds,
      );
      if (ptr == ffi.nullptr) {
        throw MysqlNativePoolStartupException(host, port);
      }
      return MysqlNativePool._(binding, ptr, acquireTimeout);
    } finally {
      malloc.free(hostP);
      malloc.free(userP);
      malloc.free(passP);
      if (dbP != ffi.nullptr) malloc.free(dbP);
    }
  }

  bool get isDestroyed => _destroyed;

  /// Borrows a [MysqlConn] from the pool. Throws
  /// [MysqlNativePoolAcquireTimeoutException] on timeout.
  MysqlConn acquire({Duration? timeout}) {
    if (_destroyed) {
      throw StateError('MysqlNativePool: already destroyed');
    }
    final effective = timeout ?? _defaultAcquireTimeout;
    final connPtr = binding.poolAcquire(_ptr, effective.inMilliseconds);
    if (connPtr == ffi.nullptr) {
      throw MysqlNativePoolAcquireTimeoutException(effective);
    }
    return MysqlConn._(this, connPtr);
  }

  /// Tears the pool down (joins workers, closes conns, frees the
  /// struct). Idempotent.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    binding.poolDestroy(_ptr);
  }
}

/// A borrowed handle to one of the pool's `mysql_conn_t*`. Hand back via
/// [release] — preferably from a `try`/`finally`.
class MysqlConn {
  final MysqlNativePool _pool;
  final ffi.Pointer<ffi.Void> _ptr;
  bool _released = false;

  MysqlConn._(this._pool, this._ptr);

  /// Underlying `mysql_conn_t*`. Pass to `binding.pollResult` /
  /// `binding.poolCancel`. Do not retain past [release].
  ffi.Pointer<ffi.Void> get ptr => _ptr;

  bool get isReleased => _released;

  /// Submits `sql` to the worker. Resolves to one of
  /// [MysqlWorkerPortCode.ok] / [MysqlWorkerPortCode.aborted] once the
  /// worker posts. Throws if the C-side dispatch refused (slot busy).
  ///
  /// `timeout` is accepted for API symmetry; v1 does not enforce a
  /// per-query wall-clock deadline for the blocking MySQL path (see
  /// `mysql_pool.h`).
  Future<int> submit(String sql, {Duration timeout = Duration.zero}) async {
    if (_released) {
      throw StateError('MysqlConn: already released');
    }
    final port = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    try {
      final dispatched = _pool.binding.poolSubmitQuery(
        _ptr,
        sqlPtr,
        port.sendPort.nativePort,
        timeout.inMilliseconds,
      );
      if (dispatched != 1) {
        throw StateError(
            'mysql_pool_submit_query returned 0 (slot busy or shut down)');
      }
      final code = await port.first as int;
      return code;
    } finally {
      malloc.free(sqlPtr);
      port.close();
    }
  }

  /// Fire-and-forget cancel (KILL QUERY) for any in-flight query.
  void cancel() {
    if (_released) return;
    _pool.binding.poolCancel(_ptr);
  }

  /// Returns the conn to the pool. Idempotent.
  void release() {
    if (_released) return;
    _released = true;
    _pool.binding.poolRelease(_pool.ptr, _ptr);
  }
}
