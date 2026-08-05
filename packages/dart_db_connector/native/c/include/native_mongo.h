/// native_mongo.h — Public ABI of libnative_mongo.
///
///  — the MongoDB counterpart of `native_mysql.h`,
/// produced by applying the extensibility blueprint in
/// the layered architecture in the package README to a NON-relational store.
/// A NEW, INDEPENDENT native ABI (separate `libnative_mongo.{dylib,so}`),
/// versioned separately from `libnative_db` (PostgreSQL) and
/// `libnative_mysql` (MySQL). It does NOT alter those ABIs, so the other
/// drivers are unaffected.
///
/// Governed by the ABI stability policy in CONTRIBUTING.md. Any change to a
/// signature, semantics, or ownership convention here is breaking and MUST
/// be accompanied by an ADR, a MAJOR/MINOR bump, and a synchronous update
/// to `dart/lib/src/bindings/mongo_binding.dart` in the same PR.
///
/// Two design differences from the relational drivers, forced by the
/// document model:
///   1. There is NO universal "query string". Submissions are TYPED per
///      operation (find/insert/update/delete/command) — see mongo_pool.h.
///   2. A result is a raw BSON document buffer, not a row/column grid. The
///      worker copies each returned document into an opaque wrapper
///      (`native_mongo_result_t`); Dart views the buffer zero-copy and
///      parses BSON on its side. A `find` yields N wrappers CHAINED (as in
///      the MySQL multi-read of ABI MINOR 2); writes/commands yield one.
///
/// Linked Dart binding: `package:dart_db_connector/src/bindings/mongo_binding.dart`.

#ifndef NATIVE_MONGO_H
#define NATIVE_MONGO_H

#include <stdint.h>

#include "mongo_pool.h"

/// Semantic ABI version. A new, independent ABI family: born at MAJOR 1,
/// MINOR 0. Packed as ((int64_t)MAJOR << 32) | MINOR by
/// `native_mongo_abi_version`.
#define NATIVE_MONGO_ABI_VERSION_MAJOR 1
#define NATIVE_MONGO_ABI_VERSION_MINOR 1  // 1.1: + mongo_pool_submit_insert_many (bulk write, F1-Mongo)

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque result handle. Wraps a COPY of one returned BSON document buffer
/// (the cursor's buffer is only valid until the next iteration, so the
/// worker copies it). Internal layout in `mongo_pool_internal.h`. Dart sees
/// `Pointer<Void>`.
typedef struct native_mongo_result native_mongo_result_t;

/// Returns the ABI version, packed as ((int64_t)MAJOR << 32) | MINOR. Same
/// runtime-validation policy as the other ABIs : MAJOR mismatch fatal, lower linked
/// MINOR a non-blocking warning.
int64_t native_mongo_abi_version(void);

/// Initializes the Dart Native API (`dart_api_dl.h`). Called once per
/// isolate with `NativeApi.initializeApiDLData`. Returns 0 on success.
/// Distinct symbol from the other libs' init functions so all three can
/// coexist in a process.
intptr_t native_mongo_init_dart_api(void* data);

/// After a Native Port notification (int64 = 1), retrieves the next stored
/// result wrapper for `conn`, advancing the internal chain. For `find` this
/// returns each document in order and NULL once exhausted (0-document finds
/// return NULL immediately). For insert/update/delete/command it returns the
/// single reply document, then NULL. Caller owns every non-NULL return and
/// MUST call `native_mongo_clear_result`.
native_mongo_result_t* native_mongo_poll_result(mongo_conn_t* conn);

/* ─────── Result access (zero-copy view of a BSON document) ─────── */

/// Pointer to the raw BSON bytes of the result document. Valid until
/// `native_mongo_clear_result`. Caller MUST NOT free or mutate. The Dart
/// decoder wraps this with `asTypedList(length)` and parses BSON.
const uint8_t* native_mongo_result_data(native_mongo_result_t* result);

/// Length in bytes of the BSON document (its length-prefix value). 0 if
/// `result` is NULL.
int32_t native_mongo_result_length(native_mongo_result_t* result);

/* ─────── Error propagation (last failed op on this conn) ─────── */

/// After a Native Port notification of int64 = 2 (aborted), returns the
/// human-readable message of the underlying `libmongoc` failure
/// (`bson_error_t.message`) for `conn`, e.g. "E11000 duplicate key error".
/// Returns "" when there is no pending error. Valid until the next submit
/// on this conn. Caller MUST NOT free.
const char* native_mongo_last_error(mongo_conn_t* conn);

/// Numeric error code of the last failure (`bson_error_t.code`), or 0.
int32_t native_mongo_last_error_code(mongo_conn_t* conn);

/* ─────── Memory hygiene ─────── */

/// Frees a result wrapper previously returned by `native_mongo_poll_result`
/// (frees the copied BSON buffer and the node). Idempotent on NULL.
void native_mongo_clear_result(native_mongo_result_t* result);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_MONGO_H */
