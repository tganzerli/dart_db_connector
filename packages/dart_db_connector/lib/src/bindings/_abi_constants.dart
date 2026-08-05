/// ABI versions expected by this Dart package.
///
/// MUST match the macros in `native/c/include/native_db.h`:
///   - NATIVE_DB_ABI_VERSION_MAJOR
///   - NATIVE_DB_ABI_VERSION_MINOR
///
/// Validation policy :
///   - MAJOR mismatch                    -> fatal (StateError)
///   - linked.MINOR >= expected.MINOR    -> OK (forward-compat)
///   - linked.MINOR <  expected.MINOR    -> warning (non-blocking)
///
/// TODO: regenerate from native_db.h via codegen step (out of scope for
/// this task). For now, keep in sync manually whenever the C macros bump.
library;

/// Expected major version (breaking changes).
///
/// 1 → 2 in 2026-05-20: native thread/conn pool (approach B). Removed
/// `start_query_async`, `start_pipeline_async`, and
/// `cancel_query(PGconn*)`; added pool primitives (`pool_create`,
/// `pool_acquire`, `pool_release`, `pool_submit_query`,
/// `pool_submit_pipeline`, `pool_cancel`, `pool_destroy`);
/// `poll_result` first param changed from `PGconn*` to
/// `native_conn_t*`..
const int kExpectedAbiMajor = 2;

/// Expected minor version (additive non-breaking changes). Reset on
/// each MAJOR bump per the ABI stability policy.
///
/// 0 → 1 in 2026-05-23: added `pool_submit_query_params` (Extended Query
/// Protocol via libpq `PQsendQueryParams`). Legacy `pool_submit_query`
/// (Simple Protocol) preserved unchanged..
///
/// 1 → 2 in 2026-07-28: added `pool_submit_multi_read` (N read
/// statements in one round-trip, results preserved as a per-conn chain)
/// plus `get_result_status` / `get_error_message` (real server error of
/// a PGresult). Legacy paths preserved unchanged..
const int kExpectedAbiMinor = 2;
