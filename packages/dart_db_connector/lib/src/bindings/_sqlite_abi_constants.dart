/// ABI versions expected by this Dart package for the SQLite driver.
///
/// MUST match the macros in `native/c/include/native_sqlite.h`:
///   - NATIVE_SQLITE_ABI_VERSION_MAJOR
///   - NATIVE_SQLITE_ABI_VERSION_MINOR
///
/// Independent of the PostgreSQL/MySQL/MongoDB ABIs: `libnative_sqlite` is
/// versioned separately. Same validation policy : MAJOR mismatch fatal, lower linked
/// MINOR a non-blocking warning.
library;

/// Expected major version. Born at 1 in 2026-07-27..
const int kExpectedSqliteAbiMajor = 1;

/// Expected minor version (additive non-breaking changes).
///
/// 0 → 1 (2026-07-27): `sqlite_pool_submit_batch` + `sqlite_pool_submit_multi_read`
/// (N statements per round-trip). 1 → 2 (2026-07-27): `sqlite_conn_exec_sync`
/// (synchronous fast-path for light queries).
const int kExpectedSqliteAbiMinor = 2;
