# Pipeline mode vs sequential round-trips

How much of a short write transaction is spent waiting for the network, measured by sending the same
transaction two ways over the same PostgreSQL connection.

- **Sequential:** `BEGIN`, 10 × `INSERT`, `COMMIT`, each sent only after the previous reply arrives.
  12 round-trips per transaction.
- **Pipeline:** the same 12 statements sent through
  [libpq pipeline mode](https://www.postgresql.org/docs/current/libpq-pipeline-mode.html), without
  waiting for each result, followed by one sync point. 1 round-trip per transaction.

## Result

3 repetitions × 1,000 transactions per mode. Raw data: [`pipeline-vs-sequential.csv`](pipeline-vs-sequential.csv).

| Rep | Sequential TPS | Pipeline TPS | Sequential µs/tx | Pipeline µs/tx |
|---:|---:|---:|---:|---:|
| 1 | 788.4 | 3,818.6 | 1,268 | 262 |
| 2 | 849.6 | 3,970.1 | 1,177 | 252 |
| 3 | 858.5 | 3,898.7 | 1,165 | 256 |
| **Mean** | **832.2** | **3,895.8** | **1,203** | **257** |

Pipeline mode delivered **4.68×** the transactions per second, and the ranges of the two modes do not
overlap in any repetition. The hypothesis registered before the run was a 20-40% gain.

## Setup

- **Hardware:** Apple M4, 10 cores, 16 GB, macOS 15.7.5.
- **Database:** PostgreSQL 16 (`postgres:16-alpine`) in Docker; client on the host, through Docker networking.
- **Client:** this connector (libpq 18.3 through `dart:ffi`), Dart 3.11.6, JIT (`dart run`). Measured on
  2026-05-18, with the connector as it was then.
- **Fairness:** a pool of exactly one connection, shared by both modes; the modes alternate inside each
  repetition, and the table is dropped and recreated before each one.
- **Table:** `bench_pipeline (rep int4, tx int4, n int4, payload text, PRIMARY KEY (rep, tx, n))`, empty at
  the start of each repetition.

## Reproduce

Start any PostgreSQL 16 reachable from the host and point the harness at it with `POSTGRES_HOST`,
`POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER` and `POSTGRES_PASSWORD` (defaults: `localhost`, `5432`,
`teste`, `postgres`, `123`). From `benchmarks/harness-dart`:

```bash
mkdir -p ../docker/bench/outputs/legacy   # the script writes its CSV and SVG here
dart run scripts/pipeline_vs_sequential.dart
```

Source: [`harness-dart/scripts/pipeline_vs_sequential.dart`](../harness-dart/scripts/pipeline_vs_sequential.dart).

The connector in this repository is newer than the one measured, and it has since learned to fuse `BEGIN`
with the following statement on some paths. A re-run may therefore send fewer than 12 round-trips on the
sequential side, and its numbers can differ from the table above.

## Caveats

Read these before quoting the number.

- **Synthetic, write-only workload.** Ten independent inserts is the best case for pipelining. A typical
  OLTP transaction reads something and decides what to write next; the PostgreSQL documentation states that
  pipelining is not useful when the client needs the result of one operation to build the next one.
- **Round-trip cost is environment-specific.** Docker networking on macOS makes each round-trip relatively
  expensive. On Linux over a Unix socket the sequential side would be faster and the relative gain could
  shrink; across a real network it could grow.
- **No reads.** The pipeline path used here discards result rows, so `SELECT` in a pipeline was not
  measured.
- **One machine, JIT mode, three repetitions.** No confidence intervals; the non-overlapping ranges are the
  evidence of a difference, not of its exact size.
- **Error handling is the cost.** If a statement in a pipeline fails, the server skips the rest of the queue
  until the next sync point, and the driver must leave the connection and its transaction state clean.
