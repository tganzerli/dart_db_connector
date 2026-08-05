/// Runtime ABI validation between the loaded `libnative_mysql` library and
/// this Dart package.
///
/// Calls the C function `native_mysql_abi_version()` and compares the
/// result against [kExpectedMysqlAbiMajor] / [kExpectedMysqlAbiMinor],
/// following the same policy as the PostgreSQL check
/// :
///
///   - MAJOR mismatch                       -> throw StateError (fatal)
///   - linked MINOR >= expected MINOR       -> OK (forward-compat)
///   - linked MINOR <  expected MINOR       -> warn on stderr (non-blocking)
///
/// Governed by the ABI stability policy in CONTRIBUTING.md. Any change here
/// must be paired with `native/c/include/native_mysql.h`.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show stderr;

typedef _AbiVersionNative = ffi.Int64 Function();
typedef _AbiVersionDart = int Function();

const int _kAbiMajorShift = 32;
const int _k32BitMask = 0xFFFFFFFF;

/// Reads `native_mysql_abi_version()` from [lib] and compares against the
/// expected major/minor. Throws [StateError] on MAJOR mismatch. Returns a
/// `(major, minor)` record of the linked library.
({int major, int minor}) assertMysqlAbiCompatible(
  ffi.DynamicLibrary lib, {
  required int expectedMajor,
  required int expectedMinor,
}) {
  final fn = lib.lookupFunction<_AbiVersionNative, _AbiVersionDart>(
      'native_mysql_abi_version');
  final packed = fn();
  final major = (packed >> _kAbiMajorShift) & _k32BitMask;
  final minor = packed & _k32BitMask;

  if (major != expectedMajor) {
    throw StateError(
      'MySQL ABI mismatch: native library reports MAJOR=$major MINOR=$minor, '
      'but Dart package expects MAJOR=$expectedMajor MINOR=$expectedMinor. '
      'MAJOR mismatch is FATAL — rebuild native/c/ or update the Dart '
      'package (kExpectedMysqlAbiMajor in '
      'dart/lib/src/bindings/_mysql_abi_constants.dart).',
    );
  }

  if (minor < expectedMinor) {
    stderr.writeln(
      '[dart_db_connector] WARNING: linked libnative_mysql reports '
      'MINOR=$minor but Dart package expects MINOR>=$expectedMinor. '
      'Some features may be unavailable; consider rebuilding native/c/.',
    );
  }

  return (major: major, minor: minor);
}
