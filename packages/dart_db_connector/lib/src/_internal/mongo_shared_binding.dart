/// Per-isolate singleton holder for [MongoBinding].
///
/// Mirror of `MysqlSharedBinding` for the MongoDB driver. Resolves the
/// binding lazily on first call; each isolate gets its own instance and its
/// own one-time `Dart_InitializeApiDL` (via `native_mongo_init_dart_api`),
/// which must happen exactly once per isolate before any
/// `Dart_PostCObject_DL` from a native worker thread.
///
/// Marked `@internal` so external consumers depend only on
/// `MongoConnectionPool` and the public surface.
library;

import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

import '../bindings/mongo_binding.dart';
import '../native_lib_loader.dart';

@internal
class MongoSharedBinding {
  static MongoBinding? _instance;

  /// Resolves the per-isolate singleton [MongoBinding]. Idempotent. The
  /// first call locates+opens `libnative_mongo`, validates the ABI (MAJOR
  /// mismatch fatal), and calls `native_mongo_init_dart_api`.
  static MongoBinding instance() {
    final cached = _instance;
    if (cached != null) return cached;

    final lib = loadNativeMongo();
    final binding = MongoBinding(lib);
    if (binding.initDartApi(ffi.NativeApi.initializeApiDLData) != 0) {
      throw StateError(
        'Failed to initialize Dart Native API for MongoDB '
        '(native_mongo_init_dart_api returned non-zero). '
        'This is unrecoverable in the current isolate.',
      );
    }
    _instance = binding;
    return binding;
  }

  /// Replaces the cached instance — strictly for tests. Pass `null` to
  /// clear the cache (next [instance] call re-resolves).
  @visibleForTesting
  static void debugSet(MongoBinding? binding) {
    _instance = binding;
  }

  /// Whether a binding has already been resolved in this isolate.
  @visibleForTesting
  static bool get debugHasInstance => _instance != null;
}
