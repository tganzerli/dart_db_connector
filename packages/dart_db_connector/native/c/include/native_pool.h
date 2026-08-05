/// native_pool.h — Native thread/conn pool (approach B, thread-per-conn).
///
/// Added in ABI MAJOR 2 as the runtime infrastructure described in
/// (approach B). Each pool owns N PGconn* and N pthread workers in a
/// 1:1 mapping; each worker drains the single pending slot of its conn
/// via libpq blocking (`PQsendQuery` + `select`/`PQconsumeInput`/
/// `PQisBusy` loop) and notifies Dart via `Dart_PostCObject_DL`.
///
/// Ownership rules:
///   * `native_pool_t*` is owned by the Dart side; `pool_destroy`
///     blocks until all workers exit and `PQfinish` was called on
///     every conn.
///   * `native_conn_t*` is borrowed from the pool between
///     `pool_acquire` and `pool_release`. After `pool_release` the
///     handle MUST NOT be dereferenced by Dart.
///   * `PGresult*` returned by `poll_result(native_conn_t*)` is
///     caller-owned; release via `clear_result` (declared in
///     `native_db.h`).
///
/// Both `native_pool_t` and `native_conn_t` are opaque to Dart; the
/// Dart binding sees `Pointer<Void>` only.

#ifndef NATIVE_POOL_H
#define NATIVE_POOL_H

#include <stdint.h>
#include <libpq-fe.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque pool handle. Internal layout in `native_pool.c`.
typedef struct native_pool native_pool_t;

/// Opaque per-connection handle. Internal layout in `native_pool.c`.
/// Each instance owns exactly one `PGconn*` and exactly one worker
/// pthread; the two are bound for the entire pool lifetime.
typedef struct native_conn native_conn_t;

/// Creates a pool of `max_size` connections.
///
/// Spawns `max_size` PGconn via `PQconnectdb(conninfo)` and one
/// worker pthread per conn. Returns NULL if any conn fails to
/// open or any thread fails to spawn (partial state is rolled back
/// before returning).
///
/// Parameters:
///   * `conninfo`           libpq connection string, copied internally.
///   * `min_size`           reserved for future use (warm-up policy);
///                          currently the pool always allocates
///                          `max_size` conns up-front.
///   * `max_size`           must be ≥ 1.
///   * `acquire_timeout_ms` default deadline for `pool_acquire`
///                          callers passing `0`. `0` here means
///                          "no default" (callers MUST pass an
///                          explicit timeout).
///
/// Failure modes printed to stderr (consistent with `connect_db`).
native_pool_t* pool_create(
    const char* conninfo,
    int32_t min_size,
    int32_t max_size,
    int64_t acquire_timeout_ms
);

/// Blocks until a free `native_conn_t*` is available or
/// `timeout_ms` elapses.
///
/// `timeout_ms`:
///   * `0`   → use the pool's default `acquire_timeout_ms`. If the
///             pool default is also 0 the call returns NULL
///             immediately when nothing is free (non-blocking probe).
///   * `>0`  → wait up to that many milliseconds.
///   * `<0`  → wait indefinitely.
///
/// Returns NULL on timeout. The returned handle is checked out and
/// MUST be returned via `pool_release` exactly once.
native_conn_t* pool_acquire(native_pool_t* pool, int64_t timeout_ms);

/// Returns a `native_conn_t*` to the pool. No-op if `conn` is NULL.
/// Idempotency is NOT guaranteed; double-release is a programmer
/// error and may corrupt the pool's free-list.
void pool_release(native_pool_t* pool, native_conn_t* conn);

/// Submits a single SQL statement to `conn`'s worker thread.
///
/// Non-blocking. The worker wakes up, executes the query via libpq
/// (`PQsendQuery` + `select`/`PQconsumeInput`/`PQisBusy` loop) and
/// posts to `port_id`:
///   * int64 = 1 → result available; caller drains via `poll_result`.
///   * int64 = 2 → timeout fired; worker issued `PQcancel`. Caller
///                 should treat the conn as suspect and close+reopen.
///
/// Returns 1 on dispatch success, 0 if `conn` already has a pending
/// query (slot occupied) or if `PQsendQuery` failed.
///
/// `timeout_ms`:
///   * `0` → no timeout (block forever on the libpq side).
///   * `>0` → after that many ms the worker calls `PQcancel(conn)`
///            and posts int64=2.
int pool_submit_query(
    native_conn_t* conn,
    const char* sql,
    int64_t port_id,
    int64_t timeout_ms
);

/// Submits N statements in libpq pipeline mode to `conn`'s worker.
///
/// Same delivery contract as `pool_submit_query`. The worker enters
/// pipeline mode (`PQenterPipelineMode`), sends every statement via
/// `PQsendQueryParams` (parameterless, text format), syncs
/// (`PQpipelineSync`), drains `query_count + 1` PGresults (one per
/// query plus the sync sentinel), and finally exits pipeline mode.
///
/// Returns 1 on dispatch success, 0 if the slot is occupied,
/// `query_count <= 0`, or pipeline setup failed.
///
/// Limitations (inherited from libpq):
///   * SQL statements run with the extended protocol — simple
///     protocol queries (e.g. multi-statement strings) are rejected.
///   * If statement N fails, statements N+1..M arrive as
///     `PGRES_PIPELINE_ABORTED`.
///   * `pool_cancel` aborts the whole pipeline.
int pool_submit_pipeline(
    native_conn_t* conn,
    const char* const* queries,
    int32_t query_count,
    int64_t port_id,
    int64_t timeout_ms
);

/// Submits a single SQL statement with parameters via the Postgres
/// Extended Query Protocol (libpq `PQsendQueryParams`).
///
/// ABI MINOR 1 (2026-05-23) — additive, non-breaking. The legacy
/// `pool_submit_query` (Simple Query Protocol) remains valid and is
/// the right choice when zero params and text-only results are
/// acceptable.
///
/// Parameters:
///   * `sql`            — SQL with `$1`, `$2`, … placeholders. Owned
///                        by the caller; the worker dup-copies before
///                        returning.
///   * `n_params`       — count of bindings (0 ⇒ equivalent to
///                        `PQsendQuery` but using the extended
///                        protocol; result_format still honored).
///   * `param_types`    — Oid array, length `n_params`. Pass 0 to let
///                        the server infer. Owned by caller; copied.
///   * `param_values`   — array of pointers to byte buffers, length
///                        `n_params`. For text format, each buffer is
///                        a null-terminated UTF-8 string; for binary,
///                        it is `param_lengths[i]` raw bytes. NULL
///                        values must be passed as `NULL` (server
///                        treats as SQL NULL). Owned by caller; the
///                        worker dup-copies each buffer.
///   * `param_lengths`  — array of byte lengths, length `n_params`.
///                        Ignored when `param_formats[i] == 0` (text);
///                        required when `param_formats[i] == 1`
///                        (binary).
///   * `param_formats`  — array of format codes, length `n_params`.
///                        `0` = text (default), `1` = binary.
///   * `result_format`  — `0` = result in text format (compatible with
///                        the existing text-mode decoder); `1` = binary
///                        (caller is responsible for binary decoding).
///   * `port_id`        — same delivery contract as `pool_submit_query`.
///   * `timeout_ms`     — same semantics as `pool_submit_query`.
///
/// Returns 1 on dispatch success, 0 if the slot is occupied, the
/// connection has been shut down, allocation failed, or `PQsendQueryParams`
/// itself returned an error.
///
/// SECURITY: This is the **recommended** entry point for any SQL where
/// values come from outside the program. Unlike `pool_submit_query`,
/// the values travel separately from the SQL text — impossible to
/// inject SQL through bound parameters.
int pool_submit_query_params(
    native_conn_t* conn,
    const char* sql,
    int32_t n_params,
    const int32_t* param_types,
    const char* const* param_values,
    const int* param_lengths,
    const int* param_formats,
    int result_format,
    int64_t port_id,
    int64_t timeout_ms
);

/// Submits N read statements to `conn`'s worker to run in a single
/// network round-trip via the Simple Query Protocol (the statements
/// are joined with `;` and dispatched with one `PQsendQuery`), and
/// **preserves** the N result sets instead of discarding them.
///
/// ABI MINOR 2 (2026-07-28) — additive, non-breaking. This is the
/// Postgres materialisation of the F1b "multi-read" lever already
/// shipped for MySQL/SQLite. Unlike `pool_submit_pipeline` (which
/// drains and discards every PGresult, for bulk DML), the worker here
/// drains ALL results into a per-conn FIFO chain BEFORE posting the
/// notification, then `poll_result` dequeues them in statement order.
/// Draining fully on the worker side keeps the Dart isolate off any
/// blocking `PQgetResult`.
///
/// Same delivery contract as `pool_submit_query`:
///   * int64 = 1 → results available; caller drains via `poll_result`
///                 exactly `query_count` times (in order). A statement
///                 that errored surfaces as an error PGresult in the
///                 chain (check via `get_result_status`) — the implicit
///                 transaction aborts and later statements are skipped
///                 by the server, so the chain may be shorter than N.
///   * int64 = 2 → dispatch error, timeout, or shutdown; worker issued
///                 `PQcancel`. Any partial chain is freed.
///
/// Returns 1 on dispatch success, 0 if the slot is occupied,
/// `query_count <= 0`, or an allocation failed.
///
/// SECURITY: like `pool_submit_query`, the statements travel as SQL
/// text (Simple Protocol) — callers MUST synthesize them from trusted
/// input only. For untrusted values use `pool_submit_query_params`.
///
/// Semantics note: multi-statement in the Simple Protocol runs inside
/// a single implicit transaction; a mid-statement error rolls back the
/// earlier statements of the same submit.
int pool_submit_multi_read(
    native_conn_t* conn,
    const char* const* queries,
    int32_t query_count,
    int64_t port_id,
    int64_t timeout_ms
);

/// Sends a libpq `CancelRequest` for any in-flight query on `conn`.
///
/// Fire-and-forget; thread-safe (libpq guarantees this for
/// `PQcancel`). Idempotent on idle conns.
///
/// ABI MAJOR 2: replaces MAJOR 1 `cancel_query(PGconn*)` — the
/// parameter type changes to the pool's opaque handle to keep the
/// new API self-consistent.
void pool_cancel(native_conn_t* conn);

/// Tears the pool down.
///
/// Signals shutdown to every worker, joins all threads (best-effort
/// 5s deadline per thread), calls `PQfinish` on every conn, and
/// frees the pool struct. After this returns, `pool` and every
/// `native_conn_t*` derived from it are dangling.
///
/// No-op on NULL.
void pool_destroy(native_pool_t* pool);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_POOL_H */
