/// native_sqlite.h — Public ABI of libnative_sqlite.
///
///  — the SQLite counterpart of `native_mysql.h`, the
/// fourth driver and the first EMBEDDED one (in-process, synchronous, no
/// server, no network). A NEW, INDEPENDENT native ABI, versioned separately
/// from the PostgreSQL/MySQL/MongoDB libs; it does NOT alter them.
///
/// Governed by the ABI stability policy in CONTRIBUTING.md. Any change to a
/// signature, semantics, or ownership here is breaking and MUST carry an
/// ADR, a MAJOR/MINOR bump, and a synchronous update to
/// `dart/lib/src/bindings/sqlite_binding.dart`.
///
/// Why the thread-per-conn contract still applies to an embedded DB: SQLite
/// is synchronous, so a `sqlite3_step` over a heavy scan would block the
/// isolate. The worker thread offloads that blocking call, keeping the Dart
/// event loop free — the same vertical contract as the network drivers, but
/// the benefit is isolate-offload, not hiding network latency (cross-driver datum).
///
/// The result is MATERIALISED: `sqlite3_stmt` is a forward-only cursor whose
/// `sqlite3_column_*` pointers die on the next step, so the worker copies all
/// rows into an owned buffer; Dart reads cells zero-copy over that buffer.

#ifndef NATIVE_SQLITE_H
#define NATIVE_SQLITE_H

#include <stdint.h>

#include "sqlite_pool.h"

#define NATIVE_SQLITE_ABI_VERSION_MAJOR 1
// MINOR bumps (additive, non-breaking):
//   1 → sqlite_pool_submit_batch + sqlite_pool_submit_multi_read (N statements
//       in one round-trip, amortising the ~8µs Native Port overhead). 2026-07-27.
//   2 → sqlite_conn_exec_sync (synchronous fast-path for light queries: runs
//       on the CALLING thread, skipping the port + thread hop). 2026-07-27.
#define NATIVE_SQLITE_ABI_VERSION_MINOR 2

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque materialised result handle. Internal layout in
/// `sqlite_pool_internal.h`. Dart sees `Pointer<Void>`.
typedef struct native_sqlite_result native_sqlite_result_t;

/// ABI version packed as ((int64_t)MAJOR << 32) | MINOR. Same policy as the
/// other ABIs .
int64_t native_sqlite_abi_version(void);

/// Initializes the Dart Native API. Distinct symbol from the other libs so
/// all four can coexist in a process. Returns 0 on success.
intptr_t native_sqlite_init_dart_api(void* data);

/// After a Native Port notification (int64 = 1), retrieves the materialised
/// result for `conn`. Caller owns it and MUST call
/// `native_sqlite_clear_result`. Non-NULL even for DML (row/col = 0;
/// `native_sqlite_affected_rows` carries the change count).
native_sqlite_result_t* native_sqlite_poll_result(sqlite_conn_t* conn);

/* ─────── Result inspection (zero-copy reads over the owned buffer) ─────── */

/// Number of rows (0 for non-SELECT).
int native_sqlite_row_count(native_sqlite_result_t* result);

/// Number of columns (0 for non-SELECT).
int native_sqlite_col_count(native_sqlite_result_t* result);

/// `sqlite3_changes` snapshot for the last DML statement.
int64_t native_sqlite_affected_rows(native_sqlite_result_t* result);

/// Column name for [col] (pointer into the owned buffer; do not free).
const char* native_sqlite_col_name(native_sqlite_result_t* result, int col);

/// SQLite dynamic type of cell (row, col): 1=INTEGER, 2=FLOAT, 3=TEXT,
/// 4=BLOB, 5=NULL (the `sqlite3_column_type` codes) — the decode key.
int native_sqlite_cell_type(native_sqlite_result_t* result, int row, int col);

/// Pointer to the raw bytes of cell (row, col); NULL if the cell is SQL
/// NULL. Valid until `native_sqlite_clear_result`. INTEGER/FLOAT are stored
/// as their little-endian 8-byte representation; TEXT/BLOB as-is.
const unsigned char* native_sqlite_raw_value(native_sqlite_result_t* result,
                                             int row, int col);

/// Length in bytes of cell (row, col). 8 for INTEGER/FLOAT, byte length for
/// TEXT/BLOB, 0 for NULL.
int native_sqlite_raw_length(native_sqlite_result_t* result, int row, int col);

/* ─────── Error propagation (last failed op on this conn) ─────── */

/// After int64 = 2 (aborted), the `sqlite3_errmsg` of the failure, or "".
/// Valid until the next submit on this conn. Do not free.
const char* native_sqlite_last_error(sqlite_conn_t* conn);

/// The `sqlite3_extended_errcode` of the last failure, or 0.
int32_t native_sqlite_last_error_code(sqlite_conn_t* conn);

/* ─────── Memory hygiene ─────── */

/// Frees a materialised result (all copied cells + names + arrays).
/// Idempotent on NULL.
void native_sqlite_clear_result(native_sqlite_result_t* result);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_SQLITE_H */
