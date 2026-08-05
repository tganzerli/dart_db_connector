/// Diagnostic: reports whether each driver's native library can be found and
/// loaded on this machine, and whether its ABI matches what this package
/// expects.
///
/// Run it when a driver fails to load:
///
///     dart run dart_db_connector:doctor
///
/// A failure points at one of three things: this platform has no pre-built
/// binary (build from source, see the README), the database client library is
/// not installed, or the native library is older than this package.
library;

import 'dart:io';

import 'package:dart_db_connector/src/native_lib_loader.dart';

void main() {
  stdout.writeln('dart_db_connector doctor');
  stdout.writeln('  os   : ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}');
  stdout.writeln('  dart : ${Platform.version.split(' ').first}');
  stdout.writeln('');

  final probes = <String, void Function()>{
    'postgres': loadNativeDb,
    'mysql': loadNativeMysql,
    'mongo': loadNativeMongo,
    'sqlite': loadNativeSqlite,
  };

  var failed = 0;
  probes.forEach((name, load) {
    try {
      load();
      stdout.writeln('  $name: loaded, ABI OK');
    } catch (e) {
      failed++;
      stdout.writeln('  $name: FAILED');
      stdout.writeln('      ${e.toString().split('\n').first}');
    }
  });

  stdout.writeln('');
  if (failed == 0) {
    stdout.writeln('All drivers loaded.');
  } else {
    stdout.writeln('$failed driver(s) failed to load. Loading is lazy, so a '
        'driver you never touch can be ignored.');
    exitCode = 1;
  }
}
