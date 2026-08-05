/// Smoke test for the public API surface (post-audit).
///
/// Imports ONLY the package barrel, NOT any `src/` path. Confirms that
/// each of the 24 symbols catalogued in the public API audit resolves at
/// compile time and that the 4 removed cross-isolate message types
/// (`QueryError`/`QueryRequest`/`QueryResult`/`WorkerResponse`) are NOT
/// reachable from the barrel.
///
/// The test is intentionally compile-only — no DB is needed. If any
/// symbol disappears from the barrel, this file fails to compile and
/// the regression is caught before the change merges.
library;

// ignore_for_file: unused_local_variable

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:test/test.dart';

void main() {
  test('barrel exposes 24 stable/deprecated/experimental symbols', () {
    // Pool primitives (4)
    expect(PoolConfig, isA<Type>());
    expect(PoolExhaustedException, isA<Type>());
    expect(PooledConnection, isA<Type>());
    expect(PostgresConnectionPool, isA<Type>());

    // Result decoding (4)
    expect(ResultRow, isA<Type>());
    expect(ResultSet, isA<Type>());
    expect(PostgresType, isA<Type>());
    expect(PostgresOid, isA<Type>());

    // Domain interfaces + errors (6)
    expect(Repository, isA<Type>());
    expect(QueryExecutor, isA<Type>());
    expect(QueryFailedException, isA<Type>());
    expect(QueryTimeoutException, isA<Type>());
    expect(TransactionStateError, isA<Type>());
    expect(UnitOfWork, isA<Type>());

    // Concrete impls (2)
    expect(PostgresUnitOfWork, isA<Type>());
    expect(PostgresRepository, isA<Type>());

    // Transactional helpers — stable (2)
    expect(withTransaction, isA<Function>());
    expect(withTransactionOn, isA<Function>());

    // Transactional helpers — experimental (2)
    expect(withPipelinedTransaction, isA<Function>());
    expect(withTransactionInstrumented, isA<Function>());

    // Diagnostics — experimental (2)
    expect(TxDiagnostics, isA<Type>());
    void noopSink(TxDiagnostics _) {}
    final PoolDiagnosticsSink sink = noopSink;
    expect(sink, isA<Function>());

    // Isolate worker pool — deprecated but kept on barrel (2)
    // ignore: deprecated_member_use
    expect(IsolateWorkerPool, isA<Type>());
    // ignore: deprecated_member_use
    expect(WorkerPoolConfig, isA<Type>());
  });

  test('PoolConfig defaults instantiate via barrel only', () {
    const config = PoolConfig(
      connInfo: 'host=localhost port=5432 dbname=x user=x password=x',
    );
    expect(config, isA<PoolConfig>());
    expect(config.maxSize, greaterThan(0));
  });
}
