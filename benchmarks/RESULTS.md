# Results

Measured with the harnesses in this directory. Every number below comes from
5 independent sessions per cell under strict isolation, with 95% confidence
intervals. Read [`README.md`](README.md) for the protocol, and the
[limitations](#limitations) section before quoting anything.

**Primary environment:** Apple M4 (arm64), 10-core, 16 GB, macOS 15.7.5, Docker
Desktop. **Second environment:** Intel i7-8750H (x86_64), 6-core.

In the tables, *developed* is this connector and *pub.dev* is the incumbent
pure-Dart package for the same database.

---

## PostgreSQL

### Driver level, TPC-C

Seven drivers, N = 5 sessions x 5 repetitions x 10 000 transactions (3.5M total),
same time window. Throughput in transactions per second:

| Topology | Leader | Second | Rest of the field |
|---|---|---|---|
| 1x1 | **developed 712.9** | Java 561.3 | Node 484.4 > pub.dev 383.1 > Python 367.7 ≈ Rust 366.1 > Go 337.1 |
| 4x4 | **developed 1790.2** | Node 1143.0 ≈ pub.dev 1126.5 ≈ Python 1122.8 | Go 1036.0 ≈ Rust 1035.9 > Java 497.3 |

The connector leads both topologies by a distinguishable margin. At 4x4 the tail
outlier moves to Java, whose JDBC pool does not scale across connections.

### HTTP end-to-end

TechEmpower-style endpoints, pool = 64, 4 vCPU. Comparing this connector against
the pub.dev driver behind the same HTTP framework isolates the driver's
contribution:

| Endpoint | developed | pub.dev | Ratio | CI | p99 developed vs Go |
|---|---|---|---|---|---|
| `/db` | **13 004** | 8 372 | 1.55x | overlapping | **6.4 ms** vs 122.9 ms |
| `/queries` (20) | **1 205** | 600 | 2.01x | separated | 115.6 ms vs 230.8 ms |
| `/updates` | **930** | 216 | 4.31x | separated | 150.4 ms vs 239.6 ms |
| `/fortunes` | **11 039** | 6 009 | 1.84x | separated | **7.3 ms** vs 42.6 ms |

Wins all four database-bound endpoints, three of them with separated confidence
intervals, and holds a p99 roughly an order of magnitude below Go, Java and Rust.
The non-transactional fast path accounts for 1.87x to 2.43x of the read throughput
relative to the transactional path.

### Where the remaining gap lives

On endpoints with no database access, the Dart stack trailed the fast native
stacks. Swapping the HTTP framework for a raw `dart:io` server, same connector,
recovered **+54.9%** on `/plaintext` and **+60.1%** on `/json` (both p < 1e-3),
tapering to +4-6% on database-bound endpoints.

That gap was the HTTP framework, not the driver. Worth stating plainly, because the
opposite conclusion would have been the convenient one.

---

## MySQL

Parity driver. Driver-level TPC-C, N = 5 x 5, transactions per second:

| Topology | 1st | 2nd | 3rd |
|---|---|---|---|
| 1x1 | Go **725.0** | pub.dev 564.8 | developed 520.1 |
| 4x4 | **developed 901.1** | pub.dev 822.8 | Go 770.6 |

The ranking **inverts with topology**: Go leads single-connection, this connector
leads at concurrency (+9.5% over pub.dev, distinguishable).

HTTP end-to-end: Go leads throughput (`/db` 51 618, `/fortunes` 39 463) against
15 036 here. The contrast is in the tail — the Dart stacks return p99 of 3-5 ms
against Go's 52 ms. Under 64 concurrent connections issuing 20 parallel queries,
the pure-Dart `mysql_client` **collapses to 0 rps** on `/queries` and `/updates`
(pool saturation, root-caused, cell excluded from ranking) where the native pool
degrades gracefully at 1 404 / 739 rps.

---

## MongoDB

Parity driver, document model. YCSB read workloads, operations per second:

| Workload | Topology | developed | Go | pub.dev (`mongo_dart`) |
|---|---|---|---|---|
| read C | 1x1 | 13 262 | **17 374** | 5 071 |
| read C | 4x4 | **37 392** (+50.9%) | 24 778 | 6 906 |
| read A | 4x4 | **35 984** (+79.4%) | 20 054 | 12 157 |

Same inversion by topology. At 4x4 this connector dominates reads and is the only
fast driver without a tail outlier — Go's tail blows out by 39-57x.

Bulk writes scale **15.2x** from batch size 1 to 500, reaching a technical tie with
Go at high batch and 4x4, while `mongo_dart` saturates and regresses.

HTTP end-to-end: Go leads `/db` at 30 526 against 23 034 here.

---

## SQLite

Embedded, so there is no network latency to hide behind and no connection pool to
amortise. The batching and synchronous fast path beat the pub.dev `sqlite3`
package's synchronous execution, but the architecture that wins over a network is a
net cost here. Included because a negative result under a clearly stated condition
is still a result.

---

## Limitations

These qualify every number above.

**The concurrency advantage is architecture-dependent.** On x86_64, the 4x4
leadership in MySQL and MongoDB **inverts** — pub.dev leads MySQL 4x4 on Intel.
PostgreSQL is the exception: its ranking is preserved across both ISAs in both
topologies, with zero inversions over 8M transactions in a paired design. So the
PostgreSQL result generalises across architecture; the MySQL and MongoDB
concurrency wins are conditional on arm64.

**The tail advantage is also architecture-dependent.** MongoDB's clean tail at 4x4
on Apple Silicon does not survive the move to x86_64.

**The second environment is not a clean control.** It is a 2018 Intel laptop, so
"x86_64 vs arm64" is confounded with generation and thermal behaviour. Separating
those requires a modern x86 machine without throttling, which was not available.

**HTTP and SQLite were measured in one environment only.** Cross-architecture
validation covers the driver level. HTTP and SQLite results are Apple M4 only, and
should be read as such.

**Absolute values are host-sensitive.** They shift with load on the host. What
should reproduce is the ordering and the shape of the tail, not the magnitudes.
