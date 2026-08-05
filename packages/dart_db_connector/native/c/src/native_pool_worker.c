/// native_pool_worker.c — Body of the per-conn worker thread for
/// approach B. One worker is bound to one PGconn for the entire
/// lifetime of the pool. The worker is the ONLY thread that touches
/// `conn->pg` in libpq (satisfies libpq §32.21 thread-safety).
///
/// Reuses the `select() + PQconsumeInput + PQisBusy` pattern from
/// the deprecated `socket_watcher_thread` (now removed in MAJOR 2)
/// but with N=1 socket per worker — eliminates the O(n) fan-out
/// that motivated the refactor.

#include "native_pool.h"
#include "native_pool_internal.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>
#include <libpq-fe.h>

#include "dart/dart_api_dl.h"

// Posted on `port_id` after the worker finishes one slot.
//
//   1 → caller may drain results via `poll_result`.
//   2 → dispatch error or timeout fired (PQcancel was issued).
//       The connection state is undefined; caller should release
//       this `native_conn_t*` and either reconnect or stop using it.
#define WORKER_PORT_OK      ((int64_t)1)
#define WORKER_PORT_ABORTED ((int64_t)2)

// Lower bound for the per-iteration `select()` so that the worker
// observes `shutdown_requested` even on queries dispatched with no
// wall-clock deadline (`timeout_ms == 0`). 1s ≈ a worst-case shutdown
// latency that keeps tests snappy while staying invisible at runtime.
#define WORKER_SHUTDOWN_POLL_MS ((int64_t)1000)

// ─────────────────────────────────────────────────────────────────
// Time helpers
// ─────────────────────────────────────────────────────────────────

static void compute_deadline(struct timespec* out, int64_t timeout_ms) {
    clock_gettime(CLOCK_REALTIME, out);
    out->tv_sec  += timeout_ms / 1000;
    out->tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (out->tv_nsec >= 1000000000L) {
        out->tv_sec  += 1;
        out->tv_nsec -= 1000000000L;
    }
}

// Returns the number of milliseconds remaining until `deadline`.
// May be negative (deadline already passed).
static int64_t ms_until(const struct timespec* deadline) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    int64_t s_diff  = (int64_t)(deadline->tv_sec - now.tv_sec);
    int64_t ns_diff = (int64_t)(deadline->tv_nsec - now.tv_nsec);
    return s_diff * 1000 + ns_diff / 1000000;
}

// Fills `tv` with the next select() timeout. If `has_deadline` is 0
// the timeout is WORKER_SHUTDOWN_POLL_MS so the worker still wakes
// up to check `shutdown_requested`. Returns 0 if the deadline has
// already expired (caller should treat as timeout).
static int next_select_tv(struct timeval* tv,
                          int has_deadline,
                          const struct timespec* deadline) {
    int64_t budget_ms;
    if (has_deadline) {
        budget_ms = ms_until(deadline);
        if (budget_ms <= 0) return 0;
        if (budget_ms > WORKER_SHUTDOWN_POLL_MS) {
            budget_ms = WORKER_SHUTDOWN_POLL_MS;
        }
    } else {
        budget_ms = WORKER_SHUTDOWN_POLL_MS;
    }
    tv->tv_sec  = (long)(budget_ms / 1000);
    tv->tv_usec = (long)((budget_ms % 1000) * 1000);
    return 1;
}

// Best-effort PQcancel via libpq's thread-safe interface.
static void issue_cancel(PGconn* pg) {
    PGcancel* cancel = PQgetCancel(pg);
    if (cancel != NULL) {
        char errbuf[256];
        PQcancel(cancel, errbuf, sizeof(errbuf));
        PQfreeCancel(cancel);
    }
}

// ─────────────────────────────────────────────────────────────────
// Outgoing-buffer flush
// ─────────────────────────────────────────────────────────────────
//
// Drains the non-blocking conn's send buffer the libpq way. On
// PQflush()==1 the buffer is not yet empty; instead of spinning we
// wait (select) for the socket to become writable. We also watch for
// read-readiness: the server may be sending (e.g. a NOTICE) and libpq
// §"Asynchronous Command Processing" tells us to PQconsumeInput first,
// otherwise the write side can wedge when the peer's buffers fill.
//
// The wait honors the same query deadline and shutdown discipline as
// the result-drain loops below, reusing next_select_tv()/issue_cancel().
// Returns WORKER_PORT_OK once the buffer is fully sent, or
// WORKER_PORT_ABORTED on timeout / shutdown / socket error. For
// timeout and shutdown issue_cancel() has already fired; any
// path-specific cleanup (result chain, pipeline mode) is the caller's
// responsibility.
static int64_t flush_outgoing(native_conn_t* conn,
                              PGconn* pg,
                              int sock,
                              int has_deadline,
                              const struct timespec* deadline) {
    while (1) {
        int f = PQflush(pg);
        if (f == 0) return WORKER_PORT_OK;       // fully sent
        if (f < 0)  return WORKER_PORT_ABORTED;  // write error

        // f == 1: buffer not yet drained — wait, don't spin.
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        fd_set rfds, wfds;
        FD_ZERO(&rfds); FD_SET(sock, &rfds);
        FD_ZERO(&wfds); FD_SET(sock, &wfds);

        struct timeval tv;
        if (!next_select_tv(&tv, has_deadline, deadline)) {
            // Wall-clock deadline expired while sending.
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        int rc = select(sock + 1, &rfds, &wfds, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return WORKER_PORT_ABORTED;
        }
        if (rc == 0) {
            // Shutdown-poll tick or deadline — re-check both at top.
            continue;
        }
        if (FD_ISSET(sock, &rfds)) {
            // Consume server-side bytes so the peer keeps draining our
            // writes; also keeps libpq's input buffer coherent.
            if (PQconsumeInput(pg) == 0) return WORKER_PORT_ABORTED;
        }
        // Writable (or just consumed) — loop and re-try PQflush.
    }
}

// ─────────────────────────────────────────────────────────────────
// Single-query execution path
// ─────────────────────────────────────────────────────────────────

static int64_t execute_single(native_conn_t* conn,
                              const char* sql,
                              int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    if (PQsendQuery(pg, sql) != 1) {
        // libpq did not accept the dispatch (bad state, malformed
        // SQL at the protocol layer, etc.). Surface as ABORTED so
        // the Dart side closes + reopens.
        return WORKER_PORT_ABORTED;
    }

    // Deadline is computed BEFORE the flush so a blocked send counts
    // against the query timeout (see flush_outgoing).
    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Non-blocking conn: drain the send buffer without spinning.
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        return WORKER_PORT_ABORTED;
    }

    while (1) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(sock, &rfds);

        struct timeval tv;
        if (!next_select_tv(&tv, has_deadline, &deadline)) {
            // Wall-clock deadline expired.
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR) continue;
            // Hard select() error — bail.
            return WORKER_PORT_ABORTED;
        }
        if (rc == 0) {
            // Shutdown-poll wake-up OR deadline expired.
            // Loop will re-check both flags at the top.
            continue;
        }
        if (PQconsumeInput(pg) == 0) {
            return WORKER_PORT_ABORTED;
        }
        if (!PQisBusy(pg)) {
            // Result is sitting in libpq's queue; Dart will drain
            // via `poll_result` after the int64=1 notification.
            return WORKER_PORT_OK;
        }
        // Partial frame — keep iterating.
    }
}

// ─────────────────────────────────────────────────────────────────
// Pipeline execution path
// ─────────────────────────────────────────────────────────────────
//
// v1 contract: the worker drains ALL `query_count + 1` PGresults
// (the +1 is the sync sentinel) and discards them via `PQclear`.
// The Dart side receives a single int64=1 acknowledgement. Row
// data is not surfaced — same limitation as the legacy
// `start_pipeline_async` in MAJOR 1. Useful for batched DML
// where command tags are the only relevant output.

static int64_t execute_pipeline(native_conn_t* conn,
                                char** queries,
                                int32_t query_count,
                                int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    if (PQenterPipelineMode(pg) == 0) return WORKER_PORT_ABORTED;

    for (int32_t i = 0; i < query_count; i++) {
        // Pipeline mode requires the extended protocol —
        // PQsendQueryParams with 0 params behaves like a
        // parameterless query under the extended protocol.
        if (PQsendQueryParams(pg, queries[i],
                              0,        // nParams
                              NULL,     // paramTypes
                              NULL,     // paramValues
                              NULL,     // paramLengths
                              NULL,     // paramFormats
                              0         // resultFormat (text)
                              ) != 1) {
            PQexitPipelineMode(pg);
            return WORKER_PORT_ABORTED;
        }
    }

    if (PQpipelineSync(pg) == 0) {
        PQexitPipelineMode(pg);
        return WORKER_PORT_ABORTED;
    }

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Spin-free flush; exit pipeline mode on abort like the paths above.
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        PQexitPipelineMode(pg);
        return WORKER_PORT_ABORTED;
    }

    int32_t remaining = query_count + 1;  // queries + sync sentinel
    int64_t status = WORKER_PORT_OK;

    while (remaining > 0) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            status = WORKER_PORT_ABORTED;
            break;
        }

        if (PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);

            struct timeval tv;
            if (!next_select_tv(&tv, has_deadline, &deadline)) {
                issue_cancel(pg);
                status = WORKER_PORT_ABORTED;
                break;
            }

            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                status = WORKER_PORT_ABORTED;
                break;
            }
            if (rc == 0) {
                // Shutdown-poll wake-up — loop re-checks state.
                continue;
            }
            if (PQconsumeInput(pg) == 0) {
                status = WORKER_PORT_ABORTED;
                break;
            }
            continue;
        }

        // Not busy → drain one result. In pipeline mode PQgetResult
        // returns a sequence ending in PGRES_PIPELINE_SYNC, with
        // NULL separators between queries. Count only non-NULL.
        PGresult* r = PQgetResult(pg);
        if (r != NULL) {
            PQclear(r);
            remaining--;
        }
        // NULL = separator; outer loop re-checks PQisBusy.
    }

    PQexitPipelineMode(pg);

    // A mid-pipeline error leaves the transaction aborted (INERROR) —
    // the pipeline's own COMMIT became PGRES_PIPELINE_ABORTED and never
    // ran. Force a synchronous ROLLBACK so the next acquire of this conn
    // finds a clean state. A HEALTHY open transaction (INTRANS) is
    // intentionally left alone: it belongs to the caller (an external
    // withTransaction composing an executePipeline batch) and its COMMIT
    // arrives on a later submit. Matches the MySQL/SQLite batch contract:
    // the caller owns the surrounding transaction.
    PGTransactionStatusType ts = PQtransactionStatus(pg);
    if (ts == PQTRANS_INERROR) {
        PGresult* rb = PQexec(pg, "ROLLBACK");
        if (rb != NULL) PQclear(rb);
    }

    return status;
}

// ─────────────────────────────────────────────────────────────────
// Single-query with params — ABI MINOR 1 path
// ─────────────────────────────────────────────────────────────────
//
// Mirrors `execute_single` but uses `PQsendQueryParams` so the SQL
// and the parameter values travel separately (Extended Query
// Protocol). The select()/PQconsumeInput()/PQisBusy() drain loop
// is identical — libpq's notify-when-result-ready semantics do not
// depend on which Send* primitive dispatched the query.

static int64_t execute_single_params(native_conn_t* conn,
                                     const char* sql,
                                     int32_t n_params,
                                     const int32_t* param_types,
                                     const char* const* param_values,
                                     const int* param_lengths,
                                     const int* param_formats,
                                     int result_format,
                                     int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    // libpq accepts NULL for `paramTypes` when n_params == 0 (server
    // inference). For n_params > 0 we always provide the array (zeros
    // also mean inference), so we can pass it through directly.
    Oid* types_oid = NULL;
    if (n_params > 0 && param_types != NULL) {
        // Cast int32_t* → Oid* (Oid is unsigned int in libpq; same
        // width as int32_t on every supported platform).
        types_oid = (Oid*)param_types;
    }

    if (PQsendQueryParams(pg,
                          sql,
                          n_params,
                          types_oid,
                          param_values,
                          param_lengths,
                          param_formats,
                          result_format) != 1) {
        return WORKER_PORT_ABORTED;
    }

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Spin-free flush (deadline computed above so it counts the send).
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        return WORKER_PORT_ABORTED;
    }

    while (1) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(sock, &rfds);

        struct timeval tv;
        if (!next_select_tv(&tv, has_deadline, &deadline)) {
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return WORKER_PORT_ABORTED;
        }
        if (rc == 0) continue;
        if (PQconsumeInput(pg) == 0) {
            return WORKER_PORT_ABORTED;
        }
        if (!PQisBusy(pg)) {
            return WORKER_PORT_OK;
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Multi-read execution path — ABI MINOR 2 (2026-07-28)
// ─────────────────────────────────────────────────────────────────
//
// Runs N read statements in ONE round-trip via the Simple Query
// Protocol (statements joined with `;`, one `PQsendQuery`) and
// PRESERVES every result set, unlike `execute_pipeline` which
// discards them. All results are drained into the per-conn chain
// (native_pool_chain_append) BEFORE the worker posts OK, so the Dart
// side never touches a blocking `PQgetResult` — it just dequeues the
// already-materialised chain via `poll_result`.
//
// Error semantics: a mid-statement error makes the server abort the
// implicit transaction; the error PGresult is appended to the chain
// (it carries the real server message) and the Dart side decides how
// to surface it. Timeout/shutdown/dispatch errors free the partial
// chain and return ABORTED.

static char* join_with_semicolons(char** queries, int32_t count) {
    size_t total = 1;  // trailing NUL
    for (int32_t i = 0; i < count; i++) {
        total += strlen(queries[i]);
        if (i > 0) total += 1;  // ';' separator
    }
    char* joined = (char*)malloc(total);
    if (joined == NULL) return NULL;
    char* p = joined;
    for (int32_t i = 0; i < count; i++) {
        if (i > 0) *p++ = ';';
        size_t len = strlen(queries[i]);
        memcpy(p, queries[i], len);
        p += len;
    }
    *p = '\0';
    return joined;
}

static int64_t execute_multi_read(native_conn_t* conn,
                                  char** queries,
                                  int32_t count,
                                  int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    // Defensive: drop any chain left over from an abandoned prior
    // multi-read (pool_release also does this, but a conn reused
    // without release must not accumulate stale results).
    native_pool_free_result_chain(conn);

    char* joined = join_with_semicolons(queries, count);
    if (joined == NULL) return WORKER_PORT_ABORTED;

    int rc_send = PQsendQuery(pg, joined);
    free(joined);
    if (rc_send != 1) return WORKER_PORT_ABORTED;

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Spin-free flush; free the partial chain on abort like the paths below.
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        native_pool_free_result_chain(conn);
        return WORKER_PORT_ABORTED;
    }

    while (1) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            native_pool_free_result_chain(conn);
            return WORKER_PORT_ABORTED;
        }

        if (PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);

            struct timeval tv;
            if (!next_select_tv(&tv, has_deadline, &deadline)) {
                issue_cancel(pg);
                native_pool_free_result_chain(conn);
                return WORKER_PORT_ABORTED;
            }

            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                native_pool_free_result_chain(conn);
                return WORKER_PORT_ABORTED;
            }
            if (rc == 0) {
                // Shutdown-poll tick or deadline — re-check at top.
                continue;
            }
            if (PQconsumeInput(pg) == 0) {
                native_pool_free_result_chain(conn);
                return WORKER_PORT_ABORTED;
            }
            continue;
        }

        // Not busy → safe to pull one result without blocking.
        PGresult* r = PQgetResult(pg);
        if (r == NULL) break;  // whole multi-statement drained
        if (!native_pool_chain_append(conn, r)) {
            PQclear(r);
            native_pool_free_result_chain(conn);
            return WORKER_PORT_ABORTED;
        }
        // Loop; PQisBusy re-checked before the next PQgetResult.
    }

    return WORKER_PORT_OK;
}

// ─────────────────────────────────────────────────────────────────
// Worker entry point
// ─────────────────────────────────────────────────────────────────

void* native_pool_worker_main(void* arg) {
    native_conn_t* conn = (native_conn_t*)arg;

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
            return NULL;
        }

        // Snapshot slot fields. Keep slot_filled=1 so concurrent
        // submits see "occupied" until we finish posting + clear.
        int is_pipeline = conn->is_pipeline;
        int is_params = conn->is_params;
        int is_multi_read = conn->is_multi_read;
        int32_t sql_count = conn->sql_count;
        int64_t port_id = conn->port_id;
        int64_t timeout_ms = conn->timeout_ms;
        char** sql = conn->sql;
        int32_t n_params = conn->n_params;
        const int32_t* param_types_snap   = conn->param_types;
        const char* const* param_vals_snap =
            (const char* const*)conn->param_values;
        const int* param_lens_snap        = conn->param_lengths;
        const int* param_fmts_snap        = conn->param_formats;
        int result_format = conn->result_format;
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 2. Execute (one of three paths) ──
        int64_t status;
        if (is_params) {
            status = execute_single_params(conn, sql[0],
                                           n_params,
                                           param_types_snap,
                                           param_vals_snap,
                                           param_lens_snap,
                                           param_fmts_snap,
                                           result_format,
                                           timeout_ms);
        } else if (is_multi_read) {
            status = execute_multi_read(conn, sql, sql_count, timeout_ms);
        } else if (is_pipeline) {
            status = execute_pipeline(conn, sql, sql_count, timeout_ms);
        } else {
            status = execute_single(conn, sql[0], timeout_ms);
        }

        // ── 3. Clear slot FIRST — must precede the Dart-side post.
        //
        // If we posted before clearing, a fast Dart isolate could
        // receive the notification, drain the result, release the
        // conn, and have another async path re-acquire + submit on
        // the same conn — all before this worker grabs `slot_mutex`
        // to clear `slot_filled`. The second `pool_submit_query`
        // would then see `slot_filled == 1` and return 0, surfacing
        // as a spurious "libpq refused to send query" in Dart.
        // Clearing first closes the window: by the time Dart sees
        // the message, the slot is provably free.
        pthread_mutex_lock(&conn->slot_mutex);
        native_pool_free_slot_payload(conn);
        conn->slot_filled = 0;
        pthread_cond_signal(&conn->slot_cond);
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 4. Notify Dart ──
        Dart_CObject msg;
        msg.type = Dart_CObject_kInt64;
        msg.value.as_int64 = status;
        Dart_PostCObject_DL((Dart_Port)port_id, &msg);
    }
}
