/// mysql_pool.h — Native thread/conn pool for MySQL (thread-per-conn).
///
///  — mirrors `native_pool.h` (PostgreSQL, approach B)
/// for the MySQL driver, per the extensibility blueprint in
/// the layered architecture in the package README. Each pool owns N `MYSQL*`
/// and N pthread workers in a 1:1 mapping.
///
/// Key difference from the PostgreSQL pool: `libmysqlclient` exposes a
/// **blocking** client API (no `PQsetnonblocking` equivalent in the base
/// client). The thread-per-conn design absorbs this naturally — each
/// worker simply blocks in `mysql_real_query` + `mysql_store_result`
/// while the Dart event loop stays free — so there is no
/// `select`/`PQconsumeInput`/`PQisBusy` drain loop here.
///
/// This public header exposes ONLY opaque handles and primitive types —
/// it does not include <mysql.h>, so consumers of the ABI never depend
/// on the MySQL client headers. (Cleaner than the PostgreSQL headers,
/// which leak `PGconn*`/`PGresult*`.)
///
/// Ownership rules (identical contract to the PostgreSQL pool):
///   * `mysql_pool_t*` is owned by the Dart side; `mysql_pool_destroy`
///     blocks until all workers exit and `mysql_close` was called on
///     every conn.
///   * `mysql_conn_t*` is borrowed from the pool between
///     `mysql_pool_acquire` and `mysql_pool_release`. After release the
///     handle MUST NOT be dereferenced by Dart.
///   * the `native_mysql_result_t*` returned by
///     `native_mysql_poll_result(mysql_conn_t*)` is caller-owned;
///     release via `native_mysql_clear_result` (declared in
///     `native_mysql.h`).
///
/// Both `mysql_pool_t` and `mysql_conn_t` are opaque to Dart; the Dart
/// binding sees `Pointer<Void>` only.

#ifndef MYSQL_POOL_H
#define MYSQL_POOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque pool handle. Internal layout in `mysql_pool_internal.h`.
typedef struct mysql_pool mysql_pool_t;

/// Opaque per-connection handle. Internal layout in
/// `mysql_pool_internal.h`. Each instance owns exactly one `MYSQL*` and
/// exactly one worker pthread; the two are bound for the entire pool
/// lifetime.
typedef struct mysql_conn mysql_conn_t;

/// Creates a pool of `max_size` connections.
///
/// Spawns `max_size` `MYSQL*` via `mysql_real_connect` and one worker
/// pthread per conn. Returns NULL if any conn fails to open or any
/// thread fails to spawn (partial state is rolled back before
/// returning).
///
/// Unlike the libpq pool (single `conninfo` string), MySQL connection
/// coordinates are passed discretely, matching `mysql_real_connect`.
///
/// Parameters:
///   * `host` / `user` / `password` / `db`  copied internally.
///                                           NULL `db` selects no schema.
///   * `port`                                TCP port (0 ⇒ 3306 default).
///   * `min_size`           reserved for future warm-up policy; the pool
///                          currently always allocates `max_size` conns.
///   * `max_size`           must be ≥ 1.
///   * `acquire_timeout_ms` default deadline for `mysql_pool_acquire`
///                          callers passing `0`.
///
/// Failure modes printed to stderr (consistent with the libpq pool).
mysql_pool_t* mysql_pool_create(
    const char* host,
    const char* user,
    const char* password,
    const char* db,
    uint16_t port,
    int32_t min_size,
    int32_t max_size,
    int64_t acquire_timeout_ms
);

/// Blocks until a free `mysql_conn_t*` is available or `timeout_ms`
/// elapses. Same `timeout_ms` semantics as the libpq pool:
///   * `0`  → use the pool default; if that is also 0, non-blocking probe.
///   * `>0` → wait up to that many milliseconds.
///   * `<0` → wait indefinitely.
/// Returns NULL on timeout. Must be returned via `mysql_pool_release`.
mysql_conn_t* mysql_pool_acquire(mysql_pool_t* pool, int64_t timeout_ms);

/// Returns a `mysql_conn_t*` to the pool. No-op if `conn` is NULL.
/// Double-release is a programmer error and may corrupt the free-list.
void mysql_pool_release(mysql_pool_t* pool, mysql_conn_t* conn);

/// Submits a single SQL statement to `conn`'s worker thread.
///
/// Non-blocking dispatch. The worker wakes up, runs the query via
/// `mysql_real_query` + `mysql_store_result` and posts to `port_id`:
///   * int64 = 1 → result available; caller drains via
///                 `native_mysql_poll_result`.
///   * int64 = 2 → aborted (query failed or connection error). Caller
///                 should treat the conn as suspect.
///
/// Returns 1 on dispatch success, 0 if `conn` already has a pending
/// query (slot occupied) or has been shut down.
///
/// `timeout_ms`:
///   * `0`  → no timeout.
///   * `>0` → best-effort deadline. NOTE (v1): per-query wall-clock
///            enforcement is not implemented for the blocking MySQL
///            path; use `mysql_pool_cancel` to abort. The parameter is
///            accepted for ABI symmetry with the PostgreSQL pool.
int mysql_pool_submit_query(
    mysql_conn_t* conn,
    const char* sql,
    int64_t port_id,
    int64_t timeout_ms
);

/// Submits a batch of `count` statements to `conn`'s worker, executed in
/// a SINGLE round-trip via multi-statement (`CLIENT_MULTI_STATEMENTS`).
/// The MySQL analog of the PostgreSQL `pool_submit_pipeline`. ABI MINOR 1.
///
/// Same delivery contract as `mysql_pool_submit_query` (int64 = 1 ok /
/// 2 aborted). The worker joins the statements, runs them, and drains ALL
/// result sets. If ANY statement errors mid-batch it posts int64 = 2 so
/// the caller rolls back the surrounding transaction. Row data is NOT
/// surfaced (batch is for writes) — same limitation as the libpq pipeline.
///
/// SECURITY: `stmts` must be **synthesized by the program** (internal /
/// computed values), never SQL influenced by external input — multi-
/// statement + interpolation would be an injection surface. Bound-parameter
/// batching is separate future work.
///
/// Returns 1 on dispatch success, 0 if the slot is busy, `count <= 0`,
/// or allocation failed.
int mysql_pool_submit_batch(
    mysql_conn_t* conn,
    const char* const* stmts,
    int32_t count,
    int64_t port_id,
    int64_t timeout_ms
);

/// Submits `count` READ statements in a SINGLE round-trip (multi-statement)
/// and PRESERVES the N result sets. ABI MINOR 2 — the general form of
/// read-batching (any heterogeneous reads, not only IN-list-able ones).
///
/// Same delivery contract as `mysql_pool_submit_query` (int64 = 1 ok /
/// 2 aborted; aborted on a mid-batch error, freeing the partial chain).
/// After int64 = 1, the caller drains the N result sets by calling
/// `native_mysql_poll_result` `count` times — it returns each in statement
/// order (chained internally) and NULL once exhausted.
///
/// SECURITY: `reads` must be program-synthesized (as `mysql_pool_submit_batch`).
///
/// Returns 1 on dispatch success, 0 if the slot is busy, `count <= 0`, or
/// allocation failed.
int mysql_pool_submit_multi_read(
    mysql_conn_t* conn,
    const char* const* reads,
    int32_t count,
    int64_t port_id,
    int64_t timeout_ms
);

/// Best-effort cancel of any in-flight query on `conn`.
///
/// MySQL has no thread-safe in-connection cancel like libpq's
/// `PQcancel`; cancellation is performed by issuing `KILL QUERY <id>`
/// over a separate short-lived connection built from the pool's stored
/// credentials. Fire-and-forget.
void mysql_pool_cancel(mysql_conn_t* conn);

/// Tears the pool down. Signals shutdown to every worker, cancels any
/// in-flight query, joins all threads, calls `mysql_close` on every
/// conn, frees the pool struct. After this returns, `pool` and every
/// derived `mysql_conn_t*` are dangling. No-op on NULL.
void mysql_pool_destroy(mysql_pool_t* pool);

#ifdef __cplusplus
}
#endif

#endif /* MYSQL_POOL_H */
