/// Postgres connection info, configurable via env vars.
///
/// Used by all bench scripts so the same fixtures + harness work both
/// from macOS host (default localhost) and from inside a Docker
/// container (POSTGRES_HOST=postgres). No code change needed across
/// environments — just env vars on the runner.
library;

import 'dart:io';

String connInfo() {
  final host = Platform.environment['POSTGRES_HOST'] ?? 'localhost';
  final port = Platform.environment['POSTGRES_PORT'] ?? '5432';
  final db = Platform.environment['POSTGRES_DB'] ?? 'teste';
  final user = Platform.environment['POSTGRES_USER'] ?? 'postgres';
  final password = Platform.environment['POSTGRES_PASSWORD'] ?? '123';
  return 'host=$host port=$port dbname=$db user=$user password=$password';
}

/// Same info, but for the `postgres` Dart package which uses a typed
/// `Endpoint` struct rather than a conninfo string.
({String host, int port, String database, String username, String password})
    endpoint() {
  return (
    host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
    port: int.parse(Platform.environment['POSTGRES_PORT'] ?? '5432'),
    database: Platform.environment['POSTGRES_DB'] ?? 'teste',
    username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
    password: Platform.environment['POSTGRES_PASSWORD'] ?? '123',
  );
}
