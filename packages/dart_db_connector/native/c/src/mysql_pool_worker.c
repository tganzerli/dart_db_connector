/// mysql_pool_worker.c — Body of the per-conn worker thread for the
/// MySQL pool. One worker is bound to one MYSQL* for the entire pool
/// lifetime and is the ONLY thread that touches it (libmysqlclient
/// requires single-threaded access per connection).
///
/// Unlike the PostgreSQL worker (non-blocking libpq +
/// select/PQconsumeInput/PQisBusy), libmysqlclient is blocking: the
/// worker simply calls `mysql_real_query` + `mysql_store_result`. The
/// thread-per-conn design keeps the Dart event loop free because the
/// blocking call runs on this OS thread, not the isolate. Shutdown and
/// timeout are handled out-of-band via `mysql_pool_cancel` (KILL QUERY),
/// which unblocks an in-flight query so this thread can exit.

#include "mysql_pool.h"
#include "mysql_pool_internal.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mysql.h>

#include "dart/dart_api_dl.h"

// Posted on `port_id` after the worker finishes one slot.
//   1 → caller may drain the result via `native_mysql_poll_result`.
//   2 → dispatch error / query failed / connection error. The conn
//       state is suspect; caller should release and stop using it.
#define WORKER_PORT_OK      ((int64_t)1)
#define WORKER_PORT_ABORTED ((int64_t)2)

// ── Error surfacing (ABI MINOR 3) ──
//
// Clears any stale error before a statement runs; captures the live
// libmysqlclient error onto the conn when a statement aborts, so Dart can
// read it on the abort path (native_mysql_last_errno / _last_error). Both
// use only the conn's fixed buffer — no allocation. Same drain-before-next-
// submit contract as `last_result`: the executor reads the error synchronously
// right after the abort notification, before any further submit on this conn.
static void mysql_clear_conn_error(mysql_conn_t* conn) {
    conn->last_errno = 0;
    conn->last_error[0] = '\0';
}

static void mysql_capture_conn_error(mysql_conn_t* conn) {
    MYSQL* my = conn->my;
    const unsigned int e = mysql_errno(my);
    conn->last_errno = e;
    const char* msg = mysql_error(my);
    if (e == 0 && (msg == NULL || msg[0] == '\0')) {
        // Abort without a libmysqlclient error (e.g. a native allocation
        // failure). Give Dart a non-empty, honest message.
        snprintf(conn->last_error, sizeof(conn->last_error),
                 "query aborted with no MySQL error (native failure)");
    } else {
        snprintf(conn->last_error, sizeof(conn->last_error), "%s",
                 msg ? msg : "");
    }
}

// Runs one query to completion (blocking) and stores the result wrapper
// on the conn. Returns the notification code to post to Dart.
static int64_t execute_single(mysql_conn_t* conn, const char* sql) {
    MYSQL* my = conn->my;

    if (mysql_real_query(my, sql, (unsigned long)strlen(sql)) != 0) {
        // Query failed (syntax, constraint, killed, connection drop…).
        return WORKER_PORT_ABORTED;
    }

    MYSQL_RES* res = mysql_store_result(my);
    if (res == NULL && mysql_errno(my) != 0) {
        // NULL + error ⇒ genuine failure (as opposed to a NULL result
        // for a statement that simply has no row set, e.g. INSERT).
        return WORKER_PORT_ABORTED;
    }

    native_mysql_result_t* wrapped =
        (native_mysql_result_t*)calloc(1, sizeof(*wrapped));
    if (wrapped == NULL) {
        if (res != NULL) mysql_free_result(res);
        return WORKER_PORT_ABORTED;
    }
    wrapped->res = res;
    wrapped->affected_rows =
        (res == NULL) ? (int64_t)mysql_affected_rows(my) : 0;
    wrapped->col_count =
        (res != NULL) ? (int)mysql_num_fields(res) : 0;
    wrapped->cached_row = -1;
    wrapped->row = NULL;
    wrapped->lengths = NULL;

    conn->last_result = wrapped;
    return WORKER_PORT_OK;
}

// Runs a ';'-joined multi-statement batch in ONE round-trip (ABI MINOR 1).
// Drains ALL result sets and aborts on a mid-batch error so the caller
// rolls back the surrounding transaction. Row data is discarded (batch is
// for writes); an empty result wrapper is stored so poll_result is non-NULL.
static int64_t execute_batch(mysql_conn_t* conn, const char* sql) {
    MYSQL* my = conn->my;

    if (mysql_real_query(my, sql, (unsigned long)strlen(sql)) != 0) {
        return WORKER_PORT_ABORTED;
    }

    while (1) {
        MYSQL_RES* r = mysql_store_result(my);
        if (r != NULL) {
            mysql_free_result(r);
        } else if (mysql_errno(my) != 0) {
            return WORKER_PORT_ABORTED;  // error in the current statement
        }
        int next = mysql_next_result(my);  // 0 = more, -1 = done, >0 = error
        if (next > 0) return WORKER_PORT_ABORTED;
        if (next < 0) break;
    }

    native_mysql_result_t* wrapped =
        (native_mysql_result_t*)calloc(1, sizeof(*wrapped));
    if (wrapped == NULL) return WORKER_PORT_ABORTED;
    wrapped->res = NULL;
    wrapped->cached_row = -1;
    conn->last_result = wrapped;
    return WORKER_PORT_OK;
}

// Frees a chain of result wrappers (res + node). Used on the multi-read
// error path, where the partial chain must be released.
static void free_result_chain(native_mysql_result_t* head) {
    while (head != NULL) {
        native_mysql_result_t* next = head->next;
        if (head->res != NULL) mysql_free_result(head->res);
        free(head);
        head = next;
    }
}

// ABI MINOR 2 — multi-read: runs a ';'-joined batch of READS in one
// round-trip and PRESERVES each result set, chained via ->next. The Dart
// side drains the chain via native_mysql_poll_result. Mid-batch error frees
// the partial chain and aborts (the caller rolls back).
static int64_t execute_multi_read(mysql_conn_t* conn, const char* sql) {
    MYSQL* my = conn->my;

    if (mysql_real_query(my, sql, (unsigned long)strlen(sql)) != 0) {
        return WORKER_PORT_ABORTED;
    }

    native_mysql_result_t* head = NULL;
    native_mysql_result_t* tail = NULL;
    while (1) {
        MYSQL_RES* res = mysql_store_result(my);
        if (res == NULL && mysql_errno(my) != 0) {
            free_result_chain(head);
            return WORKER_PORT_ABORTED;
        }
        native_mysql_result_t* w =
            (native_mysql_result_t*)calloc(1, sizeof(*w));
        if (w == NULL) {
            if (res != NULL) mysql_free_result(res);
            free_result_chain(head);
            return WORKER_PORT_ABORTED;
        }
        w->res = res;
        w->col_count = (res != NULL) ? (int)mysql_num_fields(res) : 0;
        w->cached_row = -1;
        w->next = NULL;
        if (head == NULL) {
            head = tail = w;
        } else {
            tail->next = w;
            tail = w;
        }

        int nx = mysql_next_result(my);  // 0 = more, -1 = done, >0 = error
        if (nx > 0) {
            free_result_chain(head);
            return WORKER_PORT_ABORTED;
        }
        if (nx < 0) break;
    }

    conn->last_result = head;  // Dart drains the chain via poll_result
    return WORKER_PORT_OK;
}

void* mysql_pool_worker_main(void* arg) {
    mysql_conn_t* conn = (mysql_conn_t*)arg;

    // Each thread using libmysqlclient must init/teardown thread-local
    // state around its lifetime.
    mysql_thread_init();

    while (1) {
        // ── 1. Wait for work or shutdown ──
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

        // Snapshot slot fields. Keep slot_filled=1 so concurrent submits
        // see "occupied" until we finish posting + clear.
        int64_t port_id = conn->port_id;
        char* sql = conn->sql;
        int is_batch = conn->is_batch;
        int is_multi_read = conn->is_multi_read;
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 2. Execute (blocking) ──
        mysql_clear_conn_error(conn);  // drop any stale error first
        int64_t status = is_multi_read ? execute_multi_read(conn, sql)
                       : is_batch       ? execute_batch(conn, sql)
                                        : execute_single(conn, sql);
        // On abort, snapshot the real libmysqlclient error while `my` still
        // holds it (before the slot is cleared / any re-submit).
        if (status == WORKER_PORT_ABORTED) {
            mysql_capture_conn_error(conn);
        }

        // ── 3. Clear slot FIRST — must precede the Dart-side post, for
        //       the same race reason documented in native_pool_worker.c:
        //       a fast isolate could drain + re-submit on this conn
        //       before we clear the slot, spuriously seeing "occupied".
        pthread_mutex_lock(&conn->slot_mutex);
        mysql_pool_free_slot_payload(conn);
        conn->slot_filled = 0;
        pthread_cond_signal(&conn->slot_cond);
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 4. Notify Dart ──
        Dart_CObject msg;
        msg.type = Dart_CObject_kInt64;
        msg.value.as_int64 = status;
        Dart_PostCObject_DL((Dart_Port)port_id, &msg);
    }

    mysql_thread_end();
    return NULL;
}
