/// sqlite_pool.c — Lifecycle and dispatch for the SQLite native thread/conn
/// pool (thread-per-conn over libsqlite3, WAL). Mirrors `mysql_pool.c`; the
/// core differs only in being embedded (open a file, WAL, no network).

#include "sqlite_pool.h"
#include "native_sqlite.h"
#include "sqlite_pool_internal.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sqlite3.h>

static void deadline_from_ms(struct timespec* ts, int64_t delta_ms) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec  += delta_ms / 1000;
    ts->tv_nsec += (delta_ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) { ts->tv_sec += 1; ts->tv_nsec -= 1000000000L; }
}

static char* dup_string(const char* s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out != NULL) memcpy(out, s, n);
    return out;
}

void sqlite_pool_free_slot_payload(sqlite_conn_t* conn) {
    free(conn->sql);
    conn->sql = NULL;
    conn->is_batch = 0;
    conn->is_multi_read = 0;
    conn->port_id = 0;
    conn->timeout_ms = 0;
}

// Joins `count` statements with ';' into one heap string. NULL on bad args/OOM.
static char* join_stmts(const char* const* stmts, int32_t count) {
    size_t total = 1;
    for (int32_t i = 0; i < count; i++) {
        if (stmts[i] == NULL) return NULL;
        total += strlen(stmts[i]) + 1;
    }
    char* out = (char*)malloc(total);
    if (out == NULL) return NULL;
    char* p = out;
    for (int32_t i = 0; i < count; i++) {
        size_t n = strlen(stmts[i]);
        memcpy(p, stmts[i], n);
        p += n;
        *p++ = ';';
    }
    *p = '\0';
    return out;
}

// Opens one sqlite3* on the pool's file, enables WAL + busy_timeout.
static sqlite3* open_conn(struct sqlite_pool* pool, int index) {
    sqlite3* db = NULL;
    int rc = sqlite3_open_v2(pool->path, &db,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "sqlite_pool_create: open failed (conn %d): %s\n",
                index, db ? sqlite3_errmsg(db) : "unknown");
        if (db) sqlite3_close_v2(db);
        return NULL;
    }
    // WAL enables N concurrent readers + 1 writer on the shared file.
    char* err = NULL;
    if (sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "sqlite_pool_create: WAL pragma failed (conn %d): %s\n",
                index, err ? err : "");
        sqlite3_free(err);
        // Non-fatal: fall back to the default journal mode.
    }
    sqlite3_busy_timeout(db, pool->busy_timeout_ms);
    return db;
}

static int init_conn(sqlite_conn_t* conn, struct sqlite_pool* pool, int32_t index) {
    conn->pool = pool;
    conn->index = index;
    conn->in_use = 0;
    conn->slot_filled = 0;
    conn->is_batch = 0;
    conn->is_multi_read = 0;
    conn->sql = NULL;
    conn->port_id = 0;
    conn->timeout_ms = 0;
    conn->last_result = NULL;
    conn->last_error[0] = '\0';
    conn->last_error_code = 0;
    atomic_init(&conn->shutdown_requested, 0);

    conn->db = open_conn(pool, index);
    if (conn->db == NULL) return -1;

    if (pthread_mutex_init(&conn->slot_mutex, NULL) != 0) {
        sqlite3_close_v2(conn->db); conn->db = NULL; return -1;
    }
    if (pthread_cond_init(&conn->slot_cond, NULL) != 0) {
        pthread_mutex_destroy(&conn->slot_mutex);
        sqlite3_close_v2(conn->db); conn->db = NULL; return -1;
    }
    if (pthread_create(&conn->worker, NULL, sqlite_pool_worker_main, conn) != 0) {
        pthread_cond_destroy(&conn->slot_cond);
        pthread_mutex_destroy(&conn->slot_mutex);
        sqlite3_close_v2(conn->db); conn->db = NULL; return -1;
    }
    return 0;
}

static void teardown_conn(sqlite_conn_t* conn) {
    if (conn->db == NULL) return;
    pthread_join(conn->worker, NULL);
    sqlite_pool_free_slot_payload(conn);
    // Free any undrained result(s). Multi-read leaves a chain; walk it.
    native_sqlite_result_t* r = conn->last_result;
    while (r != NULL) {
        native_sqlite_result_t* next = r->next;
        native_sqlite_clear_result(r);
        r = next;
    }
    conn->last_result = NULL;
    pthread_cond_destroy(&conn->slot_cond);
    pthread_mutex_destroy(&conn->slot_mutex);
    sqlite3_close_v2(conn->db);
    conn->db = NULL;
}

sqlite_pool_t* sqlite_pool_create(const char* path,
                                  int32_t min_size,
                                  int32_t max_size,
                                  int64_t acquire_timeout_ms,
                                  int32_t busy_timeout_ms) {
    (void)min_size;
    if (path == NULL || max_size < 1) {
        fprintf(stderr, "sqlite_pool_create: invalid arguments\n");
        return NULL;
    }

    sqlite_pool_t* pool = (sqlite_pool_t*)calloc(1, sizeof(*pool));
    if (pool == NULL) return NULL;

    pool->path = dup_string(path);
    pool->busy_timeout_ms = (busy_timeout_ms > 0) ? busy_timeout_ms : 5000;
    pool->max_size = max_size;
    pool->default_acquire_timeout_ms = acquire_timeout_ms;
    atomic_init(&pool->shutting_down, 0);

    if (pool->path == NULL ||
        pthread_mutex_init(&pool->mutex, NULL) != 0) {
        free(pool->path); free(pool); return NULL;
    }
    if (pthread_cond_init(&pool->free_cond, NULL) != 0) {
        pthread_mutex_destroy(&pool->mutex);
        free(pool->path); free(pool); return NULL;
    }

    pool->conns = (sqlite_conn_t*)calloc((size_t)max_size, sizeof(*pool->conns));
    if (pool->conns == NULL) {
        pthread_cond_destroy(&pool->free_cond);
        pthread_mutex_destroy(&pool->mutex);
        free(pool->path); free(pool); return NULL;
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
            free(pool->path); free(pool);
            return NULL;
        }
    }
    return pool;
}

void sqlite_pool_destroy(sqlite_pool_t* pool) {
    if (pool == NULL) return;
    atomic_store(&pool->shutting_down, 1);
    for (int32_t i = 0; i < pool->max_size; i++) {
        sqlite_conn_t* c = &pool->conns[i];
        atomic_store(&c->shutdown_requested, 1);
        pthread_mutex_lock(&c->slot_mutex);
        pthread_cond_signal(&c->slot_cond);
        pthread_mutex_unlock(&c->slot_mutex);
    }
    for (int32_t i = 0; i < pool->max_size; i++) teardown_conn(&pool->conns[i]);
    pthread_mutex_lock(&pool->mutex);
    pthread_cond_broadcast(&pool->free_cond);
    pthread_mutex_unlock(&pool->mutex);
    free(pool->conns);
    pthread_cond_destroy(&pool->free_cond);
    pthread_mutex_destroy(&pool->mutex);
    free(pool->path);
    free(pool);
}

sqlite_conn_t* sqlite_pool_acquire(sqlite_pool_t* pool, int64_t timeout_ms) {
    if (pool == NULL || atomic_load(&pool->shutting_down)) return NULL;
    int64_t eff = (timeout_ms == 0) ? pool->default_acquire_timeout_ms : timeout_ms;
    struct timespec deadline;
    int use_deadline = (eff > 0);
    if (use_deadline) deadline_from_ms(&deadline, eff);

    pthread_mutex_lock(&pool->mutex);
    while (1) {
        if (atomic_load(&pool->shutting_down)) {
            pthread_mutex_unlock(&pool->mutex); return NULL;
        }
        for (int32_t i = 0; i < pool->max_size; i++) {
            if (pool->conns[i].in_use == 0) {
                pool->conns[i].in_use = 1;
                pthread_mutex_unlock(&pool->mutex);
                return &pool->conns[i];
            }
        }
        if (eff == 0) { pthread_mutex_unlock(&pool->mutex); return NULL; }
        int rc = use_deadline
            ? pthread_cond_timedwait(&pool->free_cond, &pool->mutex, &deadline)
            : pthread_cond_wait(&pool->free_cond, &pool->mutex);
        if (rc == ETIMEDOUT) { pthread_mutex_unlock(&pool->mutex); return NULL; }
    }
}

void sqlite_pool_release(sqlite_pool_t* pool, sqlite_conn_t* conn) {
    if (pool == NULL || conn == NULL) return;
    pthread_mutex_lock(&pool->mutex);
    conn->in_use = 0;
    pthread_cond_signal(&pool->free_cond);
    pthread_mutex_unlock(&pool->mutex);
}

int sqlite_pool_submit_query(sqlite_conn_t* conn, const char* sql,
                             int64_t port_id, int64_t timeout_ms) {
    if (conn == NULL || sql == NULL) return 0;
    char* sql_copy = dup_string(sql);
    if (sql_copy == NULL) return 0;

    pthread_mutex_lock(&conn->slot_mutex);
    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        free(sql_copy);
        return 0;
    }
    conn->slot_filled = 1;
    conn->sql = sql_copy;
    conn->port_id = port_id;
    conn->timeout_ms = timeout_ms;
    pthread_cond_signal(&conn->slot_cond);
    pthread_mutex_unlock(&conn->slot_mutex);
    return 1;
}

// Dispatches a ';'-joined multi-statement slot (batch or multi-read). Shared
// body of the two MINOR-1 submits.
static int submit_joined(sqlite_conn_t* conn, const char* const* stmts,
                         int32_t count, int is_batch, int is_multi_read,
                         int64_t port_id, int64_t timeout_ms) {
    if (conn == NULL || stmts == NULL || count <= 0) return 0;
    char* joined = join_stmts(stmts, count);
    if (joined == NULL) return 0;

    pthread_mutex_lock(&conn->slot_mutex);
    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        free(joined);
        return 0;
    }
    conn->slot_filled = 1;
    conn->is_batch = is_batch;
    conn->is_multi_read = is_multi_read;
    conn->sql = joined;
    conn->port_id = port_id;
    conn->timeout_ms = timeout_ms;
    pthread_cond_signal(&conn->slot_cond);
    pthread_mutex_unlock(&conn->slot_mutex);
    return 1;
}

int sqlite_pool_submit_batch(sqlite_conn_t* conn, const char* const* stmts,
                             int32_t count, int64_t port_id, int64_t timeout_ms) {
    return submit_joined(conn, stmts, count, 1, 0, port_id, timeout_ms);
}

int sqlite_pool_submit_multi_read(sqlite_conn_t* conn, const char* const* reads,
                                  int32_t count, int64_t port_id, int64_t timeout_ms) {
    return submit_joined(conn, reads, count, 0, 1, port_id, timeout_ms);
}

native_sqlite_result_t* native_sqlite_poll_result(sqlite_conn_t* conn) {
    if (conn == NULL) return NULL;
    native_sqlite_result_t* r = conn->last_result;
    // MINOR 1: advance the chain. Single result → next == NULL → identical to
    // the old behaviour.
    conn->last_result = (r != NULL) ? r->next : NULL;
    return r;
}

// ABI MINOR 2 — synchronous fast-path. Runs the query on the CALLING thread
// while holding slot_mutex, so the worker (which waits on slot_cond under the
// same mutex) cannot touch this conn's sqlite3* concurrently. Refuses (0) if
// an async op is already pending, so the Dart side falls back to the async
// path. Result stored in conn->last_result (drained via poll_result).
int sqlite_conn_exec_sync(sqlite_conn_t* conn, const char* sql) {
    if (conn == NULL || sql == NULL) return 0;
    pthread_mutex_lock(&conn->slot_mutex);
    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        return 0;  // async op pending — caller falls back to async
    }
    conn->last_error[0] = '\0';
    conn->last_error_code = 0;
    int64_t status = sqlite_pool_execute_query(conn, sql);
    pthread_mutex_unlock(&conn->slot_mutex);
    return (int)status;  // 1 ok / 2 aborted
}

const char* native_sqlite_last_error(sqlite_conn_t* conn) {
    return (conn == NULL) ? "" : conn->last_error;
}

int32_t native_sqlite_last_error_code(sqlite_conn_t* conn) {
    return (conn == NULL) ? 0 : conn->last_error_code;
}
