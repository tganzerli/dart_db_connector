/// dart_db_connector — High-performance multi-database connector for Dart Backend.
///
/// The public API surface is audited and settled, but may still change
/// before 1.0.0 — pin a version range and read CHANGELOG.md when upgrading.
///
/// Four drivers share the same layered architecture over a native
/// thread-per-conn pool: **PostgreSQL** (`libpq`), **MySQL**
/// (`libmysqlclient`), **MongoDB** (`libmongoc`) and **SQLite**
/// (`libsqlite3`, embedded). All reuse
/// the agnostic [Repository] contract. The relational drivers share a
/// SQL/row surface; MongoDB is a document store — same vertical contract,
/// but its operations are typed ([MongoCollection]) rather than `execute(sql)`,
/// and there is no `UnitOfWork` (multi-doc transactions need a replica set).
///
/// PostgreSQL surface (stable unless marked):
///   - Connection pool: [PostgresConnectionPool], [PooledConnection],
///     [PoolConfig], [PoolExhaustedException].
///   - Result decoding: [ResultSet], [ResultRow], [PostgresType],
///     [PostgresOid].
///   - Parameter binding (ABI MINOR 1): [Param], [SqlStmt].
///   - Domain interfaces + errors: [Repository], [QueryExecutor],
///     [QueryFailedException], [QueryTimeoutException],
///     [TransactionStateError], [UnitOfWork].
///   - Concrete impls: [PostgresUnitOfWork], [PostgresRepository].
///   - Transactional helpers: [withTransaction], [withTransactionOn].
///   - Isolate worker pool *(deprecated — prefer native thread/conn pool
///     of MAJOR 2)*: [IsolateWorkerPool], [WorkerPoolConfig].
///   - **`@experimental`** (contract may change before 1.0):
///     [withPipelinedTransaction], [withTransactionInstrumented],
///     `TxDiagnostics`, `PoolDiagnosticsSink`.
///
/// MySQL surface (simple-protocol, Tier 1 string SQL — no bound
/// parameters in v1):
///   - Connection pool: [MysqlConnectionPool], [MysqlPooledConnection],
///     [MysqlPoolConfig], [MysqlPoolExhaustedException].
///   - Result decoding: [MysqlResultSet], [MysqlResultRow], [MysqlType].
///   - Concrete impls: [MysqlUnitOfWork], [MysqlRepository],
///     [MysqlQueryExecutor].
///   - Transactional helpers: [withMysqlTransaction],
///     [withMysqlTransactionOn].
///
/// MongoDB surface (document model, no SQL):
///   - Connection pool: [MongoConnectionPool], [MongoPooledConnection],
///     [MongoPoolConfig], [MongoPoolExhaustedException].
///   - Document ops + repository: [MongoCollection], [MongoRepository].
///   - Decoded values: [BsonDocument], [ObjectId].
///   - Errors: [MongoOperationException] (carries the real libmongoc
///     message + code).
///
/// SQLite surface (embedded, no network):
///   - Connection pool: [SqliteConnectionPool], [SqlitePooledConnection],
///     [SqlitePoolConfig], [SqlitePoolExhaustedException].
///   - Result decoding: [SqliteResultSet], [SqliteResultRow].
///   - Concrete impls: [SqliteUnitOfWork], [SqliteRepository],
///     [SqliteQueryExecutor].
///   - Transactional helpers: [withSqliteTransaction],
///     [withSqliteTransactionOn].
///
/// What's NOT exported (internal — use `package:dart_db_connector/src/...`
/// only if you accept ABI/internal churn):
///   - Low-level FFI binding (`PostgresBinding`) — subject to ABI change.
///   - Native library loader (`loadNativeDb`).
///   - Cross-isolate message types of `IsolateWorkerPool` (`QueryRequest`,
///     `QueryResult`, `QueryError`, `WorkerResponse`).
///
/// Architectural overview + ADRs live in the project repo at
/// https://github.com/tganzerli/dart_db_connector (the package itself is
/// self-contained — this link is for readers curious about the
/// design rationale).
library;

export 'src/pool/connection_pool.dart'
    show
        PoolConfig,
        PoolExhaustedException,
        PooledConnection,
        PostgresConnectionPool;

export 'src/decoder/result_row.dart' show ResultRow, ResultSet;
export 'src/decoder/postgres_type.dart' show PostgresType;
export 'src/decoder/postgres_oids.dart' show PostgresOid;

export 'src/isolates/worker_pool.dart' show IsolateWorkerPool, WorkerPoolConfig;

export 'src/domain/repository.dart' show Repository;
export 'src/domain/unit_of_work.dart'
    show
        QueryExecutor,
        QueryFailedException,
        QueryTimeoutException,
        TransactionStateError,
        UnitOfWork;
export 'src/postgres/postgres_unit_of_work.dart' show PostgresUnitOfWork;
export 'src/postgres/postgres_repository.dart' show PostgresRepository;
export 'src/postgres/param.dart' show Param, SqlStmt;
export 'src/postgres/with_transaction.dart'
    show withPipelinedTransaction, withTransaction, withTransactionOn;
export 'src/postgres/with_postgres_connection.dart' show withPostgresConnection;
export 'src/postgres/with_transaction_instrumented.dart'
    show withTransactionInstrumented;
export 'src/pool/pool_diagnostics.dart' show TxDiagnostics, PoolDiagnosticsSink;

// ── MySQL driver — mirrors the PostgreSQL surface, reuses the
//    agnostic Repository/QueryFailedException/TransactionStateError. ──
export 'src/pool/mysql_connection_pool.dart'
    show
        MysqlConnectionPool,
        MysqlPoolConfig,
        MysqlPooledConnection,
        MysqlPoolExhaustedException;
export 'src/decoder/mysql_result_row.dart' show MysqlResultSet, MysqlResultRow;
export 'src/decoder/mysql_type.dart' show MysqlType;
export 'src/mysql/mysql_query_executor.dart' show MysqlQueryExecutor;
export 'src/mysql/mysql_unit_of_work.dart' show MysqlUnitOfWork;
export 'src/mysql/mysql_repository.dart' show MysqlRepository;
export 'src/mysql/with_mysql_transaction.dart'
    show withMysqlTransaction, withMysqlTransactionOn;
export 'src/mysql/with_mysql_connection.dart' show withMysqlConnection;

// ── MongoDB driver — document model over libmongoc; reuses the
//    agnostic Repository. No UnitOfWork/QueryExecutor (they leak the
//    relational ResultSet/Param and do not apply to a document store). ──
export 'src/pool/mongo_connection_pool.dart'
    show
        MongoConnectionPool,
        MongoPoolConfig,
        MongoPooledConnection,
        MongoPoolExhaustedException;
export 'src/mongo/mongo_collection.dart' show MongoCollection;
export 'src/mongo/mongo_repository.dart' show MongoRepository;
export 'src/mongo/mongo_bulk_result.dart'
    show BulkWriteResult, BulkWriteError, MongoBulkWriteException;
export 'src/decoder/bson_value.dart' show BsonDocument, ObjectId;
export 'src/native/mongo_native_pool.dart' show MongoOperationException;

// ── SQLite driver — embedded, relational; reuses the agnostic
//    Repository. Like MySQL it duplicates the executor/UoW (SQL seam). ──
export 'src/pool/sqlite_connection_pool.dart'
    show
        SqliteConnectionPool,
        SqlitePoolConfig,
        SqlitePooledConnection,
        SqlitePoolExhaustedException;
export 'src/decoder/sqlite_result_row.dart'
    show SqliteResultSet, SqliteResultRow, SqliteCellType;
export 'src/sqlite/sqlite_query_executor.dart' show SqliteQueryExecutor;
export 'src/sqlite/sqlite_unit_of_work.dart' show SqliteUnitOfWork;
export 'src/sqlite/sqlite_repository.dart' show SqliteRepository;
export 'src/sqlite/with_sqlite_transaction.dart'
    show withSqliteTransaction, withSqliteTransactionOn;
