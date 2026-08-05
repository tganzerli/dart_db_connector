/// mongo_pool_worker.c — Body of the per-conn worker thread for the MongoDB
/// pool. One worker owns one `mongoc_client_t` for the entire pool lifetime
/// and is the ONLY thread that touches it (libmongoc clients are not
/// thread-safe).
///
/// libmongoc operations are blocking; the thread-per-conn design keeps the
/// Dart event loop free because the blocking call runs on this OS thread,
/// not the isolate. The vertical contract matches the relational drivers:
/// snapshot the slot, run the op, clear the slot, post an int64 to the
/// Native Port. What differs is the op dispatch (typed union, not a SQL
/// string) and the result shape (a chain of copied BSON buffers).

#include "mongo_pool.h"
#include "mongo_pool_internal.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <mongoc/mongoc.h>

#include "dart/dart_api_dl.h"

#define WORKER_PORT_OK      ((int64_t)1)
#define WORKER_PORT_ABORTED ((int64_t)2)

// Records a libmongoc failure into the conn so Dart can surface the real
// message + code (native_mongo_last_error / _code) instead of an opaque
// "aborted".
static void set_error(mongo_conn_t* conn, const bson_error_t* err) {
    if (err != NULL) {
        snprintf(conn->last_error, MONGO_ERR_BUF, "%s", err->message);
        conn->last_error_code = (int32_t)err->code;
    } else {
        snprintf(conn->last_error, MONGO_ERR_BUF, "unknown error");
        conn->last_error_code = 0;
    }
}

// Allocates a result wrapper owning a copy of `len` BSON bytes. NULL on OOM.
static native_mongo_result_t* make_result(const uint8_t* data, int32_t len) {
    native_mongo_result_t* w =
        (native_mongo_result_t*)calloc(1, sizeof(*w));
    if (w == NULL) return NULL;
    w->data = (uint8_t*)malloc((size_t)len);
    if (w->data == NULL) { free(w); return NULL; }
    memcpy(w->data, data, (size_t)len);
    w->len = len;
    w->next = NULL;
    return w;
}

// Frees a chain of result wrappers (buffer + node).
static void free_result_chain(native_mongo_result_t* head) {
    while (head != NULL) {
        native_mongo_result_t* next = head->next;
        free(head->data);
        free(head);
        head = next;
    }
}

// Stores a single reply document (from a write/command) as a chain of one.
static int64_t store_single(mongo_conn_t* conn, const bson_t* reply) {
    native_mongo_result_t* w =
        make_result(bson_get_data(reply), (int32_t)reply->len);
    if (w == NULL) return WORKER_PORT_ABORTED;
    conn->last_result = w;
    return WORKER_PORT_OK;
}

// ── find: drain the cursor into a chain of copied documents ──
static int64_t execute_find(mongo_conn_t* conn) {
    mongoc_collection_t* coll =
        mongoc_client_get_collection(conn->client, conn->db, conn->coll);
    bson_t filter, opts;
    bson_init_static(&filter, conn->doc1, (size_t)conn->doc1_len);
    int has_opts = (conn->doc2 != NULL && conn->doc2_len > 0);
    if (has_opts) bson_init_static(&opts, conn->doc2, (size_t)conn->doc2_len);

    mongoc_cursor_t* cur = mongoc_collection_find_with_opts(
        coll, &filter, has_opts ? &opts : NULL, NULL);

    native_mongo_result_t* head = NULL;
    native_mongo_result_t* tail = NULL;
    const bson_t* doc;
    int64_t status = WORKER_PORT_OK;
    while (mongoc_cursor_next(cur, &doc)) {
        native_mongo_result_t* w =
            make_result(bson_get_data(doc), (int32_t)doc->len);
        if (w == NULL) { free_result_chain(head); head = NULL;
                         status = WORKER_PORT_ABORTED; goto done; }
        if (head == NULL) head = tail = w;
        else { tail->next = w; tail = w; }
    }
    bson_error_t err;
    if (mongoc_cursor_error(cur, &err)) {
        set_error(conn, &err);
        free_result_chain(head);
        head = NULL;
        status = WORKER_PORT_ABORTED;
    }
done:
    conn->last_result = head;  // NULL for a 0-document find (still OK)
    mongoc_cursor_destroy(cur);
    mongoc_collection_destroy(coll);
    return status;
}

// ── insert_one / update_one / delete_one : one reply document ──
static int64_t execute_write(mongo_conn_t* conn) {
    mongoc_collection_t* coll =
        mongoc_client_get_collection(conn->client, conn->db, conn->coll);
    bson_t d1;
    bson_init_static(&d1, conn->doc1, (size_t)conn->doc1_len);
    bson_t reply;
    bson_error_t err;
    bool ok = false;

    if (conn->op == MONGO_OP_INSERT_ONE) {
        ok = mongoc_collection_insert_one(coll, &d1, NULL, &reply, &err);
    } else if (conn->op == MONGO_OP_UPDATE_ONE) {
        bson_t d2;
        bson_init_static(&d2, conn->doc2, (size_t)conn->doc2_len);
        ok = mongoc_collection_update_one(coll, &d1, &d2, NULL, &reply, &err);
    } else { // MONGO_OP_DELETE_ONE
        ok = mongoc_collection_delete_one(coll, &d1, NULL, &reply, &err);
    }

    int64_t status;
    if (!ok) {
        set_error(conn, &err);
        status = WORKER_PORT_ABORTED;
    } else {
        status = store_single(conn, &reply);
    }
    bson_destroy(&reply);
    mongoc_collection_destroy(coll);
    return status;
}

// ── command : one reply document ──
static int64_t execute_command(mongo_conn_t* conn) {
    bson_t cmd;
    bson_init_static(&cmd, conn->doc1, (size_t)conn->doc1_len);
    bson_t reply;
    bson_error_t err;
    bool ok = mongoc_client_command_simple(
        conn->client, conn->db, &cmd, NULL, &reply, &err);
    int64_t status;
    if (!ok) {
        set_error(conn, &err);
        status = WORKER_PORT_ABORTED;
    } else {
        status = store_single(conn, &reply);
    }
    bson_destroy(&reply);
    return status;
}

// ── insert_many : slice the contiguous blob, one bulk insert, one reply ──
static int64_t execute_insert_many(mongo_conn_t* conn) {
    mongoc_collection_t* coll =
        mongoc_client_get_collection(conn->client, conn->db, conn->coll);
    int32_t n = conn->doc_count;

    bson_t*       docs = (bson_t*)malloc(sizeof(bson_t) * (size_t)n);
    const bson_t** ptrs = (const bson_t**)malloc(sizeof(bson_t*) * (size_t)n);
    if (docs == NULL || ptrs == NULL) {
        free(docs); free(ptrs);
        mongoc_collection_destroy(coll);
        set_error(conn, NULL);
        return WORKER_PORT_ABORTED;
    }

    // The N documents are concatenated back-to-back in conn->doc1; each is
    // self-delimiting via its int32 little-endian length prefix. Slice them
    // with bson_init_static (zero-copy over the slot's single copy).
    int32_t off = 0;
    int valid = 1;
    for (int32_t i = 0; i < n; i++) {
        if (off + 4 > conn->doc1_len) { valid = 0; break; }
        int32_t len;
        memcpy(&len, conn->doc1 + off, sizeof(int32_t));  // BSON prefix is LE
        if (len < 5 || off + len > conn->doc1_len) { valid = 0; break; }
        if (!bson_init_static(&docs[i], conn->doc1 + off, (size_t)len)) {
            valid = 0; break;
        }
        ptrs[i] = &docs[i];
        off += len;
    }
    if (!valid || off != conn->doc1_len) {
        snprintf(conn->last_error, MONGO_ERR_BUF,
                 "insert_many: malformed BSON blob (doc_count/length mismatch)");
        conn->last_error_code = 0;
        free(docs); free(ptrs);
        mongoc_collection_destroy(coll);
        return WORKER_PORT_ABORTED;
    }

    bson_t opts;
    bson_init(&opts);
    BSON_APPEND_BOOL(&opts, "ordered", conn->bulk_ordered != 0);

    bson_t reply;
    bson_error_t err;
    bool ok = mongoc_collection_insert_many(
        coll, ptrs, (size_t)n, &opts, &reply, &err);

    int64_t status = WORKER_PORT_OK;
    if (!ok) {
        set_error(conn, &err);
        status = WORKER_PORT_ABORTED;
    }
    // Store the reply ALWAYS (insertedCount, and writeErrors[] on partial
    // failure) so Dart surfaces per-index errors even on an aborted op.
    if (store_single(conn, &reply) == WORKER_PORT_ABORTED) {
        status = WORKER_PORT_ABORTED;  // OOM copying the reply
    }

    bson_destroy(&opts);
    bson_destroy(&reply);
    free(docs);
    free(ptrs);
    mongoc_collection_destroy(coll);
    return status;
}

void* mongo_pool_worker_main(void* arg) {
    mongo_conn_t* conn = (mongo_conn_t*)arg;

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
        int op = conn->op;
        int64_t port_id = conn->port_id;
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 2. Reset error, execute (blocking) ──
        conn->last_error[0] = '\0';
        conn->last_error_code = 0;
        int64_t status;
        switch (op) {
            case MONGO_OP_FIND:        status = execute_find(conn); break;
            case MONGO_OP_COMMAND:     status = execute_command(conn); break;
            case MONGO_OP_INSERT_MANY: status = execute_insert_many(conn); break;
            default:                   status = execute_write(conn); break;
        }

        // ── 3. Clear slot FIRST (same race note as the MySQL worker) ──
        pthread_mutex_lock(&conn->slot_mutex);
        mongo_pool_free_slot_payload(conn);
        conn->slot_filled = 0;
        pthread_cond_signal(&conn->slot_cond);
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 4. Notify Dart ──
        Dart_CObject msg;
        msg.type = Dart_CObject_kInt64;
        msg.value.as_int64 = status;
        Dart_PostCObject_DL((Dart_Port)port_id, &msg);
    }

    return NULL;
}
