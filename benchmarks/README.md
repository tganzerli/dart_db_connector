# Benchmarks

Everything needed to re-run the measurements in [`RESULTS.md`](RESULTS.md) yourself.

Performance claims are only worth what their reproduction path is worth. This
directory holds the actual harnesses, not a description of them: six language
implementations of the same workloads, the Docker topologies they run in, and the
aggregators that turn raw runs into confidence intervals.

## Layout

```
harness-dart/  The Dart benchmark harness: TPC-C and YCSB runners for this
               connector and for the pub.dev drivers, plus SQL fixtures and seeds.
drivers/       Driver-level workloads in the other languages: Go, Java, Node,
               Python, Rust.
http/          HTTP servers implementing the same endpoints across 14 stacks,
               for end-to-end measurement.
docker/        Compose topologies, per-language Dockerfiles, run orchestration,
               and the statistical aggregators.
```

## Requirements

- Docker with Compose v2 (`docker compose`, not `docker-compose`)
- Roughly 8 GB free for images
- Free disk on the Docker VM. A full VM causes the database container to hang in
  ways that look like a driver bug. Run `docker system df` first.

Nothing else: every language toolchain lives inside its container.

## The isolation protocol

Every result comes from a **strictly isolated** run. Databases keep state across
runs (buffer pools, autovacuum, lock tables), and stopped containers still hold
host resources, so measuring several drivers inside one Compose session lets each
run contaminate the next.

Each measurement therefore gets its own session:

1. `docker compose down -v` — destroy containers *and* volumes
2. `docker compose up -d <database>` — fresh instance
3. wait for the healthcheck
4. apply schema, seed data
5. run one battery of repetitions for one driver
6. `docker compose down -v`
7. sleep 10s so the OS can release resources
8. next driver

This is not optional. Running drivers back to back in a shared session produced a
158x tail-latency artifact that did not reproduce under isolation, which is the
reason the protocol exists.

## Host contention

The isolation protocol above stops one run from contaminating the next. It does
nothing about the machine underneath, and that gap is worth more than it sounds.

Background work on the host does not add noise that averages out. It steals CPU,
so it penalises whichever stack is closest to saturating the machine and leaves
the slower ones untouched. The result is a **systematic reordering** of a
cross-stack comparison, in the direction that flatters the slower stack.

Measured on the reference host, on the same cell (`/db`, pool 64, 4 vCPU), by
suspending and resuming the background daemons:

| Background CPU | Throughput | Deviation |
|---|---|---|
| 89% | 62,091 rps | -17% |
| 0% (suspended) | 74,739 rps | -0.04% |
| 79% (running again) | 59,751 rps | -20% |

Over a full battery the two fastest stacks lost 17-29% while every other stack
stayed within noise. Nothing in container-level instrumentation shows this: the
containers were perfectly healthy, they simply had less machine to run on.

Two traps specific to macOS hosts, both of which cost us real time:

- **Spotlight indexing (`mds_stores`) and photo analysis (`mediaanalysisd`)**
  can take more than a full core for hours. macOS schedules them precisely when
  the machine looks idle, so **resting the machine between runs makes this
  worse, not better**. Ten, twenty and thirty minute pauses produced no recovery
  at all in our tests.
- **It is not thermal.** On a fanless machine that is the obvious suspect, and it
  is wrong. Chassis temperature returned below baseline while throughput stayed
  22% down, and the effect is bimodal rather than a curve.

What to do:

1. Run `capture-host-load.sh` for the whole battery and join it against your run
   log by timestamp. Decide which cells to discard from the **environment**
   covariate, never from the result: selecting on the outcome is how a
   measurement error becomes a publication error. Fix the threshold before you
   look at the data.
2. Gate the start with `check-host-quiet.sh`, or simply reboot first. Checking
   costs seconds; a contaminated battery costs hours.
3. On macOS you can pause the two daemons for the duration of a run. This is
   reversible and changes no persistent configuration:

   ```sh
   killall -STOP mediaanalysisd photoanalysisd   # before
   killall -CONT mediaanalysisd photoanalysisd   # after, always
   ```

   `mds_stores` runs as root and needs `sudo`. Leaving it alone is fine as long
   as `capture-host-load.sh` is recording, so any residual contamination stays
   visible rather than invisible.

The general rule this cost three wrong diagnoses to learn: **when a measurement
disagrees with a reference, look outside the container before blaming the
instrument.** We blamed the collector, then swap, and both were wrong, because
everything instrumented was inside the container.

## Statistics

The unit of inference is the **per-session mean**, not the individual request.

- **N = 5 independent sessions** per cell, each with its own seeds
- Driver level additionally runs 5 repetitions per session
- **95% confidence intervals** via Student's t (df = 4, t = 2.776)
- Adjacent pairs compared with Welch's t-test and Mann-Whitney U
- Tail reported as p99 and p99/p50; a ratio above 10 is flagged as a tail outlier
- Driver order is **rotated deterministically** per session, so no driver
  systematically occupies the same slot in the time window
- Throughput is measured by **wall-clock** at the runner, never derived from
  summing per-request latencies — the latter overestimates under parallelism

## Running

All commands run from `benchmarks/docker`.

### Driver level

```bash
# Build once
docker compose -f compose.postgres.yml build

# Smoke run: two drivers, one topology, a few minutes. Start here to confirm
# the topology works before committing to a full run.
SESSIONS_PER_COMBO=1 REPS=1 TX_COUNT=200 \
  DRIVERS_OVERRIDE="dart go" TOPOLOGIES_OVERRIDE="1x1" \
  bash run-driver-postgres.sh

# Full run (hours) — 7 drivers x 2 topologies x 5 sessions = 70 isolated sessions
SESSIONS_PER_COMBO=5 REPS=5 TX_COUNT=10000 bash run-driver-postgres.sh
```

MySQL and MongoDB follow the same shape:

```bash
bash run-driver-mysql.sh    # env: TX_COUNT, REPS, TPCC_WAREHOUSES, OUTDIR
bash run-driver-mongo.sh    # env: OPS, RECORDS, REPS, DIST, BATCH, OUTDIR
```

### HTTP end-to-end

```bash
bash run-http-postgres.sh       # env: SESSIONS=5 VCPUS="2 4" WRK_CONNS=64
bash run-http-mysql-mongo.sh    # env: SESSIONS=5 VCPUS=4
```

Start with `SESSIONS=1 SUSTAINED_SEC=5` to confirm the topology works before
committing to a full run.

### Aggregating

```bash
python3 aggregate-driver.py    # per-cell mean, 95% CI, p99, significance tests
python3 aggregate-http.py
python3 plot-driver.py         # SVG charts with error bars
python3 plot-http.py
```

Raw CSVs land under `outputs/` and are deliberately not versioned: they run to
gigabytes, and the point of this directory is that you can regenerate them.

## Topologies

`1x1` is one worker with one connection: it isolates per-operation cost with no
intra-process contention. `4x4` is four workers with four connections each: it
measures behaviour under concurrency. The two often rank drivers differently, which
is itself a finding rather than noise — see `RESULTS.md`.

## Reproducing exactly

Absolute numbers depend on hardware, and matching ours is not the goal. What should
reproduce is the **relative ordering** and the **shape of the tail**. If your
ordering differs from `RESULTS.md`, that is interesting, and the limitations section
there lists the cases where we already know the ordering is hardware-dependent.
