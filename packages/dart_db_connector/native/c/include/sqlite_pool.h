/// sqlite_pool.h — Native thread/conn pool for SQLite (thread-per-conn over
/// libsqlite3, embedded).
///
///  — mirrors `mysql_pool.h` for SQLite. Each pool owns N
/// `sqlite3*` handles opened on the SAME database FILE in **WAL** mode (N
/// concurrent readers + 1 writer) and N pthread workers, 1:1. The vertical
/// contract is identical to the network drivers (submit → worker blocks →
/// posts int64 to a Native Port → caller polls); the difference is that the
/// worker offloads a synchronous `sqlite3_step` from the isolate rather than
/// overlapping network latency.
///
/// Public header exposes only opaque handles + primitives — no <sqlite3.h>.

#ifndef SQLITE_POOL_H
#define SQLITE_POOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque pool handle. Internal layout in `sqlite_pool_internal.h`.
typedef struct sqlite_pool sqlite_pool_t;

/// Opaque per-connection handle. Each owns one `sqlite3*` + one worker
/// pthread bound for the pool lifetime.
typedef struct sqlite_conn sqlite_conn_t;

/// Creates a pool of `max_size` connections to the database file `path`
/// (`:memory:` is NOT recommended — each conn would get a private DB; use a
/// file for shared WAL). Opens each `sqlite3*` with
/// `SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE`, sets `journal_mode=WAL` and
/// `busy_timeout=busy_timeout_ms`. Spawns one worker per conn. Returns NULL
/// on any open/thread failure (partial state rolled back).
///
/// `min_size` reserved (pool always allocates `max_size`); `max_size` ≥ 1;
/// `acquire_timeout_ms` default deadline for `sqlite_pool_acquire(0)`.
sqlite_pool_t* sqlite_pool_create(
    const char* path,
    int32_t min_size,
    int32_t max_size,
    int64_t acquire_timeout_ms,
    int32_t busy_timeout_ms
);

/// Blocks until a free conn or `timeout_ms` elapses (0 = pool default / probe;
/// >0 = wait ms; <0 = wait forever). NULL on timeout. Return via release.
sqlite_conn_t* sqlite_pool_acquire(sqlite_pool_t* pool, int64_t timeout_ms);

/// Returns a conn to the pool. No-op on NULL.
void sqlite_pool_release(sqlite_pool_t* pool, sqlite_conn_t* conn);

/// Submits one SQL statement to `conn`'s worker (non-blocking dispatch). The
/// worker prepares/steps/materialises and posts to `port_id`:
///   * int64 = 1 → result ready; drain via `native_sqlite_poll_result`.
///   * int64 = 2 → aborted; message via `native_sqlite_last_error`.
/// Returns 1 on dispatch, 0 if the slot is busy or the conn is shut down.
int sqlite_pool_submit_query(
    sqlite_conn_t* conn,
    const char* sql,
    int64_t port_id,
    int64_t timeout_ms
);

/// Submits a batch of WRITE statements in ONE round-trip (';'-joined), run
/// via `sqlite3_exec` (rows discarded). ABI MINOR 1 — amortises the fixed
/// Native Port overhead over N statements. Same delivery contract as
/// `sqlite_pool_submit_query` (int64 = 1 ok / 2 aborted; aborted on a
/// mid-batch error → caller rolls back). Returns 1 on dispatch, 0 if the slot
/// is busy / `count <= 0` / OOM.
///
/// SECURITY: `stmts` must be program-synthesized, never external input.
int sqlite_pool_submit_batch(
    sqlite_conn_t* conn,
    const char* const* stmts,
    int32_t count,
    int64_t port_id,
    int64_t timeout_ms
);

/// Submits `count` READ statements in ONE round-trip and PRESERVES the N
/// result sets (chained; drain via `native_sqlite_poll_result` × count). ABI
/// MINOR 1. Same delivery contract; aborted on a mid-batch error (frees the
/// partial chain). `reads` must be program-synthesized.
int sqlite_pool_submit_multi_read(
    sqlite_conn_t* conn,
    const char* const* reads,
    int32_t count,
    int64_t port_id,
    int64_t timeout_ms
);

/// SYNCHRONOUS fast-path (ABI MINOR 2): runs `sql` on the CALLING thread
/// (prepare/step/materialise), skipping the Native Port + worker thread hop.
/// For LIGHT queries only (a point-read is < 1µs) — the study showed the
/// async machinery costs ~8µs/op, dominant for tiny ops. Blocks the caller
/// for the query's duration; do NOT use for heavy scans (use the async
/// `sqlite_pool_submit_query`, which keeps the isolate free).
///
/// On success (return 1) the result is stored on `conn` and retrieved with
/// `native_sqlite_poll_result`, exactly like the async path. Returns 2 on
/// query error (message via `native_sqlite_last_error`), or **0 if refused**
/// because an async op is still pending on this conn (the caller must fall
/// back to the async path). Correctness: it holds the conn's slot mutex while
/// running, so the worker thread cannot touch the same `sqlite3*` meanwhile.
int sqlite_conn_exec_sync(sqlite_conn_t* conn, const char* sql);

/// Tears the pool down: signals shutdown, joins workers, `sqlite3_close_v2`
/// each conn, frees the struct. No-op on NULL.
void sqlite_pool_destroy(sqlite_pool_t* pool);

#ifdef __cplusplus
}
#endif

#endif /* SQLITE_POOL_H */
