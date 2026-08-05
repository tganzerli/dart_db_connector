/// Generic MySQL [Repository] base.
///
/// MySQL counterpart of `postgres_repository.dart`, Tier 1 only: concrete
/// subclasses provide string SQL for the five CRUD operations and a
/// `fromRow` mapper. MySQL v1 has no bound-parameter path (the native ABI
/// is simple-protocol only), so there is no Tier 2 `*SqlParams` family;
/// values are inlined into SQL by the subclass.
///
/// SECURITY NOTE (v1 limitation, documented for honesty): because there
/// is no parameter-binding path yet, subclasses that inline external
/// input MUST escape it themselves. This mirrors the PostgreSQL v1 stage
/// before the Extended Query Protocol landed. A future MINOR can add a
/// prepared-statement path.
library;

import '../decoder/mysql_result_row.dart';
import '../domain/repository.dart';
import 'mysql_query_executor.dart';

/// Base class for MySQL-backed [Repository]s. Subclasses override the
/// five string-SQL methods and pass a [MysqlResultRow] → entity mapper.
///
/// Example:
/// ```dart
/// class CounterRepository extends MysqlRepository<Counter, int> {
///   CounterRepository(MysqlQueryExecutor exec) : super(exec, _fromRow);
///   @override String get tableName => 'counter';
///   @override String get idColumn => 'id';
///   @override String selectAllSql() => 'SELECT id, value FROM counter';
///   @override String selectByIdSql(int id) =>
///       'SELECT id, value FROM counter WHERE id = $id';
///   // ... insert/update/delete
/// }
/// ```
abstract class MysqlRepository<T, K> implements Repository<T, K> {
  final MysqlQueryExecutor _exec;
  final T Function(MysqlResultRow) _fromRow;

  MysqlRepository(this._exec, this._fromRow);

  /// Table the repository targets (diagnostics; SQL is in the overrides).
  String get tableName;

  /// Primary-key column (diagnostics; concrete SQL references it).
  String get idColumn;

  // ── Tier 1: string-only (required) ──

  String selectAllSql();
  String selectByIdSql(K id);
  String insertSql(T entity);
  String updateSql(T entity);
  String deleteSql(K id);

  // ── CRUD impl ──

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
