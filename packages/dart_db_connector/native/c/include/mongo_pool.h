/// mongo_pool.h — Native thread/conn pool for MongoDB (thread-per-conn
/// over libmongoc's connection pool).
///
///  — mirrors `mysql_pool.h` for the MongoDB driver, per
/// the extensibility blueprint. The vertical
/// contract is IDENTICAL to the relational drivers (submit → the worker
/// blocks → posts an int64 to a Native Port → caller polls the result), but
/// the internal core differs, as authorized by the "vertical contract
/// constant, native core free per driver" principle.
///
/// Pool model:
/// a single `mongoc_client_pool_t` is built from the connection URI; each
/// of the N worker threads owns one `mongoc_client_t` popped once at
/// startup and pushed back at teardown (pop-hold-push). This gives
/// thread-per-conn semantics AND correct background SDAM monitoring —
/// `mongoc_client_t` is NOT thread-safe, so 1 client per thread is the
/// idiomatic use.
///
/// Two differences from the relational pools, forced by the document model:
///   * Connection coordinates are a MongoDB URI string (not discrete
///     host/user/pass/port).
///   * There is no universal query string; submissions are TYPED per
///     operation. Each carries the target db + collection and one or two
///     BSON buffers (the caller-encoded documents), plus a Native Port.
///
/// This public header exposes ONLY opaque handles and primitive types — it
/// does not include <mongoc/mongoc.h>. Both handles are opaque to Dart
/// (`Pointer<Void>`).

#ifndef MONGO_POOL_H
#define MONGO_POOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque pool handle. Internal layout in `mongo_pool_internal.h`.
typedef struct mongo_pool mongo_pool_t;

/// Opaque per-connection handle. Each instance owns exactly one
/// `mongoc_client_t` (popped from the shared client pool) and one worker
/// pthread, bound for the entire pool lifetime.
typedef struct mongo_conn mongo_conn_t;

/// Creates a pool of `max_size` connections from a MongoDB `uri`
/// (e.g. "mongodb://user:pass@host:27017/?authSource=admin").
///
/// Builds one `mongoc_client_pool_t` (maxPoolSize forced to at least
/// `max_size`), pops `max_size` clients (one per worker), and spawns one
/// worker pthread per conn. Returns NULL on a bad URI, a failed pop, or a
/// failed thread spawn (partial state rolled back). Failures printed to
/// stderr, consistent with the other pools.
///
/// `min_size` is reserved for a future warm-up policy; the pool currently
/// always allocates `max_size`. `max_size` must be ≥ 1.
/// `acquire_timeout_ms` is the default deadline for `mongo_pool_acquire`
/// callers passing 0.
mongo_pool_t* mongo_pool_create(
    const char* uri,
    int32_t min_size,
    int32_t max_size,
    int64_t acquire_timeout_ms
);

/// Blocks until a free `mongo_conn_t*` is available or `timeout_ms`
/// elapses. Same semantics as the relational pools:
///   * `0`  → pool default; if that is also 0, non-blocking probe.
///   * `>0` → wait up to that many milliseconds.
///   * `<0` → wait indefinitely.
/// Returns NULL on timeout. Must be returned via `mongo_pool_release`.
mongo_conn_t* mongo_pool_acquire(mongo_pool_t* pool, int64_t timeout_ms);

/// Returns a `mongo_conn_t*` to the pool. No-op if `conn` is NULL.
void mongo_pool_release(mongo_pool_t* pool, mongo_conn_t* conn);

/* ─────── Typed operation submissions ───────
 *
 * All are non-blocking dispatch. The worker wakes up, runs the operation
 * with libmongoc (blocking), and posts to `port_id`:
 *   * int64 = 1 → success; drain via `native_mongo_poll_result`.
 *   * int64 = 2 → aborted; the error text/code is available via
 *                 `native_mongo_last_error` / `_code` (native_mongo.h).
 * Each returns 1 on dispatch success, 0 if the slot is busy, the conn is
 * shut down, or allocation failed.
 *
 * BSON buffers (`*_bson` + `*_len`) are caller-encoded documents; they are
 * copied into the slot on dispatch, so the caller may free them on return.
 * `db` and `coll` are copied too.
 */

/// Runs `find` with `filter` and optional `opts` (limit/sort/projection…,
/// or NULL/0). Yields the matched documents, chained (drain N times).
int mongo_pool_submit_find(
    mongo_conn_t* conn,
    const char* db, const char* coll,
    const uint8_t* filter_bson, int32_t filter_len,
    const uint8_t* opts_bson, int32_t opts_len,
    int64_t port_id, int64_t timeout_ms
);

/// Inserts one `document`. Yields the write reply (insertedCount, …).
int mongo_pool_submit_insert_one(
    mongo_conn_t* conn,
    const char* db, const char* coll,
    const uint8_t* doc_bson, int32_t doc_len,
    int64_t port_id, int64_t timeout_ms
);

/// Updates one document matching `selector` with `update` (must use
/// operators, e.g. `$set`). Yields the reply (matchedCount/modifiedCount).
int mongo_pool_submit_update_one(
    mongo_conn_t* conn,
    const char* db, const char* coll,
    const uint8_t* selector_bson, int32_t selector_len,
    const uint8_t* update_bson, int32_t update_len,
    int64_t port_id, int64_t timeout_ms
);

/// Deletes one document matching `selector`. Yields the reply (deletedCount).
int mongo_pool_submit_delete_one(
    mongo_conn_t* conn,
    const char* db, const char* coll,
    const uint8_t* selector_bson, int32_t selector_len,
    int64_t port_id, int64_t timeout_ms
);

/// Runs an arbitrary database `command` (count, createIndexes, aggregate
/// with an inline cursor batch, ping…). Yields the single reply document.
int mongo_pool_submit_command(
    mongo_conn_t* conn,
    const char* db,
    const uint8_t* command_bson, int32_t command_len,
    int64_t port_id, int64_t timeout_ms
);

/// Inserts N documents in one operation (F1-Mongo bulk, ABI MINOR 1.1) via
/// mongoc_collection_insert_many. `docs_bson` is `doc_count` BSON documents
/// concatenated back-to-back; each is self-delimiting (its int32 length
/// prefix), so the worker slices them with bson_init_static. `docs_total_len`
/// is the byte length of the whole blob. `ordered` != 0 preserves order and
/// stops at the first write error; 0 = unordered (faster, collects all write
/// errors). libmongoc auto-splits by maxWriteBatchSize / maxMessageSizeBytes.
///
/// Yields ONE reply document (insertedCount, and writeErrors[] on partial
/// failure). Unlike the single-doc writes, the reply is stored EVEN when the
/// op reports failure, so the caller can surface per-index write errors; the
/// real bson_error_t is also available via native_mongo_last_error / _code.
int mongo_pool_submit_insert_many(
    mongo_conn_t* conn,
    const char* db, const char* coll,
    const uint8_t* docs_bson, int32_t docs_total_len,
    int32_t doc_count, int32_t ordered,
    int64_t port_id, int64_t timeout_ms
);

/// Tears the pool down. Signals shutdown to every worker, joins all
/// threads, pushes every client back and destroys the client pool, frees
/// the pool struct. After this returns, `pool` and every derived
/// `mongo_conn_t*` are dangling. No-op on NULL.
void mongo_pool_destroy(mongo_pool_t* pool);

#ifdef __cplusplus
}
#endif

#endif /* MONGO_POOL_H */
