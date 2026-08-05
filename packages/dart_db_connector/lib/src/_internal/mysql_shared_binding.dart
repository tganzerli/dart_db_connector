/// Per-isolate singleton holder for [MysqlBinding].
///
/// Mirror of `SharedBinding` (PostgreSQL) for the MySQL driver. Resolves
/// the binding lazily on first call; each isolate gets its own instance
/// and its own one-time `Dart_InitializeApiDL` (via
/// `native_mysql_init_dart_api`), which must happen exactly once per
/// isolate before any `Dart_PostCObject_DL` from a native worker thread.
///
/// Marked `@internal` so external consumers don't depend on the helper —
/// they should only touch `MysqlConnectionPool` and the public surface.
library;

import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

import '../bindings/mysql_binding.dart';
import '../native_lib_loader.dart';

@internal
class MysqlSharedBinding {
  static MysqlBinding? _instance;

  /// Resolves the per-isolate singleton [MysqlBinding].
  ///
  /// Idempotent. The first call: locates+opens `libnative_mysql`,
  /// validates the ABI (MAJOR mismatch fatal), and calls
  /// `native_mysql_init_dart_api` so native threads can post to Dart
  /// Native Ports.
  static MysqlBinding instance() {
    final cached = _instance;
    if (cached != null) return cached;

    final lib = loadNativeMysql();
    final binding = MysqlBinding(lib);
    if (binding.initDartApi(ffi.NativeApi.initializeApiDLData) != 0) {
      throw StateError(
        'Failed to initialize Dart Native API for MySQL '
        '(native_mysql_init_dart_api returned non-zero). '
        'This is unrecoverable in the current isolate.',
      );
    }
    _instance = binding;
    return binding;
  }

  /// Replaces the cached instance — strictly for tests. Pass `null` to
  /// clear the cache (next [instance] call re-resolves).
  @visibleForTesting
  static void debugSet(MysqlBinding? binding) {
    _instance = binding;
  }

  /// Whether a binding has already been resolved in this isolate.
  @visibleForTesting
  static bool get debugHasInstance => _instance != null;
}
