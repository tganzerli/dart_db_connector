#include "native_db.h"

#include <libpq-fe.h>
#include <stdio.h>
#include <stdint.h>

#include "dart/dart_api_dl.h"

// Retorna a versão ABI desta biblioteca empacotada como
// ((int64_t)MAJOR << 32) | MINOR. Read from Dart in
// dart/lib/src/bindings/abi_check.dart para validação em runtime.
int64_t native_db_abi_version(void) {
    return ((int64_t)NATIVE_DB_ABI_VERSION_MAJOR << 32)
         | (int64_t)NATIVE_DB_ABI_VERSION_MINOR;
}

// Inicializa a API nativa do Dart
intptr_t InitDartApiDL(void* data) {
    return Dart_InitializeApiDL(data);
}

// Opens a raw libpq connection. Still exported in MAJOR 2 for
// uso direto em tests/PoCs e como primitiva interna do pool. Conexões
// opened here are the caller's responsibility (call close_db).
PGconn *connect_db(const char *conninfo) {
    PGconn *conn = PQconnectdb(conninfo);
    if (PQstatus(conn) != CONNECTION_OK) {
        fprintf(stderr, "Connection failed: %s\n", PQerrorMessage(conn));
        PQfinish(conn);
        return NULL;
    }
    // Same policy as the pool: non-blocking lets workers use
    // select() + PQconsumeInput without stalling the whole thread.
    PQsetnonblocking(conn, 1);
    return conn;
}

// Closes a raw connection. Connections owned by a native_pool_t*
// must NOT be closed here: pool_destroy handles all of them.
void close_db(PGconn *conn) {
    if (conn != NULL) PQfinish(conn);
}

/* ─────── Result inspection (ABI MAJOR 1.3+; invariante em MAJOR 2) ─────── */

int get_row_count(PGresult *result) {
    return PQntuples(result);
}

int get_col_count(PGresult *result) {
    return PQnfields(result);
}

const char *get_field_name(PGresult *result, int col) {
    return PQfname(result, col);
}

const unsigned char *get_raw_value(PGresult *result, int row, int col) {
    if (PQgetisnull(result, row, col)) return NULL;
    return (const unsigned char *)PQgetvalue(result, row, col);
}

int get_raw_length(PGresult *result, int row, int col) {
    if (PQgetisnull(result, row, col)) return 0;
    return PQgetlength(result, row, col);
}

unsigned int get_field_type(PGresult *result, int col) {
    return (unsigned int)PQftype(result, col);
}

/* ─────── Result status / error (ABI MINOR 2, 2026-07-28) ─────── */

int get_result_status(PGresult *result) {
    return (int)PQresultStatus(result);
}

const char *get_error_message(PGresult *result) {
    return PQresultErrorMessage(result);
}

/* ─────── Memory hygiene (ABI MAJOR 1.5+; invariante em MAJOR 2) ─────── */

void clear_result(PGresult *result) {
    if (result != NULL) PQclear(result);
}
