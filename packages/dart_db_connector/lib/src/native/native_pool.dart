/// Dart wrapper around the C-side `native_pool_t` / `native_conn_t`
/// primitives declared in `native/c/include/native_pool.h`.
///
/// Owns: nothing GC-tracked. Everything lives in the C heap and is
/// released via [NativePool.destroy]. Misuse rules:
///
///   1. Only call into the pool from the isolate that called
///      [NativePool.create]. Native ports are created here and bound
///      to this isolate; cross-isolate use is unsupported in v1.
///   2. Every [acquire] MUST be paired with a [NativeConn.release].
///      Leaks starve the pool.
///   3. [destroy] requires all conns released first. Pending acquires
///      are aborted with `null` returns.
///
/// Notification protocol (matches `native_pool_worker.c`):
///   - port message int64 = 1 → result available; caller must drain
///     via `PostgresBinding.pollResult(conn.ptr)`.
///   - port message int64 = 2 → dispatch error or wall-clock timeout
///     fired; the worker issued PQcancel. Treat the conn as suspect.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../bindings/postgres_binding.dart';

/// Result codes posted by a worker after one submit completes.
class WorkerPortCode {
  /// libpq queue holds at least one `PGresult` for the caller.
  static const int ok = 1;

  /// Dispatch failed or timeout fired (PQcancel was issued); the
  /// connection is in an undefined state.
  static const int aborted = 2;
}

/// Thrown when [NativePool.create] cannot open all connections (e.g.
/// invalid conninfo or postgres unreachable).
class NativePoolStartupException implements Exception {
  final String conninfo;
  NativePoolStartupException(this.conninfo);

  @override
  String toString() =>
      'NativePoolStartupException: pool_create returned null for '
      '"$conninfo" (check Postgres reachability and credentials)';
}

/// Thrown when [NativePool.acquire] returns null because the wait
/// budget expired.
class NativePoolAcquireTimeoutException implements Exception {
  final Duration timeout;
  NativePoolAcquireTimeoutException(this.timeout);

  @override
  String toString() =>
      'NativePoolAcquireTimeoutException: no connection available '
      'within $timeout';
}

/// Thin handle around a `native_pool_t*`.
///
/// Construct via [NativePool.create]; tear down via [destroy]. The
/// class is intentionally state-light — all bookkeeping lives in C.
class NativePool {
  final PostgresBinding binding;
  final ffi.Pointer<ffi.Void> _ptr;
  final Duration _defaultAcquireTimeout;

  bool _destroyed = false;

  /// Underlying `native_pool_t*`. Exposed for tests + the Dart-side
  /// wrapper layer (`PostgresConnectionPool`). Do not pass elsewhere.
  ffi.Pointer<ffi.Void> get ptr => _ptr;

  NativePool._(this.binding, this._ptr, this._defaultAcquireTimeout);

  /// Spawns a `native_pool_t` with `maxSize` worker threads + conns.
  /// Throws [NativePoolStartupException] if `pool_create` returns
  /// null on the C side.
  factory NativePool.create({
    required PostgresBinding binding,
    required String conninfo,
    int minSize = 0,
    required int maxSize,
    required Duration acquireTimeout,
  }) {
    final p = conninfo.toNativeUtf8();
    try {
      final ptr = binding.poolCreate(
        p,
        minSize,
        maxSize,
        acquireTimeout.inMilliseconds,
      );
      if (ptr == ffi.nullptr) {
        throw NativePoolStartupException(conninfo);
      }
      return NativePool._(binding, ptr, acquireTimeout);
    } finally {
      malloc.free(p);
    }
  }

  bool get isDestroyed => _destroyed;

  /// Borrows a [NativeConn] from the pool. Throws
  /// [NativePoolAcquireTimeoutException] if [timeout] (or the pool's
  /// default) elapses without a free conn.
  ///
  /// Negative durations wait indefinitely. The default — when
  /// [timeout] is null — uses `acquireTimeout` from the construction
  /// site.
  NativeConn acquire({Duration? timeout}) {
    if (_destroyed) {
      throw StateError('NativePool: already destroyed');
    }
    final effective = timeout ?? _defaultAcquireTimeout;
    final ms = effective.inMilliseconds;
    final connPtr = binding.poolAcquire(_ptr, ms);
    if (connPtr == ffi.nullptr) {
      throw NativePoolAcquireTimeoutException(effective);
    }
    return NativeConn._(this, connPtr);
  }

  /// Tears the pool down (joins workers, closes conns, frees the
  /// struct). Idempotent.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    binding.poolDestroy(_ptr);
  }
}

/// A borrowed handle to one of the pool's `native_conn_t*`. Hand back
/// via [release] — preferably from a `try`/`finally`.
class NativeConn {
  final NativePool _pool;
  final ffi.Pointer<ffi.Void> _ptr;
  bool _released = false;

  NativeConn._(this._pool, this._ptr);

  /// Underlying `native_conn_t*`. Pass to `binding.pollResult` /
  /// `binding.poolCancel` etc. Do not retain past [release].
  ffi.Pointer<ffi.Void> get ptr => _ptr;

  bool get isReleased => _released;

  /// Submits `sql` to the worker. The returned future resolves to one
  /// of [WorkerPortCode.ok] / [WorkerPortCode.aborted] once the worker
  /// posts the result. Throws if the C-side dispatch refused (slot
  /// busy or libpq state error).
  ///
  /// `timeout`: wall-clock budget for the query. `Duration.zero` (the
  /// default) disables the timeout.
  Future<int> submit(String sql, {Duration timeout = Duration.zero}) async {
    if (_released) {
      throw StateError('NativeConn: already released');
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
            'pool_submit_query returned 0 (slot busy or libpq error)');
      }
      final code = await port.first as int;
      return code;
    } finally {
      malloc.free(sqlPtr);
      port.close();
    }
  }

  /// Submits N queries in libpq pipeline mode. v1 limitation: result
  /// rows are not surfaced — the worker drains and discards every
  /// PGresult. Best for bulk DML.
  ///
  /// Returns one of [WorkerPortCode.ok] / [WorkerPortCode.aborted].
  Future<int> submitPipeline(List<String> queries,
      {Duration timeout = Duration.zero}) async {
    if (_released) {
      throw StateError('NativeConn: already released');
    }
    if (queries.isEmpty) {
      throw ArgumentError.value(queries, 'queries', 'must be non-empty');
    }
    final n = queries.length;
    final native = malloc<ffi.Pointer<Utf8>>(n);
    final allocated = <ffi.Pointer<Utf8>>[];
    final port = ReceivePort();
    try {
      for (var i = 0; i < n; i++) {
        final p = queries[i].toNativeUtf8();
        allocated.add(p);
        native[i] = p;
      }
      final dispatched = _pool.binding.poolSubmitPipeline(
        _ptr,
        native,
        n,
        port.sendPort.nativePort,
        timeout.inMilliseconds,
      );
      if (dispatched != 1) {
        throw StateError(
            'pool_submit_pipeline returned 0 (slot busy or libpq error)');
      }
      final code = await port.first as int;
      return code;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(native);
      port.close();
    }
  }

  /// Fire-and-forget cancel for any in-flight query on this conn.
  /// Thread-safe on the C side. Idempotent on idle.
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
