/// Dart wrapper around the C-side `mongo_pool_t` / `mongo_conn_t`
/// primitives declared in `native/c/include/mongo_pool.h`.
///
/// Mirror of `mysql_native_pool.dart` for the MongoDB driver, but the
/// submit surface is TYPED per operation (find/insert/update/delete/command)
/// instead of a single `submit(sql)`, and each op decodes the returned BSON
/// document(s) via [BsonReader]. Failures carry the real libmongoc message
/// (`native_mongo_last_error`) as a [MongoOperationException], per the
/// error-propagation requirement of the MongoDB driver design.
///
/// Notification protocol (matches `mongo_pool_worker.c`):
///   - port message int64 = 1 → success; drain via `pollResult`.
///   - port message int64 = 2 → aborted; message via `lastError` / code.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bindings/mongo_binding.dart';
import '../decoder/bson_reader.dart';
import '../decoder/bson_value.dart';
import '../mongo/mongo_bulk_result.dart';

/// Result codes posted by a worker after one submit completes.
class MongoWorkerPortCode {
  static const int ok = 1;
  static const int aborted = 2;
}

/// Thrown when [MongoNativePool.create] cannot build the pool (bad URI,
/// unreachable server, failed client pop).
class MongoNativePoolStartupException implements Exception {
  final String uri;
  MongoNativePoolStartupException(this.uri);

  @override
  String toString() =>
      'MongoNativePoolStartupException: mongo_pool_create returned null for '
      '"$uri" (check MongoDB reachability and the connection string)';
}

/// Thrown when [MongoNativePool.acquire] times out.
class MongoNativePoolAcquireTimeoutException implements Exception {
  final Duration timeout;
  MongoNativePoolAcquireTimeoutException(this.timeout);

  @override
  String toString() =>
      'MongoNativePoolAcquireTimeoutException: no connection available '
      'within $timeout';
}

/// Thrown when a MongoDB operation fails, carrying the real libmongoc
/// message and numeric code (e.g. `E11000 duplicate key error`, code 11000).
class MongoOperationException implements Exception {
  final String message;
  final int code;
  MongoOperationException(this.message, {required this.code});

  @override
  String toString() => 'MongoOperationException($code): $message';
}

/// Thin handle around a `mongo_pool_t*`.
class MongoNativePool {
  final MongoBinding binding;
  final ffi.Pointer<ffi.Void> _ptr;
  final Duration _defaultAcquireTimeout;
  bool _destroyed = false;

  ffi.Pointer<ffi.Void> get ptr => _ptr;

  MongoNativePool._(this.binding, this._ptr, this._defaultAcquireTimeout);

  /// Spawns a `mongo_pool_t` with `maxSize` worker threads + clients from a
  /// MongoDB [uri]. Throws [MongoNativePoolStartupException] on failure.
  factory MongoNativePool.create({
    required MongoBinding binding,
    required String uri,
    int minSize = 0,
    required int maxSize,
    required Duration acquireTimeout,
  }) {
    final uriP = uri.toNativeUtf8();
    try {
      final ptr = binding.poolCreate(
          uriP, minSize, maxSize, acquireTimeout.inMilliseconds);
      if (ptr == ffi.nullptr) {
        throw MongoNativePoolStartupException(uri);
      }
      return MongoNativePool._(binding, ptr, acquireTimeout);
    } finally {
      malloc.free(uriP);
    }
  }

  bool get isDestroyed => _destroyed;

  MongoConn acquire({Duration? timeout}) {
    if (_destroyed) throw StateError('MongoNativePool: already destroyed');
    final effective = timeout ?? _defaultAcquireTimeout;
    final connPtr = binding.poolAcquire(_ptr, effective.inMilliseconds);
    if (connPtr == ffi.nullptr) {
      throw MongoNativePoolAcquireTimeoutException(effective);
    }
    return MongoConn._(this, connPtr);
  }

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    binding.poolDestroy(_ptr);
  }
}

/// A borrowed handle to one of the pool's `mongo_conn_t*`. Exposes the typed
/// operations; each awaits the worker's Native Port notification, decodes the
/// BSON reply(ies), and throws [MongoOperationException] on failure.
class MongoConn {
  final MongoNativePool _pool;
  final ffi.Pointer<ffi.Void> _ptr;
  bool _released = false;

  MongoConn._(this._pool, this._ptr);

  MongoBinding get _b => _pool.binding;

  ffi.Pointer<ffi.Void> get ptr => _ptr;
  bool get isReleased => _released;

  void _checkLive() {
    if (_released) throw StateError('MongoConn: already released');
  }

  /// Raises [MongoOperationException] from the conn's last-error slot.
  Never _throwLast() {
    final msg = _b.lastError(_ptr).toDartString();
    throw MongoOperationException(
      msg.isEmpty ? 'operation aborted' : msg,
      code: _b.lastErrorCode(_ptr),
    );
  }

  /// Drains and decodes all pending result documents (for `find`).
  List<BsonDocument> _drainAll() {
    final out = <BsonDocument>[];
    while (true) {
      final r = _b.pollResult(_ptr);
      if (r == ffi.nullptr) break;
      final len = _b.resultLength(r);
      final view = _b.resultData(r).asTypedList(len);
      out.add(BsonReader(view).readDocument());
      _b.clearResult(r);
    }
    return out;
  }

  /// Drains and decodes exactly one pending reply document (for writes /
  /// command). Returns an empty document if none was produced.
  BsonDocument _drainOne() {
    final r = _b.pollResult(_ptr);
    if (r == ffi.nullptr) return const BsonDocument({});
    final len = _b.resultLength(r);
    final view = _b.resultData(r).asTypedList(len);
    final doc = BsonReader(view).readDocument();
    _b.clearResult(r);
    return doc;
  }

  /// `find` matching [filter] (BSON), with optional [opts] (BSON). Returns
  /// the matched documents.
  Future<List<BsonDocument>> find(String db, String coll, Uint8List filter,
      {Uint8List? opts, Duration timeout = Duration.zero}) async {
    _checkLive();
    final port = ReceivePort();
    final dbP = db.toNativeUtf8();
    final collP = coll.toNativeUtf8();
    final fP = _toNative(filter);
    final oP = (opts != null) ? _toNative(opts) : ffi.nullptr;
    try {
      final dispatched = _b.submitFind(
          _ptr,
          dbP,
          collP,
          fP,
          filter.length,
          oP.cast(),
          opts?.length ?? 0,
          port.sendPort.nativePort,
          timeout.inMilliseconds);
      if (dispatched != 1) {
        throw StateError('mongo_pool_submit_find returned 0 (slot busy)');
      }
      final code = await port.first as int;
      if (code == MongoWorkerPortCode.aborted) _throwLast();
      return _drainAll();
    } finally {
      malloc.free(dbP);
      malloc.free(collP);
      malloc.free(fP);
      if (oP != ffi.nullptr) malloc.free(oP);
      port.close();
    }
  }

  /// Inserts one BSON [document]. Returns the write reply.
  Future<BsonDocument> insertOne(String db, String coll, Uint8List document,
          {Duration timeout = Duration.zero}) =>
      _writeOneBuf(_b.submitInsertOne, db, coll, document, timeout);

  /// Deletes one document matching [selector]. Returns the reply.
  Future<BsonDocument> deleteOne(String db, String coll, Uint8List selector,
          {Duration timeout = Duration.zero}) =>
      _writeOneBuf(_b.submitDeleteOne, db, coll, selector, timeout);

  Future<BsonDocument> _writeOneBuf(
      int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>,
              ffi.Pointer<ffi.Uint8>, int, int, int)
          submit,
      String db,
      String coll,
      Uint8List buf,
      Duration timeout) async {
    _checkLive();
    final port = ReceivePort();
    final dbP = db.toNativeUtf8();
    final collP = coll.toNativeUtf8();
    final bP = _toNative(buf);
    try {
      final dispatched = submit(_ptr, dbP, collP, bP, buf.length,
          port.sendPort.nativePort, timeout.inMilliseconds);
      if (dispatched != 1) {
        throw StateError('mongo submit returned 0 (slot busy)');
      }
      final code = await port.first as int;
      if (code == MongoWorkerPortCode.aborted) _throwLast();
      return _drainOne();
    } finally {
      malloc.free(dbP);
      malloc.free(collP);
      malloc.free(bP);
      port.close();
    }
  }

  /// Updates one document matching [selector] with [update]. Returns the reply.
  Future<BsonDocument> updateOne(
      String db, String coll, Uint8List selector, Uint8List update,
      {Duration timeout = Duration.zero}) async {
    _checkLive();
    final port = ReceivePort();
    final dbP = db.toNativeUtf8();
    final collP = coll.toNativeUtf8();
    final sP = _toNative(selector);
    final uP = _toNative(update);
    try {
      final dispatched = _b.submitUpdateOne(
          _ptr,
          dbP,
          collP,
          sP,
          selector.length,
          uP,
          update.length,
          port.sendPort.nativePort,
          timeout.inMilliseconds);
      if (dispatched != 1) {
        throw StateError('mongo_pool_submit_update_one returned 0 (slot busy)');
      }
      final code = await port.first as int;
      if (code == MongoWorkerPortCode.aborted) _throwLast();
      return _drainOne();
    } finally {
      malloc.free(dbP);
      malloc.free(collP);
      malloc.free(sP);
      malloc.free(uP);
      port.close();
    }
  }

  /// Inserts N BSON [docs] in one bulk operation. On success returns the
  /// [BulkWriteResult]; on partial or total failure throws a
  /// [MongoBulkWriteException] carrying the per-index write errors and the
  /// real libmongoc message. Unlike the single writes, the reply is drained
  /// even on abort (the worker always stores it) so write errors surface.
  Future<BulkWriteResult> insertMany(
      String db, String coll, List<Uint8List> docs,
      {bool ordered = true, Duration timeout = Duration.zero}) async {
    _checkLive();
    if (docs.isEmpty) return const BulkWriteResult(insertedCount: 0);

    final bb = BytesBuilder(copy: false);
    for (final d in docs) {
      bb.add(d);
    }
    final blob = bb.toBytes();

    final port = ReceivePort();
    final dbP = db.toNativeUtf8();
    final collP = coll.toNativeUtf8();
    final bP = _toNative(blob);
    try {
      final dispatched = _b.submitInsertMany(
          _ptr,
          dbP,
          collP,
          bP,
          blob.length,
          docs.length,
          ordered ? 1 : 0,
          port.sendPort.nativePort,
          timeout.inMilliseconds);
      if (dispatched != 1) {
        throw StateError(
            'mongo_pool_submit_insert_many returned 0 (slot busy)');
      }
      final code = await port.first as int;
      // The worker always stores the reply (insertedCount + writeErrors),
      // so drain it regardless of the status code.
      final reply = _drainOne();
      final inserted = reply.getInt('insertedCount') ?? 0;
      final rawErrors = reply.getList('writeErrors');
      if (code == MongoWorkerPortCode.aborted ||
          (rawErrors != null && rawErrors.isNotEmpty)) {
        final msg = _b.lastError(_ptr).toDartString();
        throw MongoBulkWriteException(
          msg.isEmpty ? 'bulk insert aborted' : msg,
          code: _b.lastErrorCode(_ptr),
          insertedCount: inserted,
          writeErrors: _parseWriteErrors(rawErrors),
        );
      }
      return BulkWriteResult(insertedCount: inserted);
    } finally {
      malloc.free(dbP);
      malloc.free(collP);
      malloc.free(bP);
      port.close();
    }
  }

  /// Parses the `writeErrors[]` array of a bulk reply into typed errors.
  static List<BulkWriteError> _parseWriteErrors(List<Object?>? raw) {
    if (raw == null) return const [];
    final out = <BulkWriteError>[];
    for (final e in raw) {
      if (e is! BsonDocument) continue;
      out.add(BulkWriteError(
        e.getInt('index') ?? -1,
        e.getInt('code') ?? 0,
        e.getString('errmsg') ?? '',
      ));
    }
    return out;
  }

  /// Runs a database [command] (BSON). Returns the reply document.
  Future<BsonDocument> command(String db, Uint8List command,
      {Duration timeout = Duration.zero}) async {
    _checkLive();
    final port = ReceivePort();
    final dbP = db.toNativeUtf8();
    final cP = _toNative(command);
    try {
      final dispatched = _b.submitCommand(_ptr, dbP, cP, command.length,
          port.sendPort.nativePort, timeout.inMilliseconds);
      if (dispatched != 1) {
        throw StateError('mongo_pool_submit_command returned 0 (slot busy)');
      }
      final code = await port.first as int;
      if (code == MongoWorkerPortCode.aborted) _throwLast();
      return _drainOne();
    } finally {
      malloc.free(dbP);
      malloc.free(cP);
      port.close();
    }
  }

  void release() {
    if (_released) return;
    _released = true;
    _pool.binding.poolRelease(_pool.ptr, _ptr);
  }

  static ffi.Pointer<ffi.Uint8> _toNative(Uint8List bytes) {
    final p = malloc<ffi.Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    return p;
  }
}
