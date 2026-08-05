/// ABI versions expected by this Dart package for the MongoDB driver.
///
/// MUST match the macros in `native/c/include/native_mongo.h`:
///   - NATIVE_MONGO_ABI_VERSION_MAJOR
///   - NATIVE_MONGO_ABI_VERSION_MINOR
///
/// Independent of the PostgreSQL (`_abi_constants.dart`) and MySQL
/// (`_mysql_abi_constants.dart`) ABIs: `libnative_mongo` is versioned
/// separately. Same validation policy :
///   - MAJOR mismatch                    -> fatal (StateError)
///   - linked.MINOR >= expected.MINOR    -> OK (forward-compat)
///   - linked.MINOR <  expected.MINOR    -> warning (non-blocking)
library;

/// Expected major version (breaking changes).
///
/// Born at 1 in 2026-07-27. New, independent ABI family..
const int kExpectedMongoAbiMajor = 1;

/// Expected minor version (additive non-breaking changes). Reset on each
/// MAJOR bump per the ABI stability policy.
///
/// 1 since 2026-07-28: adds `mongo_pool_submit_insert_many`
/// (bulk write)..
const int kExpectedMongoAbiMinor = 1;
