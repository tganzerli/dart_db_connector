/// ABI versions expected by this Dart package for the MySQL driver.
///
/// MUST match the macros in `native/c/include/native_mysql.h`:
///   - NATIVE_MYSQL_ABI_VERSION_MAJOR
///   - NATIVE_MYSQL_ABI_VERSION_MINOR
///
/// Independent of the PostgreSQL ABI (`_abi_constants.dart`): the MySQL
/// native library `libnative_mysql` is versioned separately. Same
/// validation policy :
///   - MAJOR mismatch                    -> fatal (StateError)
///   - linked.MINOR >= expected.MINOR    -> OK (forward-compat)
///   - linked.MINOR <  expected.MINOR    -> warning (non-blocking)
library;

/// Expected major version (breaking changes).
///
/// Born at 1 in 2026-07-24. New, independent ABI family — no
/// MAJOR 0 pre-history, unlike libnative_db..
const int kExpectedMysqlAbiMajor = 1;

/// Expected minor version (additive non-breaking changes). Reset on each
/// MAJOR bump per the ABI stability policy.
///
/// 0 → 1 (2026-07-27): `mysql_pool_submit_batch` (multi-statement write
/// batching). 1 → 2 (2026-07-27): `mysql_pool_submit_multi_read` (N reads in
/// one round-trip, N result sets chained). 2 → 3 (2026-08-03):
/// `native_mysql_last_errno` / `native_mysql_last_error` (surface the real
/// libmysqlclient error;. Legacy
/// paths preserved.
const int kExpectedMysqlAbiMinor = 3;
