/// Per-isolate singleton holder for [SqliteBinding]. Mirror of
/// `MysqlSharedBinding`. Resolves lazily; each isolate gets its own
/// `native_sqlite_init_dart_api` before any native worker posts to a port.
library;

import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

import '../bindings/sqlite_binding.dart';
import '../native_lib_loader.dart';

@internal
class SqliteSharedBinding {
  static SqliteBinding? _instance;

  static SqliteBinding instance() {
    final cached = _instance;
    if (cached != null) return cached;

    final lib = loadNativeSqlite();
    final binding = SqliteBinding(lib);
    if (binding.initDartApi(ffi.NativeApi.initializeApiDLData) != 0) {
      throw StateError(
        'Failed to initialize Dart Native API for SQLite '
        '(native_sqlite_init_dart_api returned non-zero).',
      );
    }
    _instance = binding;
    return binding;
  }

  @visibleForTesting
  static void debugSet(SqliteBinding? binding) => _instance = binding;

  @visibleForTesting
  static bool get debugHasInstance => _instance != null;
}
