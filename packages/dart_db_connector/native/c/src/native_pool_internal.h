/// native_pool_internal.h — Private layout of `native_pool_t` /
/// `native_conn_t`, shared between `native_pool.c` and
/// `native_pool_worker.c`. NOT exposed via the public ABI; nothing
/// outside `native/c/src/` should include this file.

#ifndef NATIVE_POOL_INTERNAL_H
#define NATIVE_POOL_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <libpq-fe.h>

#include "native_pool.h"

/// FIFO node holding one `PGresult*` pre-drained by the worker for the
/// multi-read path (ABI MINOR 2). The worker drains ALL results of a
/// multi-statement submit into this chain BEFORE posting the OK
/// notification, so the Dart side never blocks on `PQgetResult` while
/// polling — the non-blocking invariant of the vertical contract.
typedef struct pg_result_node {
    PGresult* result;
    struct pg_result_node* next;
} pg_result_node_t;

/// Per-connection state. Owns the libpq handle, the worker thread,
/// and a single-slot mailbox the worker drains.
struct native_conn {
    PGconn* pg;                    // libpq handle (owned)
    struct native_pool* pool;      // back-pointer for shutdown reads
    int32_t index;                 // position in pool->conns[]

    // ── Free-list state (protected by pool->mutex) ──
    int32_t in_use;                // 0 = free, 1 = checked out

    // ── Worker mailbox (protected by slot_mutex) ──
    pthread_t worker;
    pthread_mutex_t slot_mutex;
    pthread_cond_t  slot_cond;     // worker waits here; submit signals

    // Slot payload — valid iff slot_filled == 1.
    int slot_filled;
    int is_pipeline;               // 0 = single query, 1 = pipeline
    int is_params;                 // ABI MINOR 1: 1 = use PQsendQueryParams
    int is_multi_read;             // ABI MINOR 2: 1 = multi-statement, chain results
    char** sql;                    // heap-allocated copy; sql[0..count-1]
    int32_t sql_count;             // 1 for single query, N for pipeline/multi-read

    // ABI MINOR 1 — Extended Protocol payload (valid iff is_params == 1).
    // Mutually exclusive with is_pipeline (a paramized query is always
    // a single statement in v1; pipeline + params is future work).
    int32_t n_params;
    int32_t* param_types;          // owned, length n_params (0 = let server infer)
    char** param_values;           // owned, length n_params (each value owned)
    int* param_lengths;            // owned, length n_params (bytes; ignored for text)
    int* param_formats;            // owned, length n_params (0 = text, 1 = binary)
    int result_format;             // 0 = text (default), 1 = binary

    int64_t port_id;
    int64_t timeout_ms;

    // ── Multi-read result chain (ABI MINOR 2) ──
    // Populated by the worker's `execute_multi_read` before it posts OK;
    // drained by `poll_result` on the Dart isolate thread. Only one of
    // the two threads touches it at a time (the worker before the post,
    // Dart after receiving the post), so no dedicated lock is required.
    // Freed on `pool_release`/teardown to survive an abandoned drain.
    pg_result_node_t* chain_head;
    pg_result_node_t* chain_tail;

    // ── Shutdown flag (atomic; read in worker loop) ──
    _Atomic int shutdown_requested;
};

/// Pool state. Owns the connection array, the global free-list
/// mutex/condvar, and the default acquire deadline.
struct native_pool {
    char* conninfo;                // owned copy (free in destroy)
    int32_t max_size;
    int64_t default_acquire_timeout_ms;

    struct native_conn* conns;     // contiguous array, length = max_size
    pthread_mutex_t mutex;         // protects in_use scans
    pthread_cond_t  free_cond;     // signaled by release

    _Atomic int shutting_down;     // 1 = pool_destroy in progress
};

/// Worker thread entry point. Defined in `native_pool_worker.c`.
/// The `arg` is the `native_conn_t*` whose `pg` field this worker
/// services.
void* native_pool_worker_main(void* arg);

/// Frees the slot payload (sql[] entries + array) and resets the
/// scalar fields. Caller MUST hold `conn->slot_mutex` OR be the
/// teardown path where the worker is already joined. Safe on an
/// already-empty slot.
void native_pool_free_slot_payload(native_conn_t* conn);

/// Frees every remaining node of the multi-read result chain
/// (`PQclear` on each `PGresult` + `free` on the node) and resets
/// `chain_head`/`chain_tail` to NULL. Called when a drain is
/// abandoned (Dart polled fewer than N), on `pool_release`, and on
/// teardown. Safe on an empty chain. Defined in `native_pool.c`;
/// declared here so the worker can reset a stale chain before a new
/// multi-read.
void native_pool_free_result_chain(native_conn_t* conn);

/// Appends `result` to the connection's multi-read chain (FIFO).
/// Called only by the worker inside `execute_multi_read`, before the
/// OK post. Returns 0 on OOM (the caller aborts the multi-read).
int native_pool_chain_append(native_conn_t* conn, PGresult* result);

#endif /* NATIVE_POOL_INTERNAL_H */
