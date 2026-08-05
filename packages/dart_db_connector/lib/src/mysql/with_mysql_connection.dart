/// Non-transactional counterpart of [withMysqlTransaction]: runs a body on a
/// pooled MySQL connection WITHOUT opening a transaction.
///
/// Use this for read-only / autocommit work where a transaction's BEGIN +
/// COMMIT round-trips would be pure overhead. A single `SELECT` costs one
/// round-trip here versus three inside `withMysqlTransaction`. For atomicity
/// across statements, use [withMysqlTransaction] instead.
///
/// Usage:
/// ```dart
/// final row = await withMysqlConnection(pool, (exec) async {
///   final rs = await exec.execute('SELECT id FROM world WHERE id = 1');
///   try {
///     return rs.row(0).getInt('id');
///   } finally {
///     rs.release();
///   }
/// });
/// ```
library;

import '../pool/mysql_connection_pool.dart';
import 'mysql_query_executor.dart';

/// Runs [body] over a connection acquired from [pool], with no transaction,
/// and always releases the connection. Returns [body]'s value.
///
/// The [MysqlQueryExecutor] passed to [body] runs each statement in the
/// server's autocommit mode. Result sets read inside [body] must be fully
/// consumed (and `release()`d) before [body] returns — the connection goes
/// back to the pool on return.
Future<T> withMysqlConnection<T>(
  MysqlConnectionPool pool,
  Future<T> Function(MysqlQueryExecutor exec) body,
) async {
  final leased = await pool.acquire();
  try {
    return await body(MysqlQueryExecutor(pool.binding, leased.raw));
  } finally {
    await leased.release();
  }
}
