/// native_db.h — Public ABI of libnative_db.
///
/// Governed by the ABI stability policy in CONTRIBUTING.md. Any change to a
/// signature, semantics, or ownership convention here is a breaking change
/// in ABI and MUST be accompanied by:
///   1. A design note in CHANGELOG.md.
///   2. A bump of NATIVE_DB_ABI_VERSION_MAJOR (breaking) or
///      NATIVE_DB_ABI_VERSION_MINOR (additive non-breaking).
///   3. A synchronous update to `dart/lib/src/bindings/postgres_binding.dart`
///      in the same PR.
///
/// Linked Dart binding: `package:dart_db_connector/src/bindings/postgres_binding.dart`.

#ifndef NATIVE_DB_H
#define NATIVE_DB_H

#include <stdint.h>
#include <libpq-fe.h>

#include "native_pool.h"

/// Semantic ABI version. Incremented per the ABI stability policy in CONTRIBUTING.md.
/// MAJOR 1 → 2 introduced in 2026-05-20: `start_query_async` and
/// `start_pipeline_async` removed in favour of the native thread/conn
/// pool (`pool_*` in `native_pool.h`). `cancel_query(PGconn*)` was
/// renamed to `pool_cancel(native_conn_t*)`, and `poll_result`'s first
/// parameter changed type from `PGconn*` to `native_conn_t*`..
#define NATIVE_DB_ABI_VERSION_MAJOR 2
// MINOR bumps (additive, non-breaking):
//   1 → `pool_submit_query_params` added (Extended Query Protocol —
//       parameter binding + optional binary result). 2026-05-23.
//       Legacy `pool_submit_query` preserved unchanged.
//   2 → `pool_submit_multi_read` added (N read statements in one
//       round-trip, results preserved as a per-conn chain) plus
//       `get_result_status` / `get_error_message` (surface the real
//       server error of a PGresult). 2026-07-28. Legacy paths
//       unchanged.
#define NATIVE_DB_ABI_VERSION_MINOR 2

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the ABI version of this library, packed as
/// ((int64_t)MAJOR << 32) | MINOR. Use to validate at runtime that the
/// linked .dylib/.so/.dll matches the Dart package's expectations.
///
/// Validation policy:
///   - MAJOR mismatch                    -> fatal (StateError)
///   - linked.MINOR >= consumer.MINOR    -> OK (forward-compat)
///   - linked.MINOR <  consumer.MINOR    -> warning (non-blocking)
int64_t native_db_abi_version(void);

/// Initializes the Dart Native API (`dart_api_dl.h`). Must be called once,
/// early in main(), passing `NativeApi.initializeApiDLData` from Dart.
/// Returns 0 on success, non-zero on failure.
intptr_t InitDartApiDL(void* data);

/// Opens a PostgreSQL connection using the libpq conninfo string.
/// Returns NULL on failure (libpq error printed to stderr). The returned
/// connection is set to non-blocking mode via PQsetnonblocking.
///
/// Preserved in MAJOR 2 as a primitive for tests, PoCs, and internal use
/// by `pool_create`. Application code should prefer `pool_create` +
/// `pool_acquire` instead of managing raw `PGconn*` directly.
PGconn* connect_db(const char* conninfo);

/// After a Native Port notification, retrieves the next PGresult from
/// the connection's libpq queue. Caller is responsible for
/// `clear_result` on every non-NULL return. Returns NULL when no more
/// results are pending.
///
/// ABI MAJOR 2: first parameter changed from `PGconn*` to
/// `native_conn_t*` (opaque pool handle). The symbol name and arity
/// stay the same to minimise churn on the Dart binding.
PGresult* poll_result(native_conn_t* conn);

/// Closes a raw `PGconn*` via `PQfinish`. Used by callers of
/// `connect_db` outside of a pool. Conns owned by a `native_pool_t`
/// are closed automatically by `pool_destroy`; calling `close_db` on
/// them is undefined behaviour.
void close_db(PGconn* conn);

/* ─────── Result inspection (zero-copy reads) — added in ABI MINOR 3 of MAJOR 1; invariant in MAJOR 2 ─────── */

/// Number of rows in the result.
int get_row_count(PGresult* result);

/// Number of columns in the result.
int get_col_count(PGresult* result);

/// Column name for the given column index. Returns pointer into PGresult
/// memory (valid until PQclear). Caller MUST NOT free.
const char* get_field_name(PGresult* result, int col);

/// Pointer to raw bytes of a cell (row, col). NULL if cell is NULL.
/// Pointer is valid until PQclear. Caller MUST NOT free; the Dart side
/// is expected to wrap this in a Uint8List view for zero-copy access.
const unsigned char* get_raw_value(PGresult* result, int row, int col);

/// Length in bytes of a cell (row, col). 0 if cell is NULL.
int get_raw_length(PGresult* result, int row, int col);

/// PostgreSQL type OID for column [col]. Use with `pg_type.dat` to
/// decode values. Stable across Postgres versions for built-in types.
unsigned int get_field_type(PGresult* result, int col);

/* ─────── Result status / error (ABI MINOR 2, 2026-07-28) ─────── */

/// Raw `PQresultStatus` of a PGresult, cast to int (the libpq
/// `ExecStatusType` enum). Lets the Dart side distinguish a
/// successful tuple/command result from an error result — needed for
/// the multi-read path (an error in statement K arrives as an error
/// PGresult in the chain) and to stop the single path from swallowing
/// SQL errors as an empty result set. Values of interest:
///   0 PGRES_EMPTY_QUERY   1 PGRES_COMMAND_OK   2 PGRES_TUPLES_OK
///   5 PGRES_BAD_RESPONSE  6 PGRES_NONFATAL_ERROR  7 PGRES_FATAL_ERROR
int get_result_status(PGresult* result);

/// Server-side error message for a PGresult (`PQresultErrorMessage`).
/// Returns a pointer into PGresult memory (valid until `clear_result`);
/// an empty string (never NULL) when the result carries no error.
/// Caller MUST NOT free.
const char* get_error_message(PGresult* result);

/* ─────── Memory hygiene — added in ABI MINOR 5 of MAJOR 1; invariant in MAJOR 2 ─────── */

/// Frees a PGresult previously returned by `poll_result`. After this
/// call, all pointers returned by `get_field_name` / `get_raw_value`
/// for this result are dangling and MUST NOT be dereferenced.
/// Idempotent on NULL.
///
/// Without this, libpq retains every PGresult until `close_db`,
/// causing unbounded memory growth in long-running workloads.
void clear_result(PGresult* result);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_DB_H */
