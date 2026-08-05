/// native_mysql.h — Public ABI of libnative_mysql.
///
///  — the MySQL counterpart of `native_db.h`, produced
/// by applying the extensibility blueprint in
/// the layered architecture in the package README. This is a NEW, INDEPENDENT
/// native ABI (separate `libnative_mysql.{dylib,so}`), versioned
/// separately from `libnative_db` (PostgreSQL). It does NOT alter the
/// PostgreSQL ABI, so the PostgreSQL driver is unaffected.
///
/// Governed by the ABI stability policy in CONTRIBUTING.md. Any change to a
/// signature, semantics, or ownership convention here is a breaking
/// change and MUST be accompanied by:
///   1. A design note in CHANGELOG.md.
///   2. A bump of NATIVE_MYSQL_ABI_VERSION_MAJOR (breaking) or
///      NATIVE_MYSQL_ABI_VERSION_MINOR (additive non-breaking).
///   3. A synchronous update to `dart/lib/src/bindings/mysql_binding.dart`
///      in the same PR.
///
/// Like `mysql_pool.h`, this header exposes only opaque handles and
/// primitives — it does not include <mysql.h>. The result handle is an
/// opaque wrapper (`native_mysql_result_t`) rather than a raw
/// `MYSQL_RES*`: the wrapper caches the current row so that random-access
/// cell reads stay zero-copy over `mysql_store_result` (where a
/// `MYSQL_ROW` is only valid until the next fetch).
///
/// Linked Dart binding: `package:dart_db_connector/src/bindings/mysql_binding.dart`.

#ifndef NATIVE_MYSQL_H
#define NATIVE_MYSQL_H

#include <stdint.h>

#include "mysql_pool.h"

/// Semantic ABI version. A new, independent ABI family: born at MAJOR 1,
/// MINOR 0 (no MAJOR 0 pre-history, unlike libnative_db). Packed as
/// ((int64_t)MAJOR << 32) | MINOR by `native_mysql_abi_version`.
#define NATIVE_MYSQL_ABI_VERSION_MAJOR 1
// MINOR bumps (additive, non-breaking):
//   1 → `mysql_pool_submit_batch` added (multi-statement write batching in
//       one round-trip, the MySQL analog of the libpq pipeline). 2026-07-27.
//   2 → `mysql_pool_submit_multi_read` added (N reads in one round-trip,
//       preserving N result sets as a chain drained by poll_result). 2026-07-27.
//   3 → `native_mysql_last_errno` / `native_mysql_last_error` added (surface
//       the real libmysqlclient error on the abort path). 2026-08-03.
//       
#define NATIVE_MYSQL_ABI_VERSION_MINOR 3

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque result handle. Wraps a `MYSQL_RES*` plus a one-row cache.
/// Internal layout in `mysql_pool_internal.h`. Dart sees `Pointer<Void>`.
typedef struct native_mysql_result native_mysql_result_t;

/// Returns the ABI version of this library, packed as
/// ((int64_t)MAJOR << 32) | MINOR. Same runtime-validation policy as the
/// PostgreSQL ABI :
///   - MAJOR mismatch                    -> fatal (StateError)
///   - linked.MINOR >= consumer.MINOR    -> OK (forward-compat)
///   - linked.MINOR <  consumer.MINOR    -> warning (non-blocking)
int64_t native_mysql_abi_version(void);

/// Initializes the Dart Native API (`dart_api_dl.h`). Must be called once
/// per isolate, passing `NativeApi.initializeApiDLData` from Dart.
/// Returns 0 on success, non-zero on failure.
///
/// Distinct symbol name from the PostgreSQL lib's `InitDartApiDL` so the
/// two libraries can coexist unambiguously in tooling and in a process
/// that loads both.
intptr_t native_mysql_init_dart_api(void* data);

/// After a Native Port notification, retrieves the stored result handle
/// produced by the worker for `conn`. Caller is responsible for
/// `native_mysql_clear_result` on every non-NULL return. Returns NULL
/// when no result is pending.
///
/// For statements with no row set (INSERT/UPDATE/DELETE) the returned
/// handle is still non-NULL: `native_mysql_row_count` /
/// `native_mysql_col_count` report 0, and `native_mysql_affected_rows`
/// carries the affected-row count.
native_mysql_result_t* native_mysql_poll_result(mysql_conn_t* conn);

/* ─────── Error surfacing (ABI MINOR 3) ─────── */

/// Last libmysqlclient error code captured on `conn` when its most recent
/// statement aborted (the `mysql_errno` at the point of failure). 0 when the
/// last statement succeeded — the field is reset before each statement. Read
/// only on the abort path (after a `2` notification), before any further
/// submit on this conn. Same drain-before-next-submit contract as the result.
unsigned int native_mysql_last_errno(mysql_conn_t* conn);

/// Last libmysqlclient error message captured on `conn` when its most recent
/// statement aborted (`mysql_error` at the point of failure). Empty string on
/// success. The returned pointer is owned by the conn and valid until the
/// next query on it — DO NOT free.
const char* native_mysql_last_error(mysql_conn_t* conn);

/* ─────── Result inspection (zero-copy reads) ─────── */

/// Number of rows in the result. 0 for non-SELECT statements.
int native_mysql_row_count(native_mysql_result_t* result);

/// Number of columns in the result. 0 for non-SELECT statements.
int native_mysql_col_count(native_mysql_result_t* result);

/// Affected-row count for the last DML statement (INSERT/UPDATE/DELETE),
/// as reported by `mysql_affected_rows`. Undefined for SELECT.
int64_t native_mysql_affected_rows(native_mysql_result_t* result);

/// Column name for the given column index. Returns a pointer into the
/// `MYSQL_RES` field metadata (valid until `native_mysql_clear_result`).
/// Caller MUST NOT free.
const char* native_mysql_field_name(native_mysql_result_t* result, int col);

/// Pointer to raw bytes of a cell (row, col). NULL if the cell is SQL
/// NULL. Pointer is valid until `native_mysql_clear_result` OR until the
/// next cell read from a DIFFERENT row (the wrapper caches one row at a
/// time). The Dart decoder reads a row's cells together before moving
/// on, so the pointer stays valid across a single row's columns. Values
/// use the MySQL text protocol (ASCII-encoded), like libpq text-mode.
const unsigned char* native_mysql_raw_value(native_mysql_result_t* result, int row, int col);

/// Length in bytes of a cell (row, col). 0 if the cell is SQL NULL.
int native_mysql_raw_length(native_mysql_result_t* result, int row, int col);

/// MySQL `enum_field_types` code for column [col] (e.g. MYSQL_TYPE_LONG=3,
/// MYSQL_TYPE_VAR_STRING=253). This is the decode key, the MySQL analogue
/// of the PostgreSQL type OID.
int native_mysql_field_type(native_mysql_result_t* result, int col);

/* ─────── Memory hygiene ─────── */

/// Frees a result handle previously returned by
/// `native_mysql_poll_result` (calls `mysql_free_result` on the wrapped
/// `MYSQL_RES*` and frees the wrapper). After this call, all pointers
/// returned by `native_mysql_field_name` / `native_mysql_raw_value` for
/// this result are dangling. Idempotent on NULL.
void native_mysql_clear_result(native_mysql_result_t* result);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_MYSQL_H */
