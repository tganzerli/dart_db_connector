#!/usr/bin/env bash
# Cross-language MongoDB YCSB bench under STRICT ISOLATION. 
#
# Every (driver, workload, topology) is its own isolated Docker session:
#   1. compose down -v         (purge containers + volumes)
#   2. up mongo fresh + wait healthy
#   3. one bench (the driver loads its own dataset, then measures)
#   4. down -v
#   5. cool down 10s
#
# Drivers: dart-developed (libnative_mongo), dart-pkg (mongo_dart pub.dev),
#          go (mongo-go-driver). Workloads: C (read-only), A (50/50), W
#          (write-heavy insert — F1-Mongo bulk lever). For W, each batch size
#          in BATCHES runs as its own isolated session (batch=1 = unitary
#          insertOne baseline; batch>1 = insertMany bulk).
# Topologies: 1x1 (1 conn), 4x4 (16 conns). Key dist: uniform (fair cross-lang).
# Output: docker/bench/outputs/mongo_<driver>_<workload>_<topo>.csv
#         (write-heavy: mongo_<driver>_W_<topo>_b<batch>.csv)
#
# Usage: cd docker/bench && bash run-driver-mongo.sh
#   write-heavy F1 run: WORKLOADS_OVERRIDE="W" BATCH="1 100" bash run-driver-mongo.sh
# Env: OPS (40000), RECORDS (10000), REPS (3), DIST (uniform), BATCH ("1"),
#      OUTDIR (./outputs)

set -euo pipefail
cd "$(dirname "$0")"

export OPS="${OPS:-40000}"
export RECORDS="${RECORDS:-10000}"
export REPS="${REPS:-3}"
export DIST="${DIST:-uniform}"
OUTDIR="${OUTDIR:-./outputs}"
mkdir -p "$OUTDIR"

COMPOSE="docker compose -f compose.mongo.yml"

DRIVERS=(dart-developed dart-pkg go)
WORKLOADS=(C A)
TOPOLOGIES=(1x1 4x4)
# Bulk batch sizes, applied ONLY to the write-heavy (W) workload.
BATCHES=(1)
if [ -n "${BATCH:-}" ]; then read -r -a BATCHES <<< "$BATCH"; fi
if [ -n "${DRIVERS_OVERRIDE:-}" ]; then read -r -a DRIVERS <<< "$DRIVERS_OVERRIDE"; fi
if [ -n "${WORKLOADS_OVERRIDE:-}" ]; then read -r -a WORKLOADS <<< "$WORKLOADS_OVERRIDE"; fi
if [ -n "${TOPOLOGIES_OVERRIDE:-}" ]; then read -r -a TOPOLOGIES <<< "$TOPOLOGIES_OVERRIDE"; fi

wait_mongo_healthy() {
  local timeout=90 elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if $COMPOSE ps mongo --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
      return 0
    fi
    sleep 2; elapsed=$((elapsed + 2))
  done
  echo "[error] mongo not healthy in ${timeout}s" >&2; return 1
}

conns_for() { [ "$1" = "1x1" ] && echo 1 || echo 16; }

run_dart() {
  local driver="$1" wl="$2" topo="$3" batch="$4" csv="$5"
  local flag="native-mongo"
  [ "$driver" = "dart-pkg" ] && flag="mongo-pkg"
  $COMPOSE run --rm bench-dart-mongo \
    --driver "$flag" --workload "$wl" --conns "$(conns_for "$topo")" \
    --ops "$OPS" --records "$RECORDS" --reps "$REPS" --dist "$DIST" \
    --batch "$batch" --topology "$topo" --csv "/outputs/$csv"
}

run_go() {
  local wl="$1" topo="$2" batch="$3" csv="$4"
  $COMPOSE run --rm bench-go-mongo \
    --workload "$wl" --conns "$(conns_for "$topo")" \
    --ops "$OPS" --records "$RECORDS" --reps "$REPS" \
    --batch "$batch" --topology "$topo" --csv "/outputs/$csv"
}

isolated_run() {
  local driver="$1" wl="$2" topo="$3" batch="$4"
  local csv="mongo_${driver}_${wl}_${topo}.csv"
  # Write-heavy runs carry the batch size in the filename so the unitary
  # baseline (b1) and the bulk variants are archived side by side.
  [ "$wl" = "W" ] && csv="mongo_${driver}_${wl}_${topo}_b${batch}.csv"
  echo
  echo "============================================="
  echo "  ISOLATED: $driver wl=$wl $topo batch=$batch  ($(date -u +%H:%M:%S) UTC)"
  echo "============================================="
  $COMPOSE down -v 2>/dev/null || true
  $COMPOSE up -d mongo >/dev/null
  wait_mongo_healthy
  case "$driver" in
    dart-developed|dart-pkg) run_dart "$driver" "$wl" "$topo" "$batch" "$csv" ;;
    go)                      run_go "$wl" "$topo" "$batch" "$csv" ;;
  esac
  $COMPOSE down -v 2>/dev/null || true
  echo "[isolated] cool-down 10s ..."; sleep 10
}

echo "[setup] building images ..."
$COMPOSE build bench-dart-mongo bench-go-mongo 2>&1 | tail -3

for driver in "${DRIVERS[@]}"; do
  rm -f "$OUTDIR"/mongo_${driver}_*.csv
done

start=$(date +%s)
# Count sessions: W workloads fan out over BATCHES; others run once (batch 1).
n=0
for wl in "${WORKLOADS[@]}"; do
  if [ "$wl" = "W" ]; then bcount=${#BATCHES[@]}; else bcount=1; fi
  n=$(( n + ${#DRIVERS[@]} * ${#TOPOLOGIES[@]} * bcount ))
done
echo "[setup] ${#DRIVERS[@]} drivers × ${#WORKLOADS[@]} workloads × ${#TOPOLOGIES[@]} topos = ${n} sessions; OPS=$OPS RECORDS=$RECORDS REPS=$REPS DIST=$DIST BATCH='${BATCHES[*]}'"

for driver in "${DRIVERS[@]}"; do
  for wl in "${WORKLOADS[@]}"; do
    for topo in "${TOPOLOGIES[@]}"; do
      if [ "$wl" = "W" ]; then
        for b in "${BATCHES[@]}"; do
          isolated_run "$driver" "$wl" "$topo" "$b"
        done
      else
        isolated_run "$driver" "$wl" "$topo" 1
      fi
    done
  done
done

end=$(date +%s); elapsed=$((end - start))
echo
echo "[done] ${n} sessions in ${elapsed}s ($((elapsed/60))m $((elapsed%60))s)"
ls -la "$OUTDIR"/mongo_*.csv 2>&1 | tail -20
