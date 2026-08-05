# dart_db_connector

High-performance, multi-database connector for Dart backends.

Built on `dart:ffi` over native C drivers, with a thread-per-connection pool that
lives outside the Dart VM and Dart Native Ports for completion notification. A
blocking database call occupies an OS thread, never an isolate, so the event loop
stays responsive under load.

Supports **PostgreSQL**, **MySQL**, **MongoDB** and **SQLite** through one
architecture: the vertical contract (`Repository` / `UnitOfWork` / connection pool)
stays constant, while each driver keeps its own native core.

## Install

```yaml
dependencies:
  dart_db_connector: ^0.1.0
```

## Usage

### Non-transactional read (fastest path)

```dart
import 'package:dart_db_connector/dart_db_connector.dart';

final pool = PostgresConnectionPool(
  const PoolConfig(
    connInfo: 'host=localhost port=5432 dbname=app user=postgres password=secret',
    maxSize: 8,
  ),
);
await pool.start();

final rs = await withPostgresConnection(pool, (exec) async {
  return exec.execute('SELECT id, name FROM users LIMIT 10');
});
try {
  for (var r = 0; r < rs.rowCount; r++) {
    final row = rs.row(r);
    print('${row['id']}: ${row['name']}');
  }
} finally {
  rs.release();
}

await pool.close();
```

`withPostgresConnection` skips the `BEGIN`/`COMMIT` round-trips, which is what you
want for reads. Use `withTransaction` when you need atomicity.

Always `release()` a `ResultSet`: it owns native memory. A finalizer will reclaim it
eventually, but explicit release is what keeps resident memory flat under load.

### Bound parameters

Any value originating outside the application should be bound, never interpolated
into the SQL string:

```dart
final rs = await withTransaction<ResultSet>(pool, (exec) async {
  return exec.execute(
    r'SELECT id, name FROM users WHERE email = $1',
    params: [Param.text(email)],
  );
});
rs.release();
```

### Other databases

```dart
final mysql = MysqlConnectionPool(
  const MysqlPoolConfig(
      host: 'localhost', user: 'root', password: 'secret', database: 'app'),
);
final mongo = MongoConnectionPool(
  const MongoPoolConfig(uri: 'mongodb://localhost:27017', maxSize: 8),
);
final sqlite = SqliteConnectionPool(
  const SqlitePoolConfig(path: 'app.db', maxSize: 4),
);
```

MongoDB is a document store, so its operations are typed (`MongoCollection`) rather
than `execute(sql)`, and there is no `UnitOfWork` — multi-document transactions
require a replica set. Everything else reuses the same `Repository` contract.

See [`example/`](example) for runnable programs covering each driver.

## Platform support

Pre-built native binaries ship with the package for:

| Platform | Status |
|---|---|
| `linux-x64` | pre-built binary |
| `linux-arm64` | pre-built binary |
| `macos-arm64` | pre-built binary |
| `macos-x64` | pre-built binary |
| Windows | **not supported** |

Windows is not a packaging gap: the native pool is implemented on POSIX threads and
has no Win32 path. Supporting it means porting that layer, not adding a build target.

## System libraries

The native binaries link **dynamically** against each database's client library, so
a pre-built binary saves you the compiler and CMake, but the client library still
has to be present. This is deliberate: statically linking `libmysqlclient` (GPLv2)
into an MIT package would change the licence of the result.

Install only what you use — the drivers load lazily, so an absent library only
surfaces if you actually touch that driver.

| Driver | Debian / Ubuntu | macOS (Homebrew) |
|---|---|---|
| PostgreSQL | `libpq5` | `libpq` |
| MySQL | `libmysqlclient21` | `mysql-client` |
| MongoDB | `libmongoc-1.0-0` | `mongo-c-driver` |
| SQLite | `libsqlite3-0` | ships with macOS |

## Building from source

Needed on any platform without a pre-built binary, or when working from a clone.
Requires CMake 3.20+, a C11 compiler, and the `-dev` headers of whichever clients
you want.

```bash
cmake -S native/c -B native/c/build
cmake --build native/c/build
```

Each driver can be switched off if its client library is unavailable:

```bash
cmake -S native/c -B native/c/build \
  -DBUILD_NATIVE_MYSQL=OFF -DBUILD_NATIVE_MONGO=OFF
```

The resolver finds the result automatically. To point at a specific build, set
`DART_DB_CONNECTOR_NATIVE_LIB_PATH` (and the `_MYSQL_` / `_MONGO_` / `_SQLITE_`
variants) to an absolute path.

## Diagnosing a load failure

```bash
dart run dart_db_connector:doctor
```

Reports, per driver, whether the native library was found and whether its ABI
matches what this package expects. A failure means one of three things: this
platform has no pre-built binary, the database client library is not installed, or
the native library is older than the package.

## Performance

Measured against six other language stacks under TPC-C and a TechEmpower-style HTTP
workload, with 5 independent sessions per cell and 95% confidence intervals. Full
numbers, methodology and limitations are in the repository's `benchmarks/RESULTS.md`,
along with everything needed to reproduce them.

## Licence

MIT.
