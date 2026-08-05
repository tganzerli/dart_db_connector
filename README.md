# dart_db_connector

A high-performance, multi-database connector for Dart backends, plus the benchmark
suite used to measure it.

Dart is fast, but on the server its database drivers have historically been the
bottleneck: the language's raw speed gets neutralised by the persistence layer.
This project attacks that layer directly. It pairs `dart:ffi` with native C drivers,
a thread-per-connection pool that lives outside the Dart VM, and Dart Native Ports
for completion notification, so a blocking database call never occupies an isolate.

**PostgreSQL, MySQL, MongoDB and SQLite** are supported through one architecture:
the vertical contract (`Repository` / `UnitOfWork` / connection pool) stays constant
while each driver keeps its own native core.

## What lives here

This repository has two distinct audiences, and the layout reflects that.

| Directory | For whom | What it is |
|---|---|---|
| [`packages/dart_db_connector/`](packages/dart_db_connector) | consumers | The published package. Add it from pub.dev and you never need the rest of this repo. |
| [`benchmarks/`](benchmarks) | reviewers | Everything needed to re-run the measurements yourself: harnesses in six languages, Docker topologies, and the statistical aggregators. |

Publishing is scoped to the package directory, so nothing in `benchmarks/` ever
ships to pub.dev.

## Quick start

```yaml
dependencies:
  dart_db_connector: ^0.1.0
```

```dart
import 'package:dart_db_connector/dart_db_connector.dart';

final pool = PostgresConnectionPool(
  connString: 'host=localhost user=postgres password=secret dbname=app',
  size: 8,
);
await pool.start();

await withPostgresConnection(pool, (conn) async {
  final rs = await conn.execute('SELECT id, name FROM users LIMIT 10');
  for (final row in rs.rows) {
    print('${row['id']}: ${row['name']}');
  }
  rs.release();
});

await pool.close();
```

See the [package README](packages/dart_db_connector/README.md) for the full API,
supported platforms, and the system libraries each driver needs.

## Results

Headline numbers, methodology and limitations are in
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md). The short version, measured on
Apple M4 with 5 independent sessions per cell and 95% confidence intervals:

- **PostgreSQL, driver level (TPC-C):** leads all seven compared drivers in both
  topologies — 712.9 TPS at 1x1 and 1790.2 TPS at 4x4.
- **PostgreSQL, HTTP end-to-end:** 1.55x to 4.31x the throughput of the pub.dev
  driver across four database-bound endpoints, with p99 latency roughly an order
  of magnitude below Go, Java and Rust.
- **MySQL and MongoDB:** parity drivers. Go leads single-connection; this connector
  leads at 4x4 concurrency, and holds a far tighter latency tail throughout.

Those results carry real caveats about hardware and architecture. They are stated
plainly in `RESULTS.md` rather than buried, and you can reproduce every one of them
with [`benchmarks/README.md`](benchmarks/README.md).

## Status

Version 0.1.0. The public API surface is settled and audited, but it may still
change before 1.0.0. Platform support is documented honestly in the package README:
four platforms ship pre-built binaries, Windows is not supported.

## License

MIT. See [LICENSE](LICENSE).
