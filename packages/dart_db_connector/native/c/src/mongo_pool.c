/// mongo_pool.c — Lifecycle and dispatch primitives for the MongoDB native
/// thread/conn pool (thread-per-conn over libmongoc's client pool). Mirrors
/// `mysql_pool.c` but the native core differs per the C.0 pool-model
/// decision: one shared
/// `mongoc_client_pool_t`, each worker owning one popped client for life.

#include "mongo_pool.h"
#include "native_mongo.h"
#include "mongo_pool_internal.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mongoc/mongoc.h>

// ─────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────

// libmongoc must be initialised once per process before any client is used.
static pthread_once_t g_mongoc_once = PTHREAD_ONCE_INIT;
static void init_mongoc_library(void) { mongoc_init(); }

static void deadline_from_ms(struct timespec* ts, int64_t delta_ms) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec  += delta_ms / 1000;
    ts->tv_nsec += (delta_ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_sec  += 1;
        ts->tv_nsec -= 1000000000L;
    }
}

static char* dup_string(const char* s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out == NULL) return NULL;
    memcpy(out, s, n);
    return out;
}

static uint8_t* dup_bytes(const uint8_t* src, int32_t len) {
    if (src == NULL || len <= 0) return NULL;
    uint8_t* out = (uint8_t*)malloc((size_t)len);
    if (out == NULL) return NULL;
    memcpy(out, src, (size_t)len);
    return out;
}

void mongo_pool_free_slot_payload(mongo_conn_t* conn) {
    free(conn->db);   conn->db = NULL;
    free(conn->coll); conn->coll = NULL;
    free(conn->doc1); conn->doc1 = NULL; conn->doc1_len = 0;
    free(conn->doc2); conn->doc2 = NULL; conn->doc2_len = 0;
    conn->doc_count = 0;
    conn->bulk_ordered = 0;
    conn->op = 0;
    conn->port_id = 0;
    conn->timeout_ms = 0;
}

// Initializes one mongo_conn_t: pops a client, sets up mutex/condvar, starts
// the worker. Returns 0 on success, -1 on failure (partial cleanup done).
static int init_conn(mongo_conn_t* conn, struct mongo_pool* pool, int32_t index) {
    conn->pool = pool;
    conn->index = index;
    conn->in_use = 0;
    conn->slot_filled = 0;
    conn->op = 0;
    conn->db = NULL;
    conn->coll = NULL;
    conn->doc1 = NULL; conn->doc1_len = 0;
    conn->doc2 = NULL; conn->doc2_len = 0;
    conn->doc_count = 0;
    conn->bulk_ordered = 0;
    conn->port_id = 0;
    conn->timeout_ms = 0;
    conn->last_result = NULL;
    conn->last_error[0] = '\0';
    conn->last_error_code = 0;
    atomic_init(&conn->shutdown_requested, 0);

    // Pop this worker's dedicated client (held for the pool's lifetime).
    conn->client = mongoc_client_pool_pop(pool->client_pool);
    if (conn->client == NULL) {
        fprintf(stderr, "mongo_pool_create: client pool pop failed (conn %d)\n", index);
        return -1;
    }

    if (pthread_mutex_init(&conn->slot_mutex, NULL) != 0) {
        mongoc_client_pool_push(pool->client_pool, conn->client);
        conn->client = NULL;
        return -1;
    }
    if (pthread_cond_init(&conn->slot_cond, NULL) != 0) {
        pthread_mutex_destroy(&conn->slot_mutex);
        mongoc_client_pool_push(pool->client_pool, conn->client);
        conn->client = NULL;
        return -1;
    }
    if (pthread_create(&conn->worker, NULL, mongo_pool_worker_main, conn) != 0) {
        pthread_cond_destroy(&conn->slot_cond);
        pthread_mutex_destroy(&conn->slot_mutex);
        mongoc_client_pool_push(pool->client_pool, conn->client);
        conn->client = NULL;
        return -1;
    }
    return 0;
}

// Joins the worker, frees per-conn resources, pushes the client back to the
// shared pool. Caller must have set shutdown_requested = 1 and signaled.
static void teardown_conn(mongo_conn_t* conn) {
    if (conn->client == NULL) return;  // never initialised
    pthread_join(conn->worker, NULL);
    mongo_pool_free_slot_payload(conn);
    // Free any undrained result chain.
    native_mongo_result_t* r = conn->last_result;
    while (r != NULL) {
        native_mongo_result_t* next = r->next;
        native_mongo_clear_result(r);
        r = next;
    }
    conn->last_result = NULL;
    pthread_cond_destroy(&conn->slot_cond);
    pthread_mutex_destroy(&conn->slot_mutex);
    mongoc_client_pool_push(conn->pool->client_pool, conn->client);
    conn->client = NULL;
}

// ─────────────────────────────────────────────────────────────────
// Public API — pool lifecycle
// ─────────────────────────────────────────────────────────────────

mongo_pool_t* mongo_pool_create(const char* uri_str,
                                int32_t min_size,
                                int32_t max_size,
                                int64_t acquire_timeout_ms) {
    (void)min_size;  // reserved for future warm-up policy

    if (uri_str == NULL || max_size < 1) {
        fprintf(stderr, "mongo_pool_create: invalid arguments\n");
        return NULL;
    }

    pthread_once(&g_mongoc_once, init_mongoc_library);

    bson_error_t uerr;
    mongoc_uri_t* uri = mongoc_uri_new_with_error(uri_str, &uerr);
    if (uri == NULL) {
        fprintf(stderr, "mongo_pool_create: bad uri: %s\n", uerr.message);
        return NULL;
    }
    // Ensure the client pool can hand out one client per worker.
    mongoc_uri_set_option_as_int32(uri, MONGOC_URI_MAXPOOLSIZE, max_size);

    mongo_pool_t* pool = (mongo_pool_t*)calloc(1, sizeof(*pool));
    if (pool == NULL) { mongoc_uri_destroy(uri); return NULL; }

    pool->uri = uri;
    pool->max_size = max_size;
    pool->default_acquire_timeout_ms = acquire_timeout_ms;
    atomic_init(&pool->shutting_down, 0);

    pool->client_pool = mongoc_client_pool_new(uri);
    if (pool->client_pool == NULL) {
        fprintf(stderr, "mongo_pool_create: client_pool_new failed\n");
        mongoc_uri_destroy(uri);
        free(pool);
        return NULL;
    }

    if (pthread_mutex_init(&pool->mutex, NULL) != 0 ||
        pthread_cond_init(&pool->free_cond, NULL) != 0) {
        mongoc_client_pool_destroy(pool->client_pool);
        mongoc_uri_destroy(uri);
        free(pool);
        return NULL;
    }

    pool->conns = (mongo_conn_t*)calloc((size_t)max_size, sizeof(*pool->conns));
    if (pool->conns == NULL) {
        pthread_cond_destroy(&pool->free_cond);
        pthread_mutex_destroy(&pool->mutex);
        mongoc_client_pool_destroy(pool->client_pool);
        mongoc_uri_destroy(uri);
        free(pool);
        return NULL;
    }

    for (int32_t i = 0; i < max_size; i++) {
        if (init_conn(&pool->conns[i], pool, i) != 0) {
            for (int32_t j = 0; j < i; j++) {
                atomic_store(&pool->conns[j].shutdown_requested, 1);
                pthread_mutex_lock(&pool->conns[j].slot_mutex);
                pthread_cond_signal(&pool->conns[j].slot_cond);
                pthread_mutex_unlock(&pool->conns[j].slot_mutex);
                teardown_conn(&pool->conns[j]);
            }
            free(pool->conns);
            pthread_cond_destroy(&pool->free_cond);
            pthread_mutex_destroy(&pool->mutex);
            mongoc_client_pool_destroy(pool->client_pool);
            mongoc_uri_destroy(uri);
            free(pool);
            return NULL;
        }
    }

    return pool;
}

void mongo_pool_destroy(mongo_pool_t* pool) {
    if (pool == NULL) return;

    atomic_store(&pool->shutting_down, 1);

    for (int32_t i = 0; i < pool->max_size; i++) {
        mongo_conn_t* c = &pool->conns[i];
        atomic_store(&c->shutdown_requested, 1);
        pthread_mutex_lock(&c->slot_mutex);
        pthread_cond_signal(&c->slot_cond);
        pthread_mutex_unlock(&c->slot_mutex);
    }

    for (int32_t i = 0; i < pool->max_size; i++) {
        teardown_conn(&pool->conns[i]);
    }

    pthread_mutex_lock(&pool->mutex);
    pthread_cond_broadcast(&pool->free_cond);
    pthread_mutex_unlock(&pool->mutex);

    free(pool->conns);
    pthread_cond_destroy(&pool->free_cond);
    pthread_mutex_destroy(&pool->mutex);
    mongoc_client_pool_destroy(pool->client_pool);
    mongoc_uri_destroy(pool->uri);
    free(pool);
}

// ─────────────────────────────────────────────────────────────────
// Public API — acquire / release
// ─────────────────────────────────────────────────────────────────

mongo_conn_t* mongo_pool_acquire(mongo_pool_t* pool, int64_t timeout_ms) {
    if (pool == NULL) return NULL;
    if (atomic_load(&pool->shutting_down)) return NULL;

    int64_t effective_ms = timeout_ms;
    if (effective_ms == 0) effective_ms = pool->default_acquire_timeout_ms;

    struct timespec deadline;
    int use_deadline = (effective_ms > 0);
    if (use_deadline) deadline_from_ms(&deadline, effective_ms);

    pthread_mutex_lock(&pool->mutex);
    while (1) {
        if (atomic_load(&pool->shutting_down)) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;
        }
        for (int32_t i = 0; i < pool->max_size; i++) {
            if (pool->conns[i].in_use == 0) {
                pool->conns[i].in_use = 1;
                pthread_mutex_unlock(&pool->mutex);
                return &pool->conns[i];
            }
        }
        if (effective_ms == 0) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;  // non-blocking probe
        }
        int rc = use_deadline
            ? pthread_cond_timedwait(&pool->free_cond, &pool->mutex, &deadline)
            : pthread_cond_wait(&pool->free_cond, &pool->mutex);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;
        }
    }
}

void mongo_pool_release(mongo_pool_t* pool, mongo_conn_t* conn) {
    if (pool == NULL || conn == NULL) return;
    pthread_mutex_lock(&pool->mutex);
    conn->in_use = 0;
    pthread_cond_signal(&pool->free_cond);
    pthread_mutex_unlock(&pool->mutex);
}

// ─────────────────────────────────────────────────────────────────
// Public API — typed submissions
// ─────────────────────────────────────────────────────────────────

// Fills the slot with a typed op and dispatches. Takes ownership of nothing;
// copies db/coll/doc1/doc2. Returns 1 on success, 0 if busy/shutdown/OOM.
static int submit_op(mongo_conn_t* conn, int op,
                     const char* db, const char* coll,
                     const uint8_t* doc1, int32_t doc1_len,
                     const uint8_t* doc2, int32_t doc2_len,
                     int32_t doc_count, int32_t ordered,
                     int64_t port_id, int64_t timeout_ms) {
    if (conn == NULL || db == NULL || doc1 == NULL || doc1_len <= 0) return 0;

    char* db_copy = dup_string(db);
    char* coll_copy = (coll != NULL) ? dup_string(coll) : NULL;
    uint8_t* d1 = dup_bytes(doc1, doc1_len);
    uint8_t* d2 = (doc2 != NULL && doc2_len > 0) ? dup_bytes(doc2, doc2_len) : NULL;
    if (db_copy == NULL || d1 == NULL ||
        (coll != NULL && coll_copy == NULL) ||
        (doc2 != NULL && doc2_len > 0 && d2 == NULL)) {
        free(db_copy); free(coll_copy); free(d1); free(d2);
        return 0;
    }

    pthread_mutex_lock(&conn->slot_mutex);
    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        free(db_copy); free(coll_copy); free(d1); free(d2);
        return 0;
    }

    conn->slot_filled = 1;
    conn->op = op;
    conn->db = db_copy;
    conn->coll = coll_copy;
    conn->doc1 = d1; conn->doc1_len = doc1_len;
    conn->doc2 = d2; conn->doc2_len = (d2 != NULL) ? doc2_len : 0;
    conn->doc_count = doc_count;
    conn->bulk_ordered = ordered;
    conn->port_id = port_id;
    conn->timeout_ms = timeout_ms;

    pthread_cond_signal(&conn->slot_cond);
    pthread_mutex_unlock(&conn->slot_mutex);
    return 1;
}

int mongo_pool_submit_find(mongo_conn_t* conn,
                           const char* db, const char* coll,
                           const uint8_t* filter_bson, int32_t filter_len,
                           const uint8_t* opts_bson, int32_t opts_len,
                           int64_t port_id, int64_t timeout_ms) {
    return submit_op(conn, MONGO_OP_FIND, db, coll,
                     filter_bson, filter_len, opts_bson, opts_len,
                     0, 0, port_id, timeout_ms);
}

int mongo_pool_submit_insert_one(mongo_conn_t* conn,
                                 const char* db, const char* coll,
                                 const uint8_t* doc_bson, int32_t doc_len,
                                 int64_t port_id, int64_t timeout_ms) {
    return submit_op(conn, MONGO_OP_INSERT_ONE, db, coll,
                     doc_bson, doc_len, NULL, 0, 0, 0, port_id, timeout_ms);
}

int mongo_pool_submit_update_one(mongo_conn_t* conn,
                                 const char* db, const char* coll,
                                 const uint8_t* selector_bson, int32_t selector_len,
                                 const uint8_t* update_bson, int32_t update_len,
                                 int64_t port_id, int64_t timeout_ms) {
    return submit_op(conn, MONGO_OP_UPDATE_ONE, db, coll,
                     selector_bson, selector_len, update_bson, update_len,
                     0, 0, port_id, timeout_ms);
}

int mongo_pool_submit_delete_one(mongo_conn_t* conn,
                                 const char* db, const char* coll,
                                 const uint8_t* selector_bson, int32_t selector_len,
                                 int64_t port_id, int64_t timeout_ms) {
    return submit_op(conn, MONGO_OP_DELETE_ONE, db, coll,
                     selector_bson, selector_len, NULL, 0, 0, 0,
                     port_id, timeout_ms);
}

int mongo_pool_submit_command(mongo_conn_t* conn,
                              const char* db,
                              const uint8_t* command_bson, int32_t command_len,
                              int64_t port_id, int64_t timeout_ms) {
    return submit_op(conn, MONGO_OP_COMMAND, db, NULL,
                     command_bson, command_len, NULL, 0, 0, 0,
                     port_id, timeout_ms);
}

int mongo_pool_submit_insert_many(mongo_conn_t* conn,
                                  const char* db, const char* coll,
                                  const uint8_t* docs_bson, int32_t docs_total_len,
                                  int32_t doc_count, int32_t ordered,
                                  int64_t port_id, int64_t timeout_ms) {
    if (doc_count <= 0) return 0;  // empty batch rejected (Dart short-circuits)
    return submit_op(conn, MONGO_OP_INSERT_MANY, db, coll,
                     docs_bson, docs_total_len, NULL, 0,
                     doc_count, ordered, port_id, timeout_ms);
}

// ─────────────────────────────────────────────────────────────────
// Result + error retrieval (read private conn layout)
// ─────────────────────────────────────────────────────────────────

native_mongo_result_t* native_mongo_poll_result(mongo_conn_t* conn) {
    if (conn == NULL) return NULL;
    native_mongo_result_t* r = conn->last_result;
    conn->last_result = (r != NULL) ? r->next : NULL;  // advance chain
    return r;  // ownership passes to caller (clear_result per node)
}

const char* native_mongo_last_error(mongo_conn_t* conn) {
    if (conn == NULL) return "";
    return conn->last_error;
}

int32_t native_mongo_last_error_code(mongo_conn_t* conn) {
    if (conn == NULL) return 0;
    return conn->last_error_code;
}
