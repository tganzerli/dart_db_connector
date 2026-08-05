/// mongo_pool_internal.h — Private layout of `mongo_pool_t` /
/// `mongo_conn_t` / `native_mongo_result_t`, shared between
/// `mongo_pool.c`, `mongo_pool_worker.c` and `native_mongo.c`. NOT exposed
/// via the public ABI; nothing outside `native/c/src/` should include it.

#ifndef MONGO_POOL_INTERNAL_H
#define MONGO_POOL_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <mongoc/mongoc.h>

#include "mongo_pool.h"
#include "native_mongo.h"   // for the native_mongo_result_t typedef

/// Operation kinds carried in a slot. There is no universal query string in
/// MongoDB, so the operation IS the type (the vertical contract carries a
/// discriminated union instead of a SQL string).
enum mongo_op {
    MONGO_OP_FIND         = 1,
    MONGO_OP_INSERT_ONE   = 2,
    MONGO_OP_UPDATE_ONE   = 3,
    MONGO_OP_DELETE_ONE   = 4,
    MONGO_OP_COMMAND      = 5,
    MONGO_OP_INSERT_MANY  = 6   // ABI MINOR 1.1: bulk insert (F1-Mongo)
};

#define MONGO_ERR_BUF 512

/// Result wrapper. Owns a COPY of one returned BSON document buffer, because
/// the cursor / reply buffer libmongoc hands back is only valid until the
/// next `mongoc_cursor_next` / `bson_destroy`. Results are chained so
/// `native_mongo_poll_result` can return each document of a `find` in order
/// (analogous to the MySQL multi-read chain, ABI MINOR 2).
struct native_mongo_result {
    uint8_t* data;                       // owned copy of the BSON document
    int32_t  len;                        // byte length (== document length prefix)
    struct native_mongo_result* next;    // NULL for the last / a single reply
};

/// Per-connection state. Owns one `mongoc_client_t` (popped from the shared
/// client pool and held for the pool's lifetime) and one worker thread that
/// is the ONLY thread to touch that client (libmongoc clients are not
/// thread-safe).
struct mongo_conn {
    mongoc_client_t* client;       // popped from pool->client_pool (owned until push)
    struct mongo_pool* pool;       // back-pointer
    int32_t index;                 // position in pool->conns[]

    // ── Free-list state (protected by pool->mutex) ──
    int32_t in_use;                // 0 = free, 1 = checked out

    // ── Worker mailbox (protected by slot_mutex) ──
    pthread_t worker;
    pthread_mutex_t slot_mutex;
    pthread_cond_t  slot_cond;

    // ── Slot payload — valid iff slot_filled == 1 ──
    int slot_filled;
    int op;                        // enum mongo_op
    char* db;                      // owned copies
    char* coll;                    // NULL for MONGO_OP_COMMAND
    uint8_t* doc1;                 // owned copy: filter / document / selector / command
    int32_t  doc1_len;
    uint8_t* doc2;                 // owned copy: opts / update (NULL when unused)
    int32_t  doc2_len;
    int32_t  doc_count;            // MONGO_OP_INSERT_MANY: number of docs in doc1 blob
    int32_t  bulk_ordered;         // MONGO_OP_INSERT_MANY: 1 = ordered, 0 = unordered
    int64_t port_id;
    int64_t timeout_ms;

    // ── Result hand-off — set by worker before posting, drained by
    //    native_mongo_poll_result. Ownership passes to the caller. ──
    native_mongo_result_t* last_result;

    // ── Error hand-off — filled by the worker on an aborted op, read via
    //    native_mongo_last_error / _code. ──
    char    last_error[MONGO_ERR_BUF];
    int32_t last_error_code;

    // ── Shutdown flag (atomic; read in worker loop) ──
    _Atomic int shutdown_requested;
};

/// Pool state. Owns the shared libmongoc client pool, the URI, the conn
/// array, and the free-list mutex/condvar.
struct mongo_pool {
    mongoc_client_pool_t* client_pool;   // owned
    mongoc_uri_t* uri;                   // owned

    int32_t max_size;
    int64_t default_acquire_timeout_ms;

    struct mongo_conn* conns;            // contiguous array, length = max_size
    pthread_mutex_t mutex;               // protects in_use scans
    pthread_cond_t  free_cond;           // signaled by release

    _Atomic int shutting_down;           // 1 = mongo_pool_destroy in progress
};

/// Worker thread entry point. Defined in `mongo_pool_worker.c`. `arg` is the
/// `mongo_conn_t*` whose `client` field this worker services.
void* mongo_pool_worker_main(void* arg);

/// Frees the slot payload (db/coll strings + BSON buffers) and resets the
/// scalar fields. Caller MUST hold `conn->slot_mutex` OR be the teardown
/// path where the worker is already joined. Safe on an already-empty slot.
void mongo_pool_free_slot_payload(mongo_conn_t* conn);

#endif /* MONGO_POOL_INTERNAL_H */
