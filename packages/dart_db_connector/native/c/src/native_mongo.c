/// native_mongo.c — ABI/version shims and result access for
/// libnative_mongo. Mirrors `native_mysql.c` but over BSON document
/// buffers: a result wrapper owns a copy of one BSON document, which Dart
/// views zero-copy (`asTypedList`) and parses on its side.

#include "native_mongo.h"

#include <stdint.h>
#include <stdlib.h>

#include "dart/dart_api_dl.h"
#include "mongo_pool_internal.h"

// Returns the ABI version packed as ((int64_t)MAJOR << 32) | MINOR.
// Consumed by Dart in dart/lib/src/bindings/mongo_abi_check.dart.
int64_t native_mongo_abi_version(void) {
    return ((int64_t)NATIVE_MONGO_ABI_VERSION_MAJOR << 32)
         | (int64_t)NATIVE_MONGO_ABI_VERSION_MINOR;
}

// Initializes the Dart Native API. Distinct symbol from the PostgreSQL and
// MySQL libs' init functions so all three can be loaded in one process.
intptr_t native_mongo_init_dart_api(void* data) {
    return Dart_InitializeApiDL(data);
}

/* ─────── Result access (zero-copy view of a BSON document) ─────── */

const uint8_t* native_mongo_result_data(native_mongo_result_t* result) {
    if (result == NULL) return NULL;
    return result->data;
}

int32_t native_mongo_result_length(native_mongo_result_t* result) {
    if (result == NULL) return 0;
    return result->len;
}

/* ─────── Memory hygiene ─────── */

void native_mongo_clear_result(native_mongo_result_t* result) {
    if (result == NULL) return;
    free(result->data);
    free(result);
}
