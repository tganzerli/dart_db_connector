/// mysql_pool.c — Lifecycle and dispatch primitives for the MySQL
/// native thread/conn pool (thread-per-conn). Mirrors `native_pool.c`
/// (PostgreSQL) over libmysqlclient. See the extensibility blueprint in
/// the layered architecture in the package README.

#include "mysql_pool.h"
#include "native_mysql.h"
#include "mysql_pool_internal.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mysql.h>

// ─────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────

// libmysqlclient must be initialised once per process before any thread
// touches it. `mysql_init(NULL)` would do it lazily but is not
// thread-safe on first call, so we force it here under pthread_once.
static pthread_once_t g_mysql_lib_once = PTHREAD_ONCE_INIT;
static void init_mysql_library(void) {
    mysql_library_init(0, NULL, NULL);
}

// Builds an absolute CLOCK_REALTIME deadline `now + delta_ms`.
static void deadline_from_ms(struct timespec* ts, int64_t delta_ms) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec  += delta_ms / 1000;
    ts->tv_nsec += (delta_ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_sec  += 1;
        ts->tv_nsec -= 1000000000L;
    }
}

// Heap-duplicates a C string. Returns NULL if `s` is NULL or on OOM.
static char* dup_string(const char* s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out == NULL) return NULL;
    memcpy(out, s, n);
    return out;
}

// Frees the slot payload (sql string). Safe on NULL. Exposed via
// mysql_pool_internal.h so the worker can release after dispatching.
void mysql_pool_free_slot_payload(mysql_conn_t* conn) {
    free(conn->sql);
    conn->sql = NULL;
    conn->is_batch = 0;
    conn->is_multi_read = 0;
    conn->port_id = 0;
    conn->timeout_ms = 0;
}

// Opens a MYSQL* against the pool credentials. Returns NULL on failure
// (error printed to stderr). Sets utf8mb4 and disables auto-reconnect
// (a silent reconnect would resurrect a conn we intend to treat as
// suspect after an abort).
static MYSQL* open_conn(struct mysql_pool* pool, int index) {
    MYSQL* my = mysql_init(NULL);
    if (my == NULL) {
        fprintf(stderr, "mysql_pool_create: mysql_init failed (conn %d)\n", index);
        return NULL;
    }
    // MySQL 8.0+ defaults auto-reconnect to OFF (a silent reconnect
    // would resurrect a conn we intend to treat as suspect after an
    // abort), so no MYSQL_OPT_RECONNECT is needed; `my_bool` is also
    // gone from the 8.0+/9.x client headers.
    // v1 is plaintext (no TLS). Oracle's libmysqlclient can negotiate TLS
    // against the server's auto self-signed cert; force SSL off there.
    // MariaDB Connector/C connects plaintext by default and lacks
    // MYSQL_OPT_SSL_MODE / SSL_MODE_DISABLED, so skip on that client.
#ifndef MARIADB_BASE_VERSION
    enum mysql_ssl_mode ssl_disabled = SSL_MODE_DISABLED;
    mysql_options(my, MYSQL_OPT_SSL_MODE, &ssl_disabled);
#endif
    mysql_options(my, MYSQL_SET_CHARSET_NAME, "utf8mb4");

    // CLIENT_MULTI_STATEMENTS is required so `mysql_pool_submit_batch` can
    // send a ';'-joined batch in one round-trip (ABI MINOR 1). Single-query
    // (`mysql_pool_submit_query`) is unaffected — one statement yields one
    // result and the batch drain never runs on that path.
    if (mysql_real_connect(my, pool->host, pool->user, pool->password,
                           pool->db, pool->port, NULL,
                           CLIENT_MULTI_STATEMENTS) == NULL) {
        fprintf(stderr, "mysql_pool_create: connect failed (conn %d): %s\n",
                index, mysql_error(my));
        mysql_close(my);
        return NULL;
    }
    return my;
}

// Initializes a single mysql_conn_t: opens the MYSQL*, sets up
// mutex/condvar, starts the worker. Returns 0 on success, -1 on failure
// (partial state cleaned up before return).
static int init_conn(mysql_conn_t* conn, struct mysql_pool* pool, int32_t index) {
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
    atomic_init(&conn->shutdown_requested, 0);

    conn->my = open_conn(pool, index);
    if (conn->my == NULL) return -1;
    conn->thread_id = mysql_thread_id(conn->my);

    if (pthread_mutex_init(&conn->slot_mutex, NULL) != 0) {
        mysql_close(conn->my);
        conn->my = NULL;
        return -1;
    }
    if (pthread_cond_init(&conn->slot_cond, NULL) != 0) {
        pthread_mutex_destroy(&conn->slot_mutex);
        mysql_close(conn->my);
        conn->my = NULL;
        return -1;
    }
    if (pthread_create(&conn->worker, NULL, mysql_pool_worker_main, conn) != 0) {
        pthread_cond_destroy(&conn->slot_cond);
        pthread_mutex_destroy(&conn->slot_mutex);
        mysql_close(conn->my);
        conn->my = NULL;
        return -1;
    }
    return 0;
}

// Joins the worker and frees per-conn resources. The caller must have
// set conn->shutdown_requested = 1 and signaled slot_cond.
static void teardown_conn(mysql_conn_t* conn) {
    if (conn->my == NULL) return;  // never initialised
    pthread_join(conn->worker, NULL);
    mysql_pool_free_slot_payload(conn);
    // Free any undrained result(s). Multi-read leaves a chain; walk it.
    native_mysql_result_t* r = conn->last_result;
    while (r != NULL) {
        native_mysql_result_t* next = r->next;
        native_mysql_clear_result(r);
        r = next;
    }
    conn->last_result = NULL;
    pthread_cond_destroy(&conn->slot_cond);
    pthread_mutex_destroy(&conn->slot_mutex);
    mysql_close(conn->my);
    conn->my = NULL;
}

// ─────────────────────────────────────────────────────────────────
// Public API — pool lifecycle
// ─────────────────────────────────────────────────────────────────

mysql_pool_t* mysql_pool_create(const char* host,
                                const char* user,
                                const char* password,
                                const char* db,
                                uint16_t port,
                                int32_t min_size,
                                int32_t max_size,
                                int64_t acquire_timeout_ms) {
    (void)min_size;  // reserved for future warm-up policy

    if (max_size < 1) {
        fprintf(stderr, "mysql_pool_create: invalid arguments\n");
        return NULL;
    }

    pthread_once(&g_mysql_lib_once, init_mysql_library);

    mysql_pool_t* pool = (mysql_pool_t*)calloc(1, sizeof(*pool));
    if (pool == NULL) return NULL;

    pool->host     = dup_string(host);
    pool->user     = dup_string(user);
    pool->password = dup_string(password);
    pool->db       = dup_string(db);   // NULL db is valid (no schema)
    pool->port     = port;
    pool->max_size = max_size;
    pool->default_acquire_timeout_ms = acquire_timeout_ms;
    atomic_init(&pool->shutting_down, 0);

    // Any of host/user/password may legitimately be NULL (unix socket /
    // no password); only fail the dup that had a non-NULL source.
    int dup_failed = (host != NULL && pool->host == NULL)
                  || (user != NULL && pool->user == NULL)
                  || (password != NULL && pool->password == NULL)
                  || (db != NULL && pool->db == NULL);
    if (dup_failed || pthread_mutex_init(&pool->mutex, NULL) != 0) {
        free(pool->host); free(pool->user); free(pool->password); free(pool->db);
        free(pool);
        return NULL;
    }
    if (pthread_cond_init(&pool->free_cond, NULL) != 0) {
        pthread_mutex_destroy(&pool->mutex);
        free(pool->host); free(pool->user); free(pool->password); free(pool->db);
        free(pool);
        return NULL;
    }

    pool->conns = (mysql_conn_t*)calloc((size_t)max_size, sizeof(*pool->conns));
    if (pool->conns == NULL) {
        pthread_cond_destroy(&pool->free_cond);
        pthread_mutex_destroy(&pool->mutex);
        free(pool->host); free(pool->user); free(pool->password); free(pool->db);
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
            free(pool->host); free(pool->user); free(pool->password); free(pool->db);
            free(pool);
            return NULL;
        }
    }

    return pool;
}

void mysql_pool_destroy(mysql_pool_t* pool) {
    if (pool == NULL) return;

    atomic_store(&pool->shutting_down, 1);

    // Signal every worker and cancel any in-flight query so a worker
    // blocked in mysql_real_query returns promptly.
    for (int32_t i = 0; i < pool->max_size; i++) {
        mysql_conn_t* c = &pool->conns[i];
        atomic_store(&c->shutdown_requested, 1);
        mysql_pool_cancel(c);
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
    free(pool->host); free(pool->user); free(pool->password); free(pool->db);
    free(pool);
}

// ─────────────────────────────────────────────────────────────────
// Public API — acquire / release
// ─────────────────────────────────────────────────────────────────

mysql_conn_t* mysql_pool_acquire(mysql_pool_t* pool, int64_t timeout_ms) {
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

        int rc;
        if (use_deadline) {
            rc = pthread_cond_timedwait(&pool->free_cond, &pool->mutex, &deadline);
        } else {
            rc = pthread_cond_wait(&pool->free_cond, &pool->mutex);
        }
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;
        }
    }
}

void mysql_pool_release(mysql_pool_t* pool, mysql_conn_t* conn) {
    if (pool == NULL || conn == NULL) return;

    pthread_mutex_lock(&pool->mutex);
    conn->in_use = 0;
    pthread_cond_signal(&pool->free_cond);
    pthread_mutex_unlock(&pool->mutex);
}

// ─────────────────────────────────────────────────────────────────
// Public API — submit
// ─────────────────────────────────────────────────────────────────

int mysql_pool_submit_query(mysql_conn_t* conn,
                            const char* sql,
                            int64_t port_id,
                            int64_t timeout_ms) {
    if (conn == NULL || sql == NULL) return 0;

    pthread_mutex_lock(&conn->slot_mutex);

    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        return 0;
    }

    char* sql_copy = dup_string(sql);
    if (sql_copy == NULL) {
        pthread_mutex_unlock(&conn->slot_mutex);
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

// Joins `count` statements with ';' separators into one heap string.
// Returns NULL on bad args or OOM.
static char* join_stmts(const char* const* stmts, int32_t count) {
    size_t total = 1;  // trailing NUL
    for (int32_t i = 0; i < count; i++) {
        if (stmts[i] == NULL) return NULL;
        total += strlen(stmts[i]) + 1;  // statement + separator
    }
    char* out = (char*)malloc(total);
    if (out == NULL) return NULL;
    char* p = out;
    for (int32_t i = 0; i < count; i++) {
        size_t n = strlen(stmts[i]);
        memcpy(p, stmts[i], n);
        p += n;
        if (i + 1 < count) *p++ = ';';
    }
    *p = '\0';
    return out;
}

// ABI MINOR 1 — multi-statement batch (MySQL analog of the libpq pipeline).
int mysql_pool_submit_batch(mysql_conn_t* conn,
                            const char* const* stmts,
                            int32_t count,
                            int64_t port_id,
                            int64_t timeout_ms) {
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
    conn->is_batch = 1;
    conn->sql = joined;
    conn->port_id = port_id;
    conn->timeout_ms = timeout_ms;

    pthread_cond_signal(&conn->slot_cond);
    pthread_mutex_unlock(&conn->slot_mutex);
    return 1;
}

// ABI MINOR 2 — multi-read (N reads in one round-trip, N result sets preserved).
int mysql_pool_submit_multi_read(mysql_conn_t* conn,
                                 const char* const* reads,
                                 int32_t count,
                                 int64_t port_id,
                                 int64_t timeout_ms) {
    if (conn == NULL || reads == NULL || count <= 0) return 0;

    char* joined = join_stmts(reads, count);
    if (joined == NULL) return 0;

    pthread_mutex_lock(&conn->slot_mutex);
    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        free(joined);
        return 0;
    }

    conn->slot_filled = 1;
    conn->is_multi_read = 1;
    conn->sql = joined;
    conn->port_id = port_id;
    conn->timeout_ms = timeout_ms;

    pthread_cond_signal(&conn->slot_cond);
    pthread_mutex_unlock(&conn->slot_mutex);
    return 1;
}

// ─────────────────────────────────────────────────────────────────
// Public API — cancel + result retrieval
// ─────────────────────────────────────────────────────────────────

// Opens a side connection and issues KILL QUERY. libmysqlclient has no
// thread-safe in-connection cancel, so this is the standard idiom.
void mysql_pool_kill_query(struct mysql_pool* pool, unsigned long thread_id) {
    MYSQL* killer = mysql_init(NULL);
    if (killer == NULL) return;
#ifndef MARIADB_BASE_VERSION
    enum mysql_ssl_mode ssl_disabled = SSL_MODE_DISABLED;
    mysql_options(killer, MYSQL_OPT_SSL_MODE, &ssl_disabled);
#endif
    if (mysql_real_connect(killer, pool->host, pool->user, pool->password,
                           pool->db, pool->port, NULL, 0) != NULL) {
        char stmt[64];
        snprintf(stmt, sizeof(stmt), "KILL QUERY %lu", thread_id);
        mysql_query(killer, stmt);  // best-effort; ignore result
    }
    mysql_close(killer);
}

void mysql_pool_cancel(mysql_conn_t* conn) {
    if (conn == NULL || conn->pool == NULL) return;
    mysql_pool_kill_query(conn->pool, conn->thread_id);
}

// Declared in native_mysql.h; defined here because it reads the private
// conn layout. Ownership of the returned handle passes to the caller.
native_mysql_result_t* native_mysql_poll_result(mysql_conn_t* conn) {
    if (conn == NULL) return NULL;
    native_mysql_result_t* r = conn->last_result;
    // ABI MINOR 2: advance the result chain. For a single result the chain
    // is length 1 (next == NULL), so this is identical to the old behaviour.
    conn->last_result = (r != NULL) ? r->next : NULL;
    return r;   // ownership passes to the caller (clear_result per node)
}
