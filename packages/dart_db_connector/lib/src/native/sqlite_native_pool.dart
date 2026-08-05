/// Dart wrapper around the C-side `sqlite_pool_t` / `sqlite_conn_t`
/// primitives (`native/c/include/sqlite_pool.h`). Mirror of
/// `mysql_native_pool.dart`; `create` takes a DB file path + busy timeout.
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../bindings/sqlite_binding.dart';

class SqliteWorkerPortCode {
  static const int ok = 1;
  static const int aborted = 2;
}

/// Thrown when [SqliteNativePool.create] cannot open the pool (bad path /
/// permissions / open failure).
class SqliteNativePoolStartupException implements Exception {
  final String path;
  SqliteNativePoolStartupException(this.path);
  @override
  String toString() =>
      'SqliteNativePoolStartupException: sqlite_pool_create returned null for '
      '"$path" (check the path and write permissions)';
}

class SqliteNativePoolAcquireTimeoutException implements Exception {
  final Duration timeout;
  SqliteNativePoolAcquireTimeoutException(this.timeout);
  @override
  String toString() =>
      'SqliteNativePoolAcquireTimeoutException: no connection within $timeout';
}

/// Thin handle around a `sqlite_pool_t*`.
class SqliteNativePool {
  final SqliteBinding binding;
  final ffi.Pointer<ffi.Void> _ptr;
  final Duration _defaultAcquireTimeout;
  bool _destroyed = false;

  ffi.Pointer<ffi.Void> get ptr => _ptr;

  SqliteNativePool._(this.binding, this._ptr, this._defaultAcquireTimeout);

  factory SqliteNativePool.create({
    required SqliteBinding binding,
    required String path,
    int minSize = 0,
    required int maxSize,
    required Duration acquireTimeout,
    Duration busyTimeout = const Duration(seconds: 5),
  }) {
    final pathP = path.toNativeUtf8();
    try {
      final ptr = binding.poolCreate(pathP, minSize, maxSize,
          acquireTimeout.inMilliseconds, busyTimeout.inMilliseconds);
      if (ptr == ffi.nullptr) {
        throw SqliteNativePoolStartupException(path);
      }
      return SqliteNativePool._(binding, ptr, acquireTimeout);
    } finally {
      malloc.free(pathP);
    }
  }

  bool get isDestroyed => _destroyed;

  ffi.Pointer<ffi.Void> acquire({Duration? timeout}) {
    if (_destroyed) throw StateError('SqliteNativePool: already destroyed');
    final effective = timeout ?? _defaultAcquireTimeout;
    final connPtr = binding.poolAcquire(_ptr, effective.inMilliseconds);
    if (connPtr == ffi.nullptr) {
      throw SqliteNativePoolAcquireTimeoutException(effective);
    }
    return connPtr;
  }

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    binding.poolDestroy(_ptr);
  }
}
