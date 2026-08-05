/// native_mysql.c — Result inspection + ABI/version shims for
/// libnative_mysql. Mirrors `native_db.c` (PostgreSQL) but over
/// libmysqlclient's `MYSQL_RES` API, wrapped in `native_mysql_result_t`
/// so random-access cell reads stay zero-copy (see mysql_pool_internal.h).

#include "native_mysql.h"

#include <mysql.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include "dart/dart_api_dl.h"
#include "mysql_pool_internal.h"

// Returns the ABI version packed as ((int64_t)MAJOR << 32) | MINOR.
// Consumed by Dart in dart/lib/src/bindings/mysql_abi_check.dart.
int64_t native_mysql_abi_version(void) {
    return ((int64_t)NATIVE_MYSQL_ABI_VERSION_MAJOR << 32)
         | (int64_t)NATIVE_MYSQL_ABI_VERSION_MINOR;
}

// Initializes the Dart Native API. Distinct symbol from the PostgreSQL
// lib's InitDartApiDL so both libs can be loaded in one process.
intptr_t native_mysql_init_dart_api(void* data) {
    return Dart_InitializeApiDL(data);
}

/* ─────── Error surfacing (ABI MINOR 3) ─────── */

// Last libmysqlclient error code captured on `conn` by the worker at the
// moment a query aborted. 0 if the last statement succeeded (the field is
// reset before each statement). Valid until the next query on this conn.
unsigned int native_mysql_last_errno(mysql_conn_t* conn) {
    if (conn == NULL) return 0;
    return conn->last_errno;
}

// Last libmysqlclient error message captured on `conn` by the worker at the
// moment a query aborted. Empty string if the last statement succeeded.
// Pointer valid until the next query on this conn — DO NOT free.
const char* native_mysql_last_error(mysql_conn_t* conn) {
    if (conn == NULL) return "";
    return conn->last_error;
}

/* ─────── Result inspection (zero-copy reads) ─────── */

int native_mysql_row_count(native_mysql_result_t* result) {
    if (result == NULL || result->res == NULL) return 0;
    return (int)mysql_num_rows(result->res);
}

int native_mysql_col_count(native_mysql_result_t* result) {
    if (result == NULL || result->res == NULL) return 0;
    return result->col_count;
}

int64_t native_mysql_affected_rows(native_mysql_result_t* result) {
    if (result == NULL) return 0;
    return result->affected_rows;
}

const char* native_mysql_field_name(native_mysql_result_t* result, int col) {
    if (result == NULL || result->res == NULL) return NULL;
    if (col < 0 || col >= result->col_count) return NULL;
    MYSQL_FIELD* f = mysql_fetch_field_direct(result->res, (unsigned int)col);
    return (f != NULL) ? f->name : NULL;
}

// Advances the wrapper's one-row cache to `row` if needed. Returns 0 on
// success (cache now holds `row`), -1 on failure (no result / bad index /
// fetch failed). `mysql_data_seek` is O(1) on a stored result.
static int ensure_row(native_mysql_result_t* result, int64_t row) {
    if (result == NULL || result->res == NULL) return -1;
    if (row < 0 || row >= (int64_t)mysql_num_rows(result->res)) return -1;
    if (result->cached_row == row && result->row != NULL) return 0;

    mysql_data_seek(result->res, (my_ulonglong)row);
    result->row = mysql_fetch_row(result->res);
    result->lengths = mysql_fetch_lengths(result->res);
    result->cached_row = (result->row != NULL) ? row : -1;
    return (result->row != NULL) ? 0 : -1;
}

const unsigned char* native_mysql_raw_value(native_mysql_result_t* result,
                                            int row, int col) {
    if (ensure_row(result, row) != 0) return NULL;
    if (col < 0 || col >= result->col_count) return NULL;
    // row[col] is NULL for SQL NULL — passed through as NULL to Dart.
    return (const unsigned char*)result->row[col];
}

int native_mysql_raw_length(native_mysql_result_t* result, int row, int col) {
    if (ensure_row(result, row) != 0) return 0;
    if (col < 0 || col >= result->col_count) return 0;
    if (result->row[col] == NULL) return 0;      // SQL NULL
    return (int)result->lengths[col];
}

int native_mysql_field_type(native_mysql_result_t* result, int col) {
    if (result == NULL || result->res == NULL) return 0;
    if (col < 0 || col >= result->col_count) return 0;
    MYSQL_FIELD* f = mysql_fetch_field_direct(result->res, (unsigned int)col);
    return (f != NULL) ? (int)f->type : 0;
}

/* ─────── Memory hygiene ─────── */

void native_mysql_clear_result(native_mysql_result_t* result) {
    if (result == NULL) return;
    if (result->res != NULL) mysql_free_result(result->res);
    free(result);
}
