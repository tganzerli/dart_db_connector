/// mysql_pool_internal.h — Private layout of `mysql_pool_t` /
/// `mysql_conn_t` / `native_mysql_result_t`, shared between
/// `mysql_pool.c`, `mysql_pool_worker.c` and `native_mysql.c`. NOT
/// exposed via the public ABI; nothing outside `native/c/src/` should
/// include this file.

#ifndef MYSQL_POOL_INTERNAL_H
#define MYSQL_POOL_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <mysql.h>

#include "mysql_pool.h"
#include "native_mysql.h"   // for the native_mysql_result_t typedef

/// Result wrapper. Owns the `MYSQL_RES*` and caches exactly one fetched
/// row so that random-access cell reads stay zero-copy: `mysql_store_result`
/// buffers all rows client-side, but `mysql_fetch_row` yields a
/// `MYSQL_ROW` valid only until the next fetch. The Dart decoder reads a
/// row's columns together, so caching one row covers that access pattern.
struct native_mysql_result {
    MYSQL_RES* res;             // NULL for non-SELECT statements (owned)
    int64_t affected_rows;      // mysql_affected_rows() snapshot (DML)
    int col_count;              // mysql_num_fields(res), cached

    int64_t cached_row;         // index of the row currently in `row`; -1 = none
    MYSQL_ROW row;              // pointers into libmysqlclient buffers (borrowed)
    unsigned long* lengths;     // per-column byte lengths of `row` (borrowed)

    // ABI MINOR 2 — multi-read: results are chained so poll_result can
    // return each of the N result sets in order (NULL for single-result).
    struct native_mysql_result* next;
};

/// Per-connection state. Owns the MySQL handle, the worker thread, and a
/// single-slot mailbox the worker drains. MySQL's client API is blocking,
/// so there is no libpq-style non-blocking socket loop; the worker simply
/// blocks in `mysql_real_query`.
struct mysql_conn {
    MYSQL* my;                     // libmysqlclient handle (owned)
    unsigned long thread_id;       // mysql_thread_id — target for KILL QUERY
    struct mysql_pool* pool;       // back-pointer (params + shutdown reads)
    int32_t index;                 // position in pool->conns[]

    // ── Free-list state (protected by pool->mutex) ──
    int32_t in_use;                // 0 = free, 1 = checked out

    // ── Worker mailbox (protected by slot_mutex) ──
    pthread_t worker;
    pthread_mutex_t slot_mutex;
    pthread_cond_t  slot_cond;     // worker waits here; submit signals

    // Slot payload — valid iff slot_filled == 1.
    int slot_filled;
    int is_batch;                  // 1 = `sql` is a ';'-joined batch (ABI MINOR 1)
    int is_multi_read;             // 1 = `sql` is a ';'-joined multi-read (ABI MINOR 2)
    char* sql;                     // heap-allocated copy (owned)
    int64_t port_id;
    int64_t timeout_ms;

    // ── Result hand-off — set by worker before posting, drained by
    //    native_mysql_poll_result. Ownership passes to the caller. ──
    native_mysql_result_t* last_result;

    // ── Last error (ABI MINOR 3) — captured by the worker at the moment a
    //    query fails, read by Dart only on the abort path via
    //    native_mysql_last_errno / native_mysql_last_error. Fixed buffer
    //    (no allocation on the error path). Valid until the next query on
    //    this conn. Reset at the start of each execute_*. ──
    unsigned int last_errno;
    char last_error[512];  // MYSQL_ERRMSG_SIZE

    // ── Shutdown flag (atomic; read in worker loop) ──
    _Atomic int shutdown_requested;
};

/// Pool state. Owns the connection array, the global free-list
/// mutex/condvar, and the connection credentials (needed to open the
/// side channel used by `mysql_pool_cancel`).
struct mysql_pool {
    char* host;                    // owned copies (free in destroy)
    char* user;
    char* password;
    char* db;
    uint16_t port;

    int32_t max_size;
    int64_t default_acquire_timeout_ms;

    struct mysql_conn* conns;      // contiguous array, length = max_size
    pthread_mutex_t mutex;         // protects in_use scans
    pthread_cond_t  free_cond;     // signaled by release

    _Atomic int shutting_down;     // 1 = mysql_pool_destroy in progress
};

/// Worker thread entry point. Defined in `mysql_pool_worker.c`. `arg` is
/// the `mysql_conn_t*` whose `my` field this worker services.
void* mysql_pool_worker_main(void* arg);

/// Frees the slot payload (sql string) and resets the scalar fields.
/// Caller MUST hold `conn->slot_mutex` OR be the teardown path where the
/// worker is already joined. Safe on an already-empty slot.
void mysql_pool_free_slot_payload(mysql_conn_t* conn);

/// Opens a short-lived MySQL connection from the pool's credentials and
/// issues `KILL QUERY <thread_id>`. Best-effort; used by
/// `mysql_pool_cancel`. Defined in `mysql_pool.c`.
void mysql_pool_kill_query(struct mysql_pool* pool, unsigned long thread_id);

#endif /* MYSQL_POOL_INTERNAL_H */
