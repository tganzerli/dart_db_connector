/// Convenience helpers that wrap [MysqlUnitOfWork] lifecycle in a single
/// call. MySQL counterpart of `with_transaction.dart` (PostgreSQL).
///
/// Usage:
/// ```dart
/// final products = await withMysqlTransaction(pool, (exec) async {
///   final repo = ProductRepository(exec);
///   await repo.insert(product);
///   return await repo.findAll();
/// });
/// ```
library;

import '../pool/mysql_connection_pool.dart';
import 'mysql_query_executor.dart';
import 'mysql_unit_of_work.dart';

/// Runs [body] inside a new [MysqlUnitOfWork] on a connection acquired
/// from [pool]. Returns [body]'s value after a successful commit; rolls
/// back and rethrows on exception.
Future<T> withMysqlTransaction<T>(
  MysqlConnectionPool pool,
  Future<T> Function(MysqlQueryExecutor exec) body,
) {
  return withMysqlTransactionOn<T>(MysqlUnitOfWork(pool), body);
}

/// Same lifecycle as [withMysqlTransaction] but uses a pre-built [uow].
Future<T> withMysqlTransactionOn<T>(
  MysqlUnitOfWork uow,
  Future<T> Function(MysqlQueryExecutor exec) body,
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
