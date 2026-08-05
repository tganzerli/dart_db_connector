#!/usr/bin/env bash
# Cross-language MySQL TPC-C bench under STRICT ISOLATION. 
#
# Every (driver, topology) is its own isolated Docker session:
#   1. compose down -v         (purge containers + volumes)
#   2. up mysql fresh + wait healthy (init creates the `bench` user)
#   3. apply schema + seed (fresh DB, once per session)
#   4. one bench (REPS × TX_COUNT)
#   5. down -v
#   6. cool down 10s
#
# Drivers: dart-developed (libnative_mysql), dart-pkg (mysql_client pub.dev),
#          go (go-sql-driver/mysql). Topologies: 1x1 (1 conn) and 4x4 (16 conns).
# Output: docker/bench/outputs/mysql_<driver>_<topo>.csv
#
# Usage: cd docker/bench && bash run-driver-mysql.sh
# Env: TX_COUNT (5000), REPS (3), TPCC_WAREHOUSES (3), OUTDIR (./outputs)

set -euo pipefail
cd "$(dirname "$0")"

export TX_COUNT="${TX_COUNT:-5000}"
export REPS="${REPS:-3}"
export TPCC_WAREHOUSES="${TPCC_WAREHOUSES:-3}"
OUTDIR="${OUTDIR:-./outputs}"
mkdir -p "$OUTDIR"

COMPOSE="docker compose -f compose.mysql.yml"

DRIVERS=(dart-developed dart-pkg go)
TOPOLOGIES=(1x1 4x4)
if [ -n "${DRIVERS_OVERRIDE:-}" ]; then read -r -a DRIVERS <<< "$DRIVERS_OVERRIDE"; fi
if [ -n "${TOPOLOGIES_OVERRIDE:-}" ]; then read -r -a TOPOLOGIES <<< "$TOPOLOGIES_OVERRIDE"; fi

wait_mysql_healthy() {
  local timeout=90 elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if $COMPOSE ps mysql --format json 2>/dev/null | grep -q '"Health":"healthy"'; then
      return 0
    fi
    sleep 2; elapsed=$((elapsed + 2))
  done
  echo "[error] mysql not healthy in ${timeout}s" >&2; return 1
}

# Apply schema (as bench user) then seed the base data via the developed
# driver's seed-only mode. Runs inside the bench-dart-mysql container.
seed_db() {
  $COMPOSE run --rm --entrypoint /bin/bash bench-dart-mysql -c \
    "mysql --skip-ssl -h mysql -u bench -p123 teste < /app/tpcc_schema_mysql.sql \
     && /app/bench_tpcc_mysql --driver native-mysql --seed-db --tx-count 0" \
    >/dev/null
}

conns_for() { [ "$1" = "1x1" ] && echo 1 || echo 16; }

run_dart() {
  local driver="$1" topo="$2" csv="$3"
  local flag="native-mysql"
  [ "$driver" = "dart-pkg" ] && flag="mysql-pkg"
  [ "$driver" = "dart-batched" ] && flag="native-mysql-batched"
  [ "$driver" = "dart-readmulti" ] && flag="native-mysql-readmulti"
  $COMPOSE run --rm bench-dart-mysql \
    --driver "$flag" --conns "$(conns_for "$topo")" \
    --tx-count "$TX_COUNT" --reps "$REPS" --topology "$topo" \
    --csv "/outputs/$csv"
}

run_go() {
  local topo="$1" csv="$2" workers cpw
  if [ "$topo" = "1x1" ]; then workers=1; cpw=1; else workers=4; cpw=4; fi
  $COMPOSE run --rm bench-go-mysql \
    --workers "$workers" --conns-per-worker "$cpw" \
    --tx-count "$TX_COUNT" --reps "$REPS" --topology "$topo" \
    --csv "/outputs/$csv"
}

isolated_run() {
  local driver="$1" topo="$2"
  local csv="mysql_${driver}_${topo}.csv"
  echo
  echo "============================================="
  echo "  ISOLATED SESSION: $driver $topo  ($(date -u +%H:%M:%S) UTC)"
  echo "============================================="
  $COMPOSE down -v 2>/dev/null || true
  $COMPOSE up -d mysql >/dev/null
  wait_mysql_healthy
  seed_db
  case "$driver" in
    dart-developed|dart-pkg|dart-batched|dart-readmulti) run_dart "$driver" "$topo" "$csv" ;;
    go)                                                   run_go "$topo" "$csv" ;;
  esac
  $COMPOSE down -v 2>/dev/null || true
  echo "[isolated] cool-down 10s ..."; sleep 10
}

echo "[setup] building images ..."
$COMPOSE build bench-dart-mysql bench-go-mysql 2>&1 | tail -3

for driver in "${DRIVERS[@]}"; do
  rm -f "$OUTDIR"/mysql_${driver}_*.csv
done

start=$(date +%s)
n=$(( ${#DRIVERS[@]} * ${#TOPOLOGIES[@]} ))
echo "[setup] ${#DRIVERS[@]} drivers × ${#TOPOLOGIES[@]} topologies = ${n} sessions; TX=$TX_COUNT REPS=$REPS WAREHOUSES=$TPCC_WAREHOUSES"

for driver in "${DRIVERS[@]}"; do
  for topo in "${TOPOLOGIES[@]}"; do
    isolated_run "$driver" "$topo"
  done
done

end=$(date +%s); elapsed=$((end - start))
echo
echo "[done] ${n} sessions in ${elapsed}s ($((elapsed/60))m $((elapsed%60))s)"
ls -la "$OUTDIR"/mysql_*.csv 2>&1 | tail -10
