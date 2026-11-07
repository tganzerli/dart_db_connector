# TPC-C tail latency (p99) by transaction type

The p99 latency behind the driver-level TPC-C throughput reported in [`RESULTS.md`](../RESULTS.md):
seven PostgreSQL drivers, two topologies, five transaction types.

## Result

p99 in microseconds, per transaction type, aggregated over 5 sessions × 5 repetitions × 10,000
transactions per cell. Values in parentheses mark a tail outlier, p99/p50 > 10. Raw data with p50, p95,
p99 and sample counts: [`tpcc-tail-latency.csv`](tpcc-tail-latency.csv).

**1×1** (one worker, one connection):

| Driver | newOrder | payment | orderStatus | delivery | stockLevel |
|---|---:|---:|---:|---:|---:|
| this-connector | 3,289 | 566 | 392 | 4,828 | 903 |
| dart-postgres-3.5.11 | 6,263 | 914 | 574 | 7,702 | 1,096 |
| go-pgx | 7,570 | 839 | 650 | 8,505 | 1,132 |
| node-postgres.js | 5,501 | 818 | 470 | 7,344 | 1,045 |
| python-asyncpg | 6,701 | 990 | 695 | 8,076 | 1,316 |
| rust-tokio-postgres | 6,861 | 902 | 478 | 8,409 | 964 |
| java-pgjdbc | 4,315 | 604 | 322 | 5,500 | 882 |

**4×4** (four workers, four connections each, 16 connections):

| Driver | newOrder | payment | orderStatus | delivery | stockLevel |
|---|---:|---:|---:|---:|---:|
| this-connector | 6,145 | 3,314 | 636 | 10,148 | 1,169 |
| dart-postgres-3.5.11 | 13,808 | 5,646 | 815 | 18,296 | 1,355 |
| go-pgx | 11,878 | 6,249 | 915 | 16,164 | 1,396 |
| node-postgres.js | 10,543 | 5,206 | 1,074 | 16,899 | 1,755 |
| python-asyncpg | 10,713 | 5,927 | 853 | 14,831 | 1,455 |
| rust-tokio-postgres | 11,932 | 6,219 | 628 | 17,959 | 1,136 |
| java-pgjdbc | 86,602 (13.1×) | 95,299 (28.4×) | 64,809 (137.3×) | 99,689 | 71,507 (62.2×) |

## Reading it

The same driver can look very different depending on concurrency. With one connection, the Java driver
has the lowest `orderStatus` p99 of the seven (322 µs). With 16 connections its throughput is 497.3 TPS
against 1,035.9 to 1,790.2 for the others (about 2× behind the next one), while its `payment` p99 is
95,299 µs against 3,314 to 6,249 µs (about 15× behind the slowest of the others). Throughput alone would
have hidden most of that gap.

The likely causes are garbage-collection pauses and JIT recompilation under concurrency, made worse by
the missing connection pool and a warm-up that is short for a JVM. That explanation was **not measured**;
treat it as a hypothesis.

## Setup

Same battery as the driver-level TPC-C table in [`RESULTS.md`](../RESULTS.md), measured on 2026-07-30 in
one continuous overnight window.

- **Hardware:** Apple M4, 10 cores, 16 GB, macOS 15.7.5, Docker Desktop (Linux arm64 VM).
- **Database:** PostgreSQL 16 (`postgres:16-alpine`); every (driver, topology, session) runs in its own
  Docker session, torn down with its volumes afterwards.
- **Limits:** 2 CPUs and 4 GB per container.
- **Dataset:** TPC-C, 3 warehouses, reseeded per session; mix 45/43/4/4/4.
- **Drivers:** this connector (libpq through `dart:ffi`, AOT); `postgres` 3.5.11 (pure Dart, AOT); Go 1.23
  pgx v5.7.5; Node 20 postgres.js 3.4.5 (`prepare: false`); Python 3.12 asyncpg 0.30.0
  (`statement_cache_size=0`); Rust 1.85 tokio-postgres 0.7 with deadpool-postgres 0.14; Java 21 pgjdbc
  42.7.4 (plain JDBC `Statement`, **no external pool**, G1, `-Xmx2g`).
- **Warm-up:** 100 transactions; 500 for Java and the pure-Dart package.

## Reproduce

From `benchmarks/docker`, as in the [benchmark README](../README.md#running):

```bash
docker compose -f compose.postgres.yml build
SESSIONS_PER_COMBO=5 REPS=5 TX_COUNT=10000 bash run-driver-postgres.sh   # hours
```

## Caveats

- **Java ran without a connection pool** (no HikariCP), unlike idiomatic production use. Its 4×4
  throughput and tail reflect that handicap and are not a ceiling for the JVM.
- **Prepared statements were disabled in every driver** to compare wire cost on equal terms. Drivers that
  benefit from server-side prepared statements (asyncpg, pgx) are penalised uniformly.
- **Absolute values are host-specific.** Docker on macOS arm64 over loopback. What should reproduce is the
  ordering and the shape of the tail, not the magnitudes; on x86_64 the tail picture of some drivers
  changes (see the limitations in [`RESULTS.md`](../RESULTS.md#limitations)).
- **Different RNG per language.** The transaction mix is statistically equivalent across drivers, not
  bit-identical.
- **No p99.9.** The harness records p50, p95 and p99 only.
