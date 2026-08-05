/// Convenience helpers wrapping [SqliteUnitOfWork] lifecycle. Mirror of
/// `with_mysql_transaction.dart`.
library;

import '../pool/sqlite_connection_pool.dart';
import 'sqlite_query_executor.dart';
import 'sqlite_unit_of_work.dart';

/// Runs [body] inside a new [SqliteUnitOfWork] on a connection from [pool].
/// Commits on success; rolls back and rethrows on error.
Future<T> withSqliteTransaction<T>(
  SqliteConnectionPool pool,
  Future<T> Function(SqliteQueryExecutor exec) body,
) {
  return withSqliteTransactionOn<T>(SqliteUnitOfWork(pool), body);
}

Future<T> withSqliteTransactionOn<T>(
  SqliteUnitOfWork uow,
  Future<T> Function(SqliteQueryExecutor exec) body,
) async {
  await uow.begin();
  try {
    final result = await body(uow.executor);
    await uow.commit();
    return result;
  } catch (_) {
    await uow.rollback();
    rethrow;
  } finally {
    await uow.close();
  }
}
