/// MongoDB FFI binding for `libnative_mongo`.
///
/// Maps the `extern "C"` symbols declared in
/// `native/c/include/native_mongo.h` and `native/c/include/mongo_pool.h`.
/// ABI changes here MUST follow the ABI stability policy in CONTRIBUTING.md
/// (matching ADR + bump of NATIVE_MONGO_ABI_VERSION_*).
///
/// Independent of [PostgresBinding] and [MysqlBinding]: a separate native
/// library (`libnative_mongo`) with its own ABI.  — the
/// demonstration that the pattern generalizes to a NON-relational store.
/// Two structural differences from the relational bindings:
///   - `mongo_pool_create` takes a MongoDB URI string, not discrete params.
///   - There is no `submitQuery(sql)`; submissions are TYPED per operation
///     (find/insertOne/updateOne/deleteOne/command), each carrying BSON
///     byte buffers (`Pointer<Uint8>` + length) rather than a SQL string.
///   - A result is a raw BSON document buffer (`resultData`/`resultLength`),
///     which the Dart decoder parses; failures carry a real message
///     (`lastError`/`lastErrorCode`).
library;

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

// ───────── Init ─────────

typedef _InitDartApiNative = ffi.IntPtr Function(ffi.Pointer<ffi.Void>);
typedef _InitDartApiDart = int Function(ffi.Pointer<ffi.Void>);

// ───────── Pool primitives ─────────

typedef _PoolCreateNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, // uri
    ffi.Int32, // min_size
    ffi.Int32, // max_size
    ffi.Int64); // acquire_timeout_ms
typedef _PoolCreateDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, int, int, int);

typedef _PoolAcquireNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, ffi.Int64);
typedef _PoolAcquireDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, int);

typedef _PoolReleaseNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _PoolReleaseDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

typedef _PoolDestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _PoolDestroyDart = void Function(ffi.Pointer<ffi.Void>);

// ───────── Typed submissions ─────────
// find(conn, db, coll, filter, filter_len, opts, opts_len, port, timeout)
typedef _SubmitFindNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
    ffi.Int64,
    ffi.Int64);
typedef _SubmitFindDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    int);

// insert_one / delete_one / command share a single-buffer shape:
//   (conn, db, [coll], doc, doc_len, port, timeout)
// insert/delete take a coll; command omits it. To keep one typedef we always
// pass a coll pointer (nullptr for command) — but command's C signature has
// no coll param, so command needs its own typedef.
typedef _SubmitOneBufCollNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
    ffi.Int64,
    ffi.Int64);
typedef _SubmitOneBufCollDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    int);

// update_one(conn, db, coll, selector, sel_len, update, upd_len, port, timeout)
typedef _SubmitTwoBufNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
    ffi.Int64,
    ffi.Int64);
typedef _SubmitTwoBufDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    int);

// command(conn, db, command, cmd_len, port, timeout)
typedef _SubmitCommandNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, ffi.Int32, ffi.Int64, ffi.Int64);
typedef _SubmitCommandDart = int Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, int, int, int);

// insert_many (ABI MINOR 1.1):
//   (conn, db, coll, docs_bson, docs_total_len, doc_count, ordered, port, timeout)
// docs_bson = `doc_count` BSON documents concatenated back-to-back.
typedef _SubmitInsertManyNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
    ffi.Int32,
    ffi.Int32,
    ffi.Int64,
    ffi.Int64);
typedef _SubmitInsertManyDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    int,
    int,
    int);

// ───────── Result + error retrieval ─────────

typedef _PollResultNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);
typedef _PollResultDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

typedef _ResultDataNative = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>);
typedef _ResultDataDart = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>);

typedef _ResultLengthNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _ResultLengthDart = int Function(ffi.Pointer<ffi.Void>);

typedef _LastErrorNative = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _LastErrorDart = ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>);

typedef _LastErrorCodeNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _LastErrorCodeDart = int Function(ffi.Pointer<ffi.Void>);

typedef _ClearResultNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ClearResultDart = void Function(ffi.Pointer<ffi.Void>);

/// Thin wrapper around a [ffi.DynamicLibrary] exposing all native symbols
/// of `libnative_mongo`. Construction looks up symbols eagerly.
///
/// **Internal class.** Consumers should not instantiate directly — use
/// `MongoConnectionPool`, which resolves the binding via the per-isolate
/// `MongoSharedBinding` singleton.
@internal
class MongoBinding {
  /// Initializes the Dart Native API. Returns 0 on success.
  final int Function(ffi.Pointer<ffi.Void> data) initDartApi;

  /// Creates a `mongo_pool_t*` from a MongoDB URI with `maxSize`
  /// connections + workers. Returns `nullptr` on failure.
  final ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<Utf8> uri, int minSize, int maxSize, int acquireTimeoutMs)
      poolCreate;

  /// Blocks until a free `mongo_conn_t*` is available or `timeoutMs`
  /// elapses. Returns `nullptr` on timeout / pool shutdown.
  final ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> pool, int timeoutMs) poolAcquire;

  /// Returns a `mongo_conn_t*` to the pool. No-op on nullptr.
  final void Function(ffi.Pointer<ffi.Void> pool, ffi.Pointer<ffi.Void> conn)
      poolRelease;

  /// `find` with `filter` + optional `opts` BSON. Yields matched documents,
  /// chained (drain via [pollResult] until nullptr).
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> db,
      ffi.Pointer<Utf8> coll,
      ffi.Pointer<ffi.Uint8> filter,
      int filterLen,
      ffi.Pointer<ffi.Uint8> opts,
      int optsLen,
      int portId,
      int timeoutMs) submitFind;

  /// Inserts one BSON `document`. Yields the write reply.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> db,
      ffi.Pointer<Utf8> coll,
      ffi.Pointer<ffi.Uint8> doc,
      int docLen,
      int portId,
      int timeoutMs) submitInsertOne;

  /// Updates one document matching `selector` with `update`.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> db,
      ffi.Pointer<Utf8> coll,
      ffi.Pointer<ffi.Uint8> selector,
      int selectorLen,
      ffi.Pointer<ffi.Uint8> update,
      int updateLen,
      int portId,
      int timeoutMs) submitUpdateOne;

  /// Deletes one document matching `selector`.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> db,
      ffi.Pointer<Utf8> coll,
      ffi.Pointer<ffi.Uint8> selector,
      int selectorLen,
      int portId,
      int timeoutMs) submitDeleteOne;

  /// Runs an arbitrary database `command` (count, aggregate, ping…).
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> db,
      ffi.Pointer<ffi.Uint8> command,
      int commandLen,
      int portId,
      int timeoutMs) submitCommand;

  /// Inserts N documents (`docs` = `docCount` BSON documents concatenated)
  /// in one bulk operation. `ordered` != 0 stops at the first write error.
  /// Yields one reply (insertedCount, and writeErrors[] on partial failure).
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> db,
      ffi.Pointer<Utf8> coll,
      ffi.Pointer<ffi.Uint8> docs,
      int docsTotalLen,
      int docCount,
      int ordered,
      int portId,
      int timeoutMs) submitInsertMany;

  /// Tears down a pool: signals shutdown, joins workers, returns clients.
  final void Function(ffi.Pointer<ffi.Void> pool) poolDestroy;

  /// Retrieves the next stored result wrapper for `conn`, advancing the
  /// chain. Caller owns each non-null return and MUST call [clearResult].
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void> conn) pollResult;

  /// Pointer to the raw BSON bytes of a result. Valid until [clearResult].
  /// Wrap with `.asTypedList(resultLength(result))` to decode zero-copy.
  final ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Void> result)
      resultData;

  /// Byte length of the result's BSON document.
  final int Function(ffi.Pointer<ffi.Void> result) resultLength;

  /// Message of the last failed op on `conn` (`bson_error_t.message`), or "".
  final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void> conn) lastError;

  /// Numeric code of the last failure (`bson_error_t.code`), or 0.
  final int Function(ffi.Pointer<ffi.Void> conn) lastErrorCode;

  /// Frees a result wrapper (BSON buffer + node). Idempotent on nullptr.
  final void Function(ffi.Pointer<ffi.Void> result) clearResult;

  MongoBinding._(
    this.initDartApi,
    this.poolCreate,
    this.poolAcquire,
    this.poolRelease,
    this.submitFind,
    this.submitInsertOne,
    this.submitUpdateOne,
    this.submitDeleteOne,
    this.submitCommand,
    this.submitInsertMany,
    this.poolDestroy,
    this.pollResult,
    this.resultData,
    this.resultLength,
    this.lastError,
    this.lastErrorCode,
    this.clearResult,
  );

  factory MongoBinding(ffi.DynamicLibrary lib) {
    return MongoBinding._(
      lib.lookupFunction<_InitDartApiNative, _InitDartApiDart>(
          'native_mongo_init_dart_api'),
      lib.lookupFunction<_PoolCreateNative, _PoolCreateDart>(
          'mongo_pool_create'),
      lib.lookupFunction<_PoolAcquireNative, _PoolAcquireDart>(
          'mongo_pool_acquire'),
      lib.lookupFunction<_PoolReleaseNative, _PoolReleaseDart>(
          'mongo_pool_release'),
      lib.lookupFunction<_SubmitFindNative, _SubmitFindDart>(
          'mongo_pool_submit_find'),
      lib.lookupFunction<_SubmitOneBufCollNative, _SubmitOneBufCollDart>(
          'mongo_pool_submit_insert_one'),
      lib.lookupFunction<_SubmitTwoBufNative, _SubmitTwoBufDart>(
          'mongo_pool_submit_update_one'),
      lib.lookupFunction<_SubmitOneBufCollNative, _SubmitOneBufCollDart>(
          'mongo_pool_submit_delete_one'),
      lib.lookupFunction<_SubmitCommandNative, _SubmitCommandDart>(
          'mongo_pool_submit_command'),
      lib.lookupFunction<_SubmitInsertManyNative, _SubmitInsertManyDart>(
          'mongo_pool_submit_insert_many'),
      lib.lookupFunction<_PoolDestroyNative, _PoolDestroyDart>(
          'mongo_pool_destroy'),
      lib.lookupFunction<_PollResultNative, _PollResultDart>(
          'native_mongo_poll_result'),
      lib.lookupFunction<_ResultDataNative, _ResultDataDart>(
          'native_mongo_result_data'),
      lib.lookupFunction<_ResultLengthNative, _ResultLengthDart>(
          'native_mongo_result_length'),
      lib.lookupFunction<_LastErrorNative, _LastErrorDart>(
          'native_mongo_last_error'),
      lib.lookupFunction<_LastErrorCodeNative, _LastErrorCodeDart>(
          'native_mongo_last_error_code'),
      lib.lookupFunction<_ClearResultNative, _ClearResultDart>(
          'native_mongo_clear_result'),
    );
  }
}
