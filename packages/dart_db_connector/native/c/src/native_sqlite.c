/// native_sqlite.c — ABI/version shims and result inspection for
/// libnative_sqlite. The result is materialised (owned cell buffers), so
/// reads are zero-copy over that buffer.

#include "native_sqlite.h"

#include <stdint.h>
#include <stdlib.h>

#include "dart/dart_api_dl.h"
#include "sqlite_pool_internal.h"

int64_t native_sqlite_abi_version(void) {
    return ((int64_t)NATIVE_SQLITE_ABI_VERSION_MAJOR << 32)
         | (int64_t)NATIVE_SQLITE_ABI_VERSION_MINOR;
}

intptr_t native_sqlite_init_dart_api(void* data) {
    return Dart_InitializeApiDL(data);
}

/* ─────── Result inspection (zero-copy over the owned buffer) ─────── */

int native_sqlite_row_count(native_sqlite_result_t* result) {
    return (result == NULL) ? 0 : (int)result->row_count;
}

int native_sqlite_col_count(native_sqlite_result_t* result) {
    return (result == NULL) ? 0 : result->col_count;
}

int64_t native_sqlite_affected_rows(native_sqlite_result_t* result) {
    return (result == NULL) ? 0 : result->affected_rows;
}

const char* native_sqlite_col_name(native_sqlite_result_t* result, int col) {
    if (result == NULL || result->col_names == NULL) return NULL;
    if (col < 0 || col >= result->col_count) return NULL;
    return result->col_names[col];
}

static int64_t cell_index(native_sqlite_result_t* r, int row, int col) {
    return (int64_t)row * r->col_count + col;
}

static int cell_ok(native_sqlite_result_t* r, int row, int col) {
    return r != NULL && row >= 0 && (int64_t)row < r->row_count &&
           col >= 0 && col < r->col_count;
}

int native_sqlite_cell_type(native_sqlite_result_t* result, int row, int col) {
    if (!cell_ok(result, row, col)) return 5; // SQLITE_NULL
    return result->cell_types[cell_index(result, row, col)];
}

const unsigned char* native_sqlite_raw_value(native_sqlite_result_t* result,
                                             int row, int col) {
    if (!cell_ok(result, row, col)) return NULL;
    return (const unsigned char*)result->cell_data[cell_index(result, row, col)];
}

int native_sqlite_raw_length(native_sqlite_result_t* result, int row, int col) {
    if (!cell_ok(result, row, col)) return 0;
    return result->cell_lens[cell_index(result, row, col)];
}

/* ─────── Memory hygiene ─────── */

void native_sqlite_clear_result(native_sqlite_result_t* result) {
    if (result == NULL) return;
    int64_t total = result->row_count * result->col_count;
    if (result->cell_data != NULL) {
        for (int64_t i = 0; i < total; i++) free(result->cell_data[i]);
    }
    free(result->cell_data);
    free(result->cell_types);
    free(result->cell_lens);
    if (result->col_names != NULL) {
        for (int c = 0; c < result->col_count; c++) free(result->col_names[c]);
        free(result->col_names);
    }
    free(result);
}
