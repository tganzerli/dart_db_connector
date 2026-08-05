/// Generic SQLite [Repository] base. Mirror of `mysql_repository.dart`,
/// Tier 1 (string SQL). Subclasses provide the five CRUD statements and a
/// `fromRow` mapper. Cross-driver: `Repository<T,K>` is REUSED (agnostic); the
/// executor/UoW are duplicated.
///
/// SECURITY (v1): no bound-parameter path yet; subclasses that inline
/// external input MUST escape it.
library;

import '../decoder/sqlite_result_row.dart';
import '../domain/repository.dart';
import 'sqlite_query_executor.dart';

abstract class SqliteRepository<T, K> implements Repository<T, K> {
  final SqliteQueryExecutor _exec;
  final T Function(SqliteResultRow) _fromRow;

  SqliteRepository(this._exec, this._fromRow);

  String get tableName;
  String get idColumn;

  String selectAllSql();
  String selectByIdSql(K id);
  String insertSql(T entity);
  String updateSql(T entity);
  String deleteSql(K id);

  @override
  Future<List<T>> findAll() async {
    final rs = await _exec.execute(selectAllSql());
    try {
      return [for (final row in rs.rows) _fromRow(row)];
    } finally {
      rs.release();
    }
  }

  @override
  Future<T?> findById(K id) async {
    final rs = await _exec.execute(selectByIdSql(id));
    try {
      if (rs.rowCount == 0) return null;
      return _fromRow(rs.row(0));
    } finally {
      rs.release();
    }
  }

  @override
  Future<void> insert(T entity) async {
    (await _exec.execute(insertSql(entity))).release();
  }

  @override
  Future<void> update(T entity) async {
    (await _exec.execute(updateSql(entity))).release();
  }

  @override
  Future<void> delete(K id) async {
    (await _exec.execute(deleteSql(id))).release();
  }
}
