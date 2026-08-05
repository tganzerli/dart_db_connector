/// sqlite_pool_internal.h — Private layout of `sqlite_pool_t` /
/// `sqlite_conn_t` / `native_sqlite_result_t`, shared between
/// `sqlite_pool.c`, `sqlite_pool_worker.c` and `native_sqlite.c`. NOT
/// exposed via the public ABI.

#ifndef SQLITE_POOL_INTERNAL_H
#define SQLITE_POOL_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sqlite3.h>

#include "sqlite_pool.h"
#include "native_sqlite.h"

#define SQLITE_ERR_BUF 512

/// Materialised result. `sqlite3_stmt` is a forward-only cursor whose
/// column pointers die on the next step, so the worker copies every cell
/// into owned buffers. Cells are stored row-major (row*col_count + col).
/// INTEGER/FLOAT are stored as their 8-byte LE representation; TEXT/BLOB
/// as-is; NULL as a NULL pointer with len 0.
struct native_sqlite_result {
    int col_count;
    int64_t row_count;
    int64_t affected_rows;         // sqlite3_changes snapshot (DML)

    char** col_names;              // [col_count], owned copies

    int* cell_types;               // [row_count*col_count] sqlite3_column_type
    int32_t* cell_lens;            // [row_count*col_count] byte length
    uint8_t** cell_data;           // [row_count*col_count] owned bytes (or NULL)

    // ABI MINOR 1 — multi-read: results are chained so poll_result returns
    // each of the N result sets in order (NULL for a single result).
    struct native_sqlite_result* next;
};

/// Per-connection state. Owns one `sqlite3*` opened on the shared file (WAL)
/// and one worker thread that is the ONLY thread to touch that handle.
struct sqlite_conn {
    sqlite3* db;                   // libsqlite3 handle (owned)
    struct sqlite_pool* pool;      // back-pointer
    int32_t index;

    // ── Free-list state (protected by pool->mutex) ──
    int32_t in_use;

    // ── Worker mailbox (protected by slot_mutex) ──
    pthread_t worker;
    pthread_mutex_t slot_mutex;
    pthread_cond_t  slot_cond;

    // Slot payload — valid iff slot_filled == 1.
    int slot_filled;
    int is_batch;                  // 1 = `sql` is a ';'-joined write batch (MINOR 1)
    int is_multi_read;             // 1 = `sql` is a ';'-joined multi-read (MINOR 1)
    char* sql;                     // owned copy
    int64_t port_id;
    int64_t timeout_ms;

    // Result hand-off — set by worker, drained by native_sqlite_poll_result.
    native_sqlite_result_t* last_result;

    // Error hand-off — filled by the worker on abort.
    char    last_error[SQLITE_ERR_BUF];
    int32_t last_error_code;

    _Atomic int shutdown_requested;
};

/// Pool state. Owns the conn array + the file path (to reopen conns) +
/// the free-list mutex/condvar.
struct sqlite_pool {
    char* path;                    // owned copy of the DB file path
    int32_t busy_timeout_ms;

    int32_t max_size;
    int64_t default_acquire_timeout_ms;

    struct sqlite_conn* conns;     // contiguous, length = max_size
    pthread_mutex_t mutex;
    pthread_cond_t  free_cond;

    _Atomic int shutting_down;
};

/// Worker thread entry point (defined in sqlite_pool_worker.c). `arg` is the
/// `sqlite_conn_t*` whose `db` this worker services.
void* sqlite_pool_worker_main(void* arg);

/// Runs one SQL statement on `conn` (prepare/step/materialise), storing the
/// result in `conn->last_result`. Returns 1 (ok) / 2 (aborted). Defined in
/// `sqlite_pool_worker.c`; reused by `sqlite_conn_exec_sync` (the sync
/// fast-path in `sqlite_pool.c`), which runs it on the CALLING thread.
int64_t sqlite_pool_execute_query(sqlite_conn_t* conn, const char* sql);

/// Frees the slot payload (sql string) and resets scalars. Caller holds
/// slot_mutex OR is the joined-teardown path.
void sqlite_pool_free_slot_payload(sqlite_conn_t* conn);

#endif /* SQLITE_POOL_INTERNAL_H */
