/// Runtime ABI validation between the loaded `libnative_sqlite` and this
/// Dart package. Mirrors the other drivers' checks
/// : MAJOR mismatch → StateError;
/// linked MINOR < expected → warning.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show stderr;

typedef _AbiVersionNative = ffi.Int64 Function();
typedef _AbiVersionDart = int Function();

const int _kAbiMajorShift = 32;
const int _k32BitMask = 0xFFFFFFFF;

({int major, int minor}) assertSqliteAbiCompatible(
  ffi.DynamicLibrary lib, {
  required int expectedMajor,
  required int expectedMinor,
}) {
  final fn = lib.lookupFunction<_AbiVersionNative, _AbiVersionDart>(
      'native_sqlite_abi_version');
  final packed = fn();
  final major = (packed >> _kAbiMajorShift) & _k32BitMask;
  final minor = packed & _k32BitMask;

  if (major != expectedMajor) {
    throw StateError(
      'SQLite ABI mismatch: native library reports MAJOR=$major MINOR=$minor, '
      'but Dart package expects MAJOR=$expectedMajor MINOR=$expectedMinor. '
      'MAJOR mismatch is FATAL — rebuild native/c/ or update the Dart '
      'package (kExpectedSqliteAbiMajor in '
      'dart/lib/src/bindings/_sqlite_abi_constants.dart).',
    );
  }
  if (minor < expectedMinor) {
    stderr.writeln(
      '[dart_db_connector] WARNING: linked libnative_sqlite reports '
      'MINOR=$minor but Dart package expects MINOR>=$expectedMinor.',
    );
  }
  return (major: major, minor: minor);
}
