/// Cross-platform resolver for `libnative_db.{dylib,so,dll}`.
///
/// Walks a small list of canonical candidate paths so the consumer
/// does not need to know where the binary actually sits. The first
/// existing file wins.
///
/// The search order is — in priority:
///
/// 1. **`DART_DB_CONNECTOR_NATIVE_LIB_PATH` env var** (absolute
///    override). Useful for debugging, CI matrix runs, or pinning
///    a specific build during dev.
/// 2. **Near the executing binary** — two variants checked in order:
///    - `dirname(Platform.resolvedExecutable)/<fileName>` (flat: exe
///      and `.so` side by side; the simplest AOT layout).
///    - `dirname(Platform.resolvedExecutable)/lib/_native/<os>-<arch>/
///      <fileName>` (the pub-cache mirror: if a consumer `COPY`s the
///      `lib/` subtree from `~/.pub-cache/...` next to the exe, the
///      .so lives here). This is the layout the pre-built
///      releases produce.
///    Headless Docker deployments target either form.
/// 3. **Package URI `package:dart_db_connector/_native/<os>-<arch>/
///    <fileName>`** resolved via `Isolate.resolvePackageUriSync`.
///    This is how the pre-built binaries shipped with the package are
///    found. Works in JIT (`dart run`, `dart test`); silently no-ops in
///    AOT (where package_config.json is unavailable).
/// 4. **`/usr/local/lib/<fileName>`** — system-wide install on
///    Linux/macOS for ops teams that prefer global libraries.
/// 5. **Local build paths** (current working directory and CMake build
///    locations): `./<fileName>`, `./build/<fileName>`,
///    `./native/c/build/<fileName>`, `../native/c/build/<fileName>`.
///    Covers building the library from source with CMake, which is what
///    you do after cloning the repository, or on a platform with no
///    pre-built binary.
/// 6. If nothing matches: `StateError` listing every candidate tried,
///    plus the build command and a pointer to the `doctor` tool.
///
/// **Internal helper.** Consumers of `dart_db_connector` should not
/// call this directly — `PostgresConnectionPool` (and every other
/// public entry point) resolves the binding internally via the
/// per-isolate `SharedBinding` singleton. The function stays exported
/// within the package source tree because tests, the bench harness,
/// and the internal `IsolateWorkerPool` worker still need direct
/// access. The `@internal` annotation triggers an analyzer warning
/// if it leaks into external code.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show File, Platform;
import 'dart:isolate';

import 'package:meta/meta.dart';

import 'bindings/_abi_constants.dart';
import 'bindings/_mongo_abi_constants.dart';
import 'bindings/_mysql_abi_constants.dart';
import 'bindings/_sqlite_abi_constants.dart';
import 'bindings/abi_check.dart';
import 'bindings/mongo_abi_check.dart';
import 'bindings/mysql_abi_check.dart';
import 'bindings/sqlite_abi_check.dart';

/// Per-OS native library filenames for one driver's shared library.
typedef _LibNames = ({String macOS, String linux, String windows});

const _postgresNames = (
  macOS: 'libnative_db.dylib',
  linux: 'libnative_db.so',
  windows: 'native_db.dll',
);
const _mysqlNames = (
  macOS: 'libnative_mysql.dylib',
  linux: 'libnative_mysql.so',
  windows: 'native_mysql.dll',
);
const _mongoNames = (
  macOS: 'libnative_mongo.dylib',
  linux: 'libnative_mongo.so',
  windows: 'native_mongo.dll',
);
const _sqliteNames = (
  macOS: 'libnative_sqlite.dylib',
  linux: 'libnative_sqlite.so',
  windows: 'native_sqlite.dll',
);

const _envOverride = 'DART_DB_CONNECTOR_NATIVE_LIB_PATH';
const _mysqlEnvOverride = 'DART_DB_CONNECTOR_MYSQL_NATIVE_LIB_PATH';
const _mongoEnvOverride = 'DART_DB_CONNECTOR_MONGO_NATIVE_LIB_PATH';
const _sqliteEnvOverride = 'DART_DB_CONNECTOR_SQLITE_NATIVE_LIB_PATH';

@internal
ffi.DynamicLibrary loadNativeDb({
  String? overridePath,
  bool checkAbi = true,
}) {
  final lib =
      _openLibrary(_postgresNames, _envOverride, overridePath: overridePath);
  if (checkAbi) {
    assertAbiCompatible(
      lib,
      expectedMajor: kExpectedAbiMajor,
      expectedMinor: kExpectedAbiMinor,
    );
  }
  return lib;
}

/// MySQL counterpart of [loadNativeDb]. Resolves `libnative_mysql` via the
/// same candidate-path logic and validates its independent ABI
/// (`native_mysql_abi_version`).
@internal
ffi.DynamicLibrary loadNativeMysql({
  String? overridePath,
  bool checkAbi = true,
}) {
  final lib =
      _openLibrary(_mysqlNames, _mysqlEnvOverride, overridePath: overridePath);
  if (checkAbi) {
    assertMysqlAbiCompatible(
      lib,
      expectedMajor: kExpectedMysqlAbiMajor,
      expectedMinor: kExpectedMysqlAbiMinor,
    );
  }
  return lib;
}

/// MongoDB counterpart of [loadNativeDb]. Resolves `libnative_mongo` via the
/// same candidate-path logic and validates its independent ABI
/// (`native_mongo_abi_version`).
@internal
ffi.DynamicLibrary loadNativeMongo({
  String? overridePath,
  bool checkAbi = true,
}) {
  final lib =
      _openLibrary(_mongoNames, _mongoEnvOverride, overridePath: overridePath);
  if (checkAbi) {
    assertMongoAbiCompatible(
      lib,
      expectedMajor: kExpectedMongoAbiMajor,
      expectedMinor: kExpectedMongoAbiMinor,
    );
  }
  return lib;
}

/// SQLite counterpart of [loadNativeDb]. Resolves `libnative_sqlite` and
/// validates its independent ABI (`native_sqlite_abi_version`).
@internal
ffi.DynamicLibrary loadNativeSqlite({
  String? overridePath,
  bool checkAbi = true,
}) {
  final lib = _openLibrary(_sqliteNames, _sqliteEnvOverride,
      overridePath: overridePath);
  if (checkAbi) {
    assertSqliteAbiCompatible(
      lib,
      expectedMajor: kExpectedSqliteAbiMajor,
      expectedMinor: kExpectedSqliteAbiMinor,
    );
  }
  return lib;
}

ffi.DynamicLibrary _openLibrary(
  _LibNames names,
  String envOverride, {
  String? overridePath,
}) {
  // Path #1 — explicit override via argument (also accepted from env
  // when no argument is supplied).
  final pathFromArg = overridePath;
  if (pathFromArg != null) {
    return ffi.DynamicLibrary.open(pathFromArg);
  }
  final pathFromEnv = Platform.environment[envOverride];
  if (pathFromEnv != null && pathFromEnv.isNotEmpty) {
    return ffi.DynamicLibrary.open(pathFromEnv);
  }

  final fileName = _libraryFileName(names);
  final candidates = <String>[];

  // Path #2 — near the executing binary. Two variants checked in
  // order: flat (`<exe-dir>/<fileName>`) and the pub-cache mirror
  // (`<exe-dir>/lib/_native/<os>-<arch>/<fileName>`).
  final platformId = _platformIdentifier();
  final exeDir = _executableDirectory();
  if (exeDir != null) {
    candidates.add('$exeDir/$fileName');
    candidates.add('$exeDir/lib/_native/$platformId/$fileName');
  }

  // Path #3 — package URI for the bundled native asset. This is how the
  // binaries shipped with the published package are found.
  // `resolvePackageUriSync` returns null when the package config isn't
  // available (AOT mode, shipped binaries, etc).
  final pkgPath = _resolvePackageNativeLibPath(platformId, fileName);
  if (pkgPath != null) {
    candidates.add(pkgPath);
  }

  // Path #4 — system-wide install (Linux/macOS).
  if (!Platform.isWindows) {
    candidates.add('/usr/local/lib/$fileName');
  }

  // Path #5 — local build paths, for the CMake build cycle inside a
  // clone of the repository.
  candidates.addAll([
    fileName,
    'build/$fileName',
    'native/c/build/$fileName',
    '../native/c/build/$fileName',
  ]);

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return ffi.DynamicLibrary.open(candidate);
    }
  }

  throw StateError(
    'Native library "$fileName" not found in any of:\n  '
    '${candidates.join("\n  ")}\n\n'
    'Two ways to resolve, in priority order:\n'
    ' (a) Set $envOverride=/abs/path/to/$fileName, or\n'
    ' (b) Build the library from source:\n'
    '       cmake -S native/c -B native/c/build\n'
    '       cmake --build native/c/build\n\n'
    'Pre-built binaries ship at lib/_native/<platform>/ for linux-x64, '
    'linux-arm64, macos-x64 and macos-arm64. This platform '
    '($platformId) has none, so build from source. Run '
    '`dart run dart_db_connector:doctor` to check every driver at once.',
  );
}

String _libraryFileName(_LibNames names) {
  if (Platform.isMacOS) return names.macOS;
  if (Platform.isLinux) return names.linux;
  if (Platform.isWindows) return names.windows;
  throw UnsupportedError(
    'Unsupported OS: ${Platform.operatingSystem}. '
    'Supported: macOS, Linux, Windows.',
  );
}

/// Returns the directory of the executing Dart process when that
/// matches a real filesystem location. Returns null when the
/// executable path is not informative (e.g. inside the Dart VM
/// running through `dart run` where it points to `dart` itself).
String? _executableDirectory() {
  try {
    final exe = Platform.resolvedExecutable;
    if (exe.isEmpty) return null;
    final lastSep = exe.lastIndexOf(Platform.pathSeparator);
    if (lastSep <= 0) return null;
    return exe.substring(0, lastSep);
  } catch (_) {
    return null;
  }
}

/// Resolves `package:dart_db_connector/_native/<os>-<arch>/<fileName>`
/// to a real file path via the current isolate's package config.
/// Returns null when the package config is unavailable (AOT mode) or
/// when the URI cannot be resolved (the file might not exist yet —
/// the resolver checks `File.existsSync` afterwards).
String? _resolvePackageNativeLibPath(String platformId, String fileName) {
  try {
    final uri = Uri.parse(
      'package:dart_db_connector/_native/$platformId/$fileName',
    );
    final resolved = Isolate.resolvePackageUriSync(uri);
    return resolved?.toFilePath();
  } catch (_) {
    return null;
  }
}

/// Identifies the running platform with the convention used inside
/// `lib/_native/<id>/`. Examples: `macos-arm64`, `linux-x64`,
/// `windows-x64`. Detection uses `Platform.version` which carries
/// the architecture suffix (`... on "macos_arm64"`); falls back to
/// a Process call if the parse fails.
@visibleForTesting
String detectPlatformId() => _platformIdentifier();

String _platformIdentifier() {
  final os = Platform.isMacOS
      ? 'macos'
      : Platform.isLinux
          ? 'linux'
          : Platform.isWindows
              ? 'windows'
              : Platform.operatingSystem;
  final arch = _detectArch();
  return '$os-$arch';
}

/// Best-effort architecture detection. Reads `Platform.version` which
/// embeds the host architecture suffix (`... on "<os>_<arch>"`).
/// Returns `'unknown'` when the parse fails — the caller should treat
/// path #3 as a soft miss in that case.
String _detectArch() {
  try {
    final version = Platform.version;
    // version example: '3.11.6 (stable) (...) on "macos_arm64"'
    final match = RegExp(r'on "[^_"]+_([^"]+)"').firstMatch(version);
    if (match != null) {
      final raw = match.group(1)!;
      // Normalise to the conventional names used by the
      // `lib/_native/<os>-<arch>/` layout.
      return switch (raw) {
        'arm64' => 'arm64',
        'x64' || 'x86_64' || 'amd64' => 'x64',
        'ia32' || 'x86' => 'ia32',
        _ => raw,
      };
    }
  } catch (_) {
    // fall through
  }
  return 'unknown';
}
