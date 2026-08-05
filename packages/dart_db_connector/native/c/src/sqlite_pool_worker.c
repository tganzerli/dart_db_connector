/// sqlite_pool_worker.c — Body of the per-conn worker thread for the SQLite
/// pool. One worker owns one `sqlite3*` for the pool lifetime and is the
/// ONLY thread to touch it.
///
/// SQLite is synchronous and its `sqlite3_stmt` is a forward-only cursor, so
/// the worker prepares → steps → MATERIALISES every row (copying each cell,
/// because `sqlite3_column_*` pointers die on the next step) → notifies Dart
/// via `Dart_PostCObject_DL`. The thread-per-conn design offloads the
/// blocking `sqlite3_step` from the isolate.

#include "sqlite_pool.h"
#include "sqlite_pool_internal.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

#include "dart/dart_api_dl.h"

#define WORKER_PORT_OK      ((int64_t)1)
#define WORKER_PORT_ABORTED ((int64_t)2)

static void set_error(sqlite_conn_t* conn, sqlite3* db) {
    snprintf(conn->last_error, SQLITE_ERR_BUF, "%s", sqlite3_errmsg(db));
    conn->last_error_code = sqlite3_extended_errcode(db);
}

// Copies `len` bytes into a fresh buffer (NULL on OOM / len 0 handled by caller).
static uint8_t* dup_cell(const void* src, int32_t len) {
    uint8_t* out = (uint8_t*)malloc((size_t)len);
    if (out != NULL) memcpy(out, src, (size_t)len);
    return out;
}

// Frees the parallel cell arrays for `count` populated cells.
static void free_cells(int* types, int32_t* lens, uint8_t** data, int64_t count) {
    if (data != NULL) {
        for (int64_t i = 0; i < count; i++) free(data[i]);
    }
    free(types);
    free(lens);
    free(data);
}

// Prepares, steps, and materialises one SQL statement. Returns the port code.
// Steps a prepared stmt to completion and materialises its rows into a
// result wrapper (copying each cell, since the cursor is forward-only).
// FINALISES `stmt` in all paths. Returns the wrapper, or NULL on error (with
// set_error already done). Shared by the single, sync and multi-read paths.
static native_sqlite_result_t* materialize_stmt(sqlite_conn_t* conn,
                                                sqlite3_stmt* stmt) {
    sqlite3* db = conn->db;
    int ncol = sqlite3_column_count(stmt);

    int64_t nrows = 0, cap = 0;
    int* types = NULL;
    int32_t* lens = NULL;
    uint8_t** data = NULL;

    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        if (nrows == cap) {
            int64_t newcap = (cap == 0) ? 8 : cap * 2;
            size_t n = (size_t)newcap * (size_t)ncol;
            int* t2 = (int*)realloc(types, n * sizeof(int));
            int32_t* l2 = (int32_t*)realloc(lens, n * sizeof(int32_t));
            uint8_t** d2 = (uint8_t**)realloc(data, n * sizeof(uint8_t*));
            if ((ncol > 0 && (t2 == NULL || l2 == NULL || d2 == NULL))) {
                if (t2) types = t2;
                if (l2) lens = l2;
                if (d2) data = d2;
                free_cells(types, lens, data, nrows * ncol);
                sqlite3_finalize(stmt);
                snprintf(conn->last_error, SQLITE_ERR_BUF, "out of memory");
                conn->last_error_code = SQLITE_NOMEM;
                return NULL;
            }
            types = t2; lens = l2; data = d2;
            cap = newcap;
        }
        for (int c = 0; c < ncol; c++) {
            int64_t idx = nrows * ncol + c;
            int ty = sqlite3_column_type(stmt, c);
            types[idx] = ty;
            if (ty == SQLITE_NULL) {
                data[idx] = NULL;
                lens[idx] = 0;
            } else if (ty == SQLITE_INTEGER) {
                int64_t v = sqlite3_column_int64(stmt, c);
                data[idx] = dup_cell(&v, 8);
                lens[idx] = 8;
            } else if (ty == SQLITE_FLOAT) {
                double v = sqlite3_column_double(stmt, c);
                data[idx] = dup_cell(&v, 8);
                lens[idx] = 8;
            } else { // SQLITE_TEXT or SQLITE_BLOB
                const void* b = sqlite3_column_blob(stmt, c);
                int n = sqlite3_column_bytes(stmt, c);
                data[idx] = (n > 0) ? dup_cell(b, n) : dup_cell("", 0);
                lens[idx] = n;
            }
        }
        nrows++;
    }

    if (rc != SQLITE_DONE) {
        set_error(conn, db);
        free_cells(types, lens, data, nrows * ncol);
        sqlite3_finalize(stmt);
        return NULL;
    }

    char** names = NULL;
    if (ncol > 0) {
        names = (char**)calloc((size_t)ncol, sizeof(char*));
        for (int c = 0; c < ncol; c++) {
            const char* nm = sqlite3_column_name(stmt, c);
            names[c] = (nm != NULL) ? strdup(nm) : strdup("");
        }
    }
    int64_t affected = (int64_t)sqlite3_changes(db);
    sqlite3_finalize(stmt);

    native_sqlite_result_t* res =
        (native_sqlite_result_t*)calloc(1, sizeof(*res));
    if (res == NULL) {
        free_cells(types, lens, data, nrows * ncol);
        if (names) { for (int c = 0; c < ncol; c++) free(names[c]); free(names); }
        snprintf(conn->last_error, SQLITE_ERR_BUF, "out of memory");
        conn->last_error_code = SQLITE_NOMEM;
        return NULL;
    }
    res->col_count = ncol;
    res->row_count = nrows;
    res->affected_rows = affected;
    res->col_names = names;
    res->cell_types = types;
    res->cell_lens = lens;
    res->cell_data = data;
    return res;
}

// Frees a chain of result wrappers (used on the multi-read error path).
static void free_result_chain(native_sqlite_result_t* head) {
    while (head != NULL) {
        native_sqlite_result_t* next = head->next;
        native_sqlite_clear_result(head);
        head = next;
    }
}

// Single statement (async default + sync fast-path share this). Exposed via
// internal.h so sqlite_conn_exec_sync (pool.c) reuses it on the caller thread.
int64_t sqlite_pool_execute_query(sqlite_conn_t* conn, const char* sql) {
    sqlite3_stmt* stmt = NULL;
    if (sqlite3_prepare_v2(conn->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        set_error(conn, conn->db);
        return WORKER_PORT_ABORTED;
    }
    native_sqlite_result_t* res = materialize_stmt(conn, stmt);
    if (res == NULL) return WORKER_PORT_ABORTED;
    conn->last_result = res;
    return WORKER_PORT_OK;
}

// ABI MINOR 1 — batch of WRITES in one round-trip (';'-joined). Runs every
// statement via sqlite3_exec, discarding rows; mid-batch error → ABORTED.
static int64_t execute_batch(sqlite_conn_t* conn, const char* sql) {
    char* err = NULL;
    if (sqlite3_exec(conn->db, sql, NULL, NULL, &err) != SQLITE_OK) {
        snprintf(conn->last_error, SQLITE_ERR_BUF, "%s", err ? err : "batch failed");
        conn->last_error_code = sqlite3_extended_errcode(conn->db);
        sqlite3_free(err);
        return WORKER_PORT_ABORTED;
    }
    // Empty result so poll_result is non-NULL (mirrors the MySQL batch path).
    native_sqlite_result_t* res =
        (native_sqlite_result_t*)calloc(1, sizeof(*res));
    if (res == NULL) return WORKER_PORT_ABORTED;
    conn->last_result = res;
    return WORKER_PORT_OK;
}

// ABI MINOR 1 — multi-read: N SELECTs in one round-trip, PRESERVING the N
// result sets (chained via ->next). Iterates statements via prepare's pzTail.
static int64_t execute_multi_read(sqlite_conn_t* conn, const char* sql) {
    native_sqlite_result_t* head = NULL;
    native_sqlite_result_t* tail = NULL;
    const char* cursor = sql;
    while (cursor != NULL && *cursor != '\0') {
        // Skip leading whitespace/separators so a trailing ';' isn't a stmt.
        while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n' ||
               *cursor == '\r' || *cursor == ';') cursor++;
        if (*cursor == '\0') break;
        sqlite3_stmt* stmt = NULL;
        const char* next = NULL;
        if (sqlite3_prepare_v2(conn->db, cursor, -1, &stmt, &next) != SQLITE_OK) {
            set_error(conn, conn->db);
            free_result_chain(head);
            return WORKER_PORT_ABORTED;
        }
        if (stmt == NULL) { cursor = next; continue; } // empty tail
        native_sqlite_result_t* w = materialize_stmt(conn, stmt);
        if (w == NULL) { free_result_chain(head); return WORKER_PORT_ABORTED; }
        if (head == NULL) head = tail = w;
        else { tail->next = w; tail = w; }
        cursor = next;
    }
    conn->last_result = head;  // Dart drains the chain via poll_result
    return WORKER_PORT_OK;
}

void* sqlite_pool_worker_main(void* arg) {
    sqlite_conn_t* conn = (sqlite_conn_t*)arg;

    while (1) {
        pthread_mutex_lock(&conn->slot_mutex);
        while (!conn->slot_filled &&
               !atomic_load(&conn->shutdown_requested)) {
            pthread_cond_wait(&conn->slot_cond, &conn->slot_mutex);
        }
        if (!conn->slot_filled &&
            atomic_load(&conn->shutdown_requested)) {
            pthread_mutex_unlock(&conn->slot_mutex);
            break;
        }
        int64_t port_id = conn->port_id;
        char* sql = conn->sql;
        int is_batch = conn->is_batch;
        int is_multi_read = conn->is_multi_read;
        pthread_mutex_unlock(&conn->slot_mutex);

        conn->last_error[0] = '\0';
        conn->last_error_code = 0;
        int64_t status = is_multi_read ? execute_multi_read(conn, sql)
                       : is_batch       ? execute_batch(conn, sql)
                                        : sqlite_pool_execute_query(conn, sql);

        pthread_mutex_lock(&conn->slot_mutex);
        sqlite_pool_free_slot_payload(conn);
        conn->slot_filled = 0;
        pthread_cond_signal(&conn->slot_cond);
        pthread_mutex_unlock(&conn->slot_mutex);

        Dart_CObject msg;
        msg.type = Dart_CObject_kInt64;
        msg.value.as_int64 = status;
        Dart_PostCObject_DL((Dart_Port)port_id, &msg);
    }
    return NULL;
}
