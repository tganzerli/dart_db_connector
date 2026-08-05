#!/usr/bin/env bash
# FINAL ROBUST cross-language TPC-C bench under STRICT ISOLATION with
# N independent sessions per (driver × topology).
#
# Difference vs run-driver-postgres.sh (May delivery — kept intact for history):
#   1. OUTER loop over SESSIONS_PER_COMBO. Order is session → driver → topology,
#      so every driver is sampled across the WHOLE temporal window (closes the
#      temporal-gap threat #11 of the May bench page). Driver order is rotated
#      deterministically per session to balance ordering effects (no RNG).
#   2. Each session's stdout is tee'd to <stem>_s<N>.log — wall-clock TPS lives
#      ONLY in stdout (the metrics CSV has no TPS column). Extracted later
#      by extract-throughput.sh.
#   3. Per-session CSVs (suffix _s<N>) — nothing is overwritten.
#   4. Dart 1×1 uses bench_tpcc_single_isolate --conns 1 (TRUE 1×1, matches the
#      other drivers' --workers 1 --conns-per-worker 1 and the post-fix
#      re-baseline 612.6 TPS), NOT the default bench_tpcc_small (fixed 4-conn
#      pool = NOT 1×1). See execution log D1.
#   5. Persistence sanity per Dart session (orders/new_order/order_line > 0) —
#      guards against the pre-fix degenerate-load artifact (execution log ress. 1).
#
# Sessions total: SESSIONS_PER_COMBO × 7 drivers × 2 topologies.
#   Chosen config (2026-07-30): SESSIONS_PER_COMBO=5 REPS=5 TX_COUNT=10000
#   → 70 isolated sessions, ~4–6 h wall-clock, 3.5M samples.
#
# Build first (Dart developed post-fix; native-lib COPY cache caveat → --no-cache):
#   docker compose -f compose.postgres.yml build --no-cache bench-dart
#   docker compose -f compose.postgres.yml build bench-go bench-node bench-python bench-rust bench-java
#
# Usage (smoke):  SESSIONS_PER_COMBO=1 REPS=1 TX_COUNT=200 bash run-driver-postgres.sh
# Usage (full):   SESSIONS_PER_COMBO=5 REPS=5 TX_COUNT=10000 bash run-driver-postgres.sh
#
# Env:
#   SESSIONS_PER_COMBO (default 5)
#   TX_COUNT (default 10000)
#   REPS (default 5)
#   OUTDIR (default ./outputs)
#   DRIVERS_OVERRIDE / TOPOLOGIES_OVERRIDE (space-separated subsets)

set -euo pipefail
cd "$(dirname "$0")"

SESSIONS_PER_COMBO="${SESSIONS_PER_COMBO:-5}"
TX_COUNT="${TX_COUNT:-10000}"
REPS="${REPS:-5}"
OUTDIR="${OUTDIR:-./outputs}"
mkdir -p "$OUTDIR"

DRIVERS=(dart dart-pkg go node python rust java)
TOPOLOGIES=(1x1 4x4)

if [ -n "${DRIVERS_OVERRIDE:-}" ]; then
  read -r -a DRIVERS <<< "$DRIVERS_OVERRIDE"
fi
if [ -n "${TOPOLOGIES_OVERRIDE:-}" ]; then
  read -r -a TOPOLOGIES <<< "$TOPOLOGIES_OVERRIDE"
fi

# CSV/log stem for a (driver, topology, session).
stem() {
  local driver="$1" topo="$2" s="$3"
  case "$driver" in
    dart)     echo "robust_dart-developed_${topo}_s${s}" ;;
    dart-pkg) echo "robust_dart-pkg_${topo}_s${s}" ;;
    *)        echo "robust_${driver}_${topo}_s${s}" ;;
  esac
}

wait_postgres_healthy() {
  local timeout=60 elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if docker compose -f compose.postgres.yml ps postgres --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "[error] postgres failed to become healthy in ${timeout}s" >&2
  return 1
}

seed_db() {
  docker compose -f compose.postgres.yml run --rm --entrypoint /bin/bash bench-dart \
    -c "PGPASSWORD=123 psql -h postgres -U postgres -d teste -q -f /app/tpcc_schema.sql >/dev/null && /app/bench_seed" \
    >/dev/null
}

# Persistence sanity for the Dart arms: a post-fix run MUST populate the order
# tables. Appended to the session .log so the artifact is self-documenting.
persistence_check() {
  local logfile="$1"
  docker compose -f compose.postgres.yml run --rm --entrypoint /bin/bash bench-dart \
    -c "PGPASSWORD=123 psql -h postgres -U postgres -d teste -c \"SELECT count(*) AS orders FROM orders; SELECT count(*) AS new_order FROM new_order; SELECT count(*) AS order_line FROM order_line;\"" \
    2>&1 | tee -a "$logfile"
}

# ── Dart developed (FFI) ────────────────────────────────────────────
# 1×1 = TRUE 1×1 via bench_tpcc_single_isolate --conns 1 (D1). 4×4 = multi.
run_dart() {
  local topo="$1" out="$2"
  rm -f "$OUTDIR/$out.csv" "$OUTDIR/$out.log"
  if [ "$topo" = "1x1" ]; then
    docker compose -f compose.postgres.yml run --rm -e BENCH_OUTPUT_DIR=/outputs \
      --entrypoint /app/bench_tpcc_single_isolate bench-dart \
      --driver native --conns 1 --tx-count "$TX_COUNT" --reps "$REPS" \
      --out-base "$out" 2>&1 | tee "$OUTDIR/$out.log"
  else
    docker compose -f compose.postgres.yml run --rm -e BENCH_OUTPUT_DIR=/outputs \
      --entrypoint /app/bench_tpcc_multi bench-dart \
      --driver native --workers 4 --conns-per-worker 4 \
      --tx-count "$TX_COUNT" --reps "$REPS" \
      --out-base "$out" 2>&1 | tee "$OUTDIR/$out.log"
  fi
  persistence_check "$OUTDIR/$out.log"
}

# ── Dart Pkg postgres (pub.dev 3.5.11) ──────────────────────────────
run_dart_pkg() {
  local topo="$1" out="$2"
  rm -f "$OUTDIR/$out.csv" "$OUTDIR/$out.log"
  if [ "$topo" = "1x1" ]; then
    docker compose -f compose.postgres.yml run --rm -e BENCH_OUTPUT_DIR=/outputs \
      --entrypoint /app/bench_tpcc_single_isolate bench-dart \
      --driver postgres --conns 1 --tx-count "$TX_COUNT" --reps "$REPS" \
      --out-base "$out" 2>&1 | tee "$OUTDIR/$out.log"
  else
    docker compose -f compose.postgres.yml run --rm -e BENCH_OUTPUT_DIR=/outputs \
      --entrypoint /app/bench_tpcc_multi bench-dart \
      --driver postgres --workers 4 --conns-per-worker 4 \
      --tx-count "$TX_COUNT" --reps "$REPS" \
      --out-base "$out" 2>&1 | tee "$OUTDIR/$out.log"
  fi
  persistence_check "$OUTDIR/$out.log"
}

# ── Cross-language drivers (go/node/python/rust/java) ───────────────
run_other() {
  local service="$1" topo="$2" out="$3"; shift 3
  local workers cpw
  case "$topo" in
    1x1) workers=1; cpw=1 ;;
    4x4) workers=4; cpw=4 ;;
  esac
  rm -f "$OUTDIR/$out.csv" "$OUTDIR/$out.log"
  docker compose -f compose.postgres.yml run --rm "$service" \
    --workers "$workers" --conns-per-worker "$cpw" \
    --tx-count "$TX_COUNT" --reps "$REPS" \
    --csv "/outputs/$out.csv" "$@" 2>&1 | tee "$OUTDIR/$out.log"
}

isolated_run() {
  local driver="$1" topo="$2" s="$3"
  local out; out="$(stem "$driver" "$topo" "$s")"
  echo
  echo "============================================="
  echo "  SESSION $s · $driver $topo  →  $out"
  echo "  $(date -u +%H:%M:%S) UTC"
  echo "============================================="

  docker compose -f compose.postgres.yml down -v 2>/dev/null || true
  docker compose -f compose.postgres.yml up -d postgres >/dev/null
  wait_postgres_healthy
  seed_db

  case "$driver" in
    dart)     run_dart "$topo" "$out" ;;
    dart-pkg) run_dart_pkg "$topo" "$out" ;;
    go)       run_other bench-go "$topo" "$out" ;;
    node)     run_other bench-node "$topo" "$out" ;;
    python)   run_other bench-python "$topo" "$out" ;;
    rust)     run_other bench-rust "$topo" "$out" ;;
    java)     run_other bench-java "$topo" "$out" --warmup 500 ;;
  esac

  docker compose -f compose.postgres.yml down -v 2>/dev/null || true
  echo "[isolated] cool-down 10s ..."
  sleep 10
}

# Pre-flight: ensure images exist (no rebuild during the timed run)
echo "[setup] verifying images are built ..."
docker compose -f compose.postgres.yml build bench-dart bench-go bench-node bench-python bench-rust bench-java 2>&1 | tail -3

# Clean ONLY the robust CSVs/logs for the drivers being run (preserve other work)
for driver in "${DRIVERS[@]}"; do
  case "$driver" in
    dart)     rm -f "$OUTDIR"/robust_dart-developed_*.csv "$OUTDIR"/robust_dart-developed_*.log ;;
    dart-pkg) rm -f "$OUTDIR"/robust_dart-pkg_*.csv "$OUTDIR"/robust_dart-pkg_*.log ;;
    *)        rm -f "$OUTDIR"/robust_${driver}_*.csv "$OUTDIR"/robust_${driver}_*.log ;;
  esac
done

start=$(date +%s)
n_drivers=${#DRIVERS[@]}
n_sessions=$(( SESSIONS_PER_COMBO * n_drivers * ${#TOPOLOGIES[@]} ))
echo "[setup] start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[setup] SESSIONS_PER_COMBO=$SESSIONS_PER_COMBO REPS=$REPS TX_COUNT=$TX_COUNT"
echo "[setup] ${SESSIONS_PER_COMBO} × ${n_drivers} drivers × ${#TOPOLOGIES[@]} topologies = ${n_sessions} isolated sessions"

for (( s=1; s<=SESSIONS_PER_COMBO; s++ )); do
  # Deterministic rotation of driver order by session index (balances ordering
  # effects across the temporal window without RNG — reproducible).
  offset=$(( (s - 1) % n_drivers ))
  rotated=( "${DRIVERS[@]:offset}" "${DRIVERS[@]:0:offset}" )
  echo
  echo "########## SESSION ROUND $s / $SESSIONS_PER_COMBO — order: ${rotated[*]} ##########"
  for driver in "${rotated[@]}"; do
    for topo in "${TOPOLOGIES[@]}"; do
      isolated_run "$driver" "$topo" "$s"
    done
  done
done

end=$(date +%s)
elapsed=$((end - start))
echo
echo "[done] ${n_sessions} isolated sessions in ${elapsed}s ($((elapsed/60))m $((elapsed%60))s)"
ls -la "$OUTDIR"/robust_*.csv 2>&1 | tail -20
