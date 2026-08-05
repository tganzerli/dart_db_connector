#!/usr/bin/env bash
#  (SQLite) — robust battery: N independent sessions over bench_sqlite.dart.
#
# Hardens the single-session `bench_sqlite.dart` (reps only) into the selo's
# robust frame: N sessions (independent processes) × reps within each, so the
# statistical unit is the per-SESSION mean and we get CI95 / p99 / tail across
# sessions (mirrors docker/bench/aggregate-2env.py methodology).
#
# SQLite is embedded/local (FFI-vs-FFI over the SAME libsqlite3): comparing
# languages would measure the library, not the driver. So the axis here is the
# DEVELOPED driver (thread-per-conn WAL pool, offloads sqlite3_step) vs the pub
# `sqlite3` package (synchronous, in-isolate). No Docker, no network.
#
# The connector is SQLite-freeze-clean vs the frozen baseline: the perf-v2
# work (PG fast-path, MySQL codec/error) did not touch dart/lib/src/sqlite or the
# native sqlite core, so this battery is comparable to the frozen selo.
#
# Usage:
#   bash benchmarks/scripts/sqlite/run-sqlite-robust.sh          # full N=5
#   SESSIONS=1 bash benchmarks/scripts/sqlite/run-sqlite-robust.sh   # smoke
#
# Env overrides: SESSIONS (5), REPS (5), OPS (40000), RECORDS (10000),
#   SEED_BASE (12345), OUTDIR (docker/bench/outputs/-sqlite),
#   DRIVERS ("native-sqlite pkg-sqlite3"), WORKLOADS ("read mixed"),
#   TOPOS ("1x1:1 4x4:4"), SQLITE_LIB (…/build-macos/libnative_sqlite.dylib).
set -euo pipefail

# Repo root = two levels up from this script (benchmarks/scripts/sqlite/).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

SESSIONS="${SESSIONS:-5}"
REPS="${REPS:-5}"
OPS="${OPS:-40000}"
RECORDS="${RECORDS:-10000}"
SEED_BASE="${SEED_BASE:-12345}"
OUTDIR="${OUTDIR:-$REPO/docker/bench/outputs/-sqlite}"
DRIVERS="${DRIVERS:-native-sqlite pkg-sqlite3}"
WORKLOADS="${WORKLOADS:-read mixed}"
TOPOS="${TOPOS:-1x1:1 4x4:4}"   # label:conns
SQLITE_LIB="${SQLITE_LIB:-$REPO/native/c/build-macos/libnative_sqlite.dylib}"

# The developed driver resolves the native lib via this override (our build lives
# in build-macos/, not the resolver's default build/). Harmless for the pkg driver.
export DART_DB_CONNECTOR_SQLITE_NATIVE_LIB_PATH="$SQLITE_LIB"

if [[ ! -f "$SQLITE_LIB" ]]; then
  echo "[erro] libnative_sqlite não encontrada em $SQLITE_LIB" >&2
  echo "       compile: cmake -S native/c -B native/c/build-macos && cmake --build native/c/build-macos" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
RUNOUT="$OUTDIR/run.out"
: > "$RUNOUT"   # truncate

BENCH="$REPO/benchmarks/scripts/sqlite/bench_sqlite.dart"
cd "$REPO/benchmarks"

n_combos=0
for d in $DRIVERS; do for w in $WORKLOADS; do for t in $TOPOS; do n_combos=$((n_combos+1)); done; done; done
total=$((n_combos * SESSIONS))

echo "[sqlite-robust] $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)" | tee -a "$RUNOUT"
echo "[sqlite-robust] OUTDIR=$OUTDIR" | tee -a "$RUNOUT"
echo "[sqlite-robust] {$DRIVERS} × {$WORKLOADS} × {$TOPOS} × N=$SESSIONS × REPS=$REPS × ${OPS}ops = $total runs" | tee -a "$RUNOUT"
echo "[sqlite-robust] lib=$SQLITE_LIB" | tee -a "$RUNOUT"

start=$(date +%s)
c=0
# Order: session OUTER → driver → workload → topo. Diluting temporal drift across
# sessions (each combo is revisited once per session, spread over the whole run).
for s in $(seq 1 "$SESSIONS"); do
  seed=$((SEED_BASE + s * 100))
  for d in $DRIVERS; do
    for w in $WORKLOADS; do
      for topo in $TOPOS; do
        label="${topo%%:*}"; conns="${topo##*:}"
        c=$((c+1))
        csv="$OUTDIR/sqlite_${d}_${w}_${label}_s${s}.csv"
        marker="########## SQLITE SESSION s=$s driver=$d wl=$w topo=$label conns=$conns ($c/$total, $(date -u +%H:%M:%SZ)) ##########"
        echo "$marker" | tee -a "$RUNOUT"
        dart run "$BENCH" \
          --driver "$d" --workload "$w" --conns "$conns" \
          --ops "$OPS" --records "$RECORDS" --reps "$REPS" \
          --seed "$seed" --topology "$label" --csv "$csv" \
          >> "$RUNOUT" 2>&1
      done
    done
  done
  echo "[sqlite-robust] session $s/$SESSIONS done" | tee -a "$RUNOUT"
done
end=$(date +%s)
echo "[done] $total runs em $(( (end-start)/60 ))m $(( (end-start)%60 ))s" | tee -a "$RUNOUT"
echo "[sqlite-robust] CSVs: $(ls "$OUTDIR"/sqlite_*.csv 2>/dev/null | wc -l | tr -d ' ')" | tee -a "$RUNOUT"
