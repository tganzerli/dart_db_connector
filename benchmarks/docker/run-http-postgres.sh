#!/usr/bin/env bash
# HTTP end-to-end cross-language benchmark against PostgreSQL, with N
# independent sessions per cell and 95% confidence intervals.
#
# Applies the independent-session loop of run-driver-postgres.sh (TPC-C) to the
# HTTP layer. Every (stack, endpoint, topology, vCPU, session) combination is an
# isolated Docker session: down -v -> fresh postgres -> seed -> start server ->
# warmup -> sustained wrk -> down -v. The per-session mean is the unit of
# inference.
#
# Loop order: vCPU -> session -> stack -> endpoint -> topology. Sampling each
# stack across the whole time window keeps temporal drift from loading onto any
# single stack. One CSV per cell, REPS rows each.
#
# Output: outputs/http-postgres/http_<stack>_<endpoint>_<topo>_c<vcpu>_s<session>.csv
#         Columns: stack,endpoint,topology,vcpu,session,rep,rps,p50_us,p75_us,p90_us,p99_us
set -euo pipefail
cd "$(dirname "$0")"

SESSIONS="${SESSIONS:-5}"
VCPUS="${VCPUS:-2 4}"
REPS="${REPS:-1}"
WARMUP_SEC="${WARMUP_SEC:-20}"
SUSTAINED_SEC="${SUSTAINED_SEC:-45}"
WRK_THREADS="${WRK_THREADS:-2}"
WRK_CONNS="${WRK_CONNS:-64}"
OUTDIR="${OUTDIR:-./outputs/http-postgres}"
LOGFILE="${OUTDIR}/run.log.jsonl"
mkdir -p "$OUTDIR"

STACKS=(dart-native dart-pkg go rust node python java)
ENDPOINTS=(plaintext json db queries updates fortunes)
TOPOLOGIES=(1 64)
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --stacks) IFS=',' read -r -a STACKS <<< "$2"; shift 2 ;;
    --endpoints) IFS=',' read -r -a ENDPOINTS <<< "$2"; shift 2 ;;
    --topologies) IFS=',' read -r -a TOPOLOGIES <<< "$2"; shift 2 ;;
    --vcpus) VCPUS="$2"; shift 2 ;;
    --sessions) SESSIONS="$2"; shift 2 ;;
    --reps) REPS="$2"; shift 2 ;;
    *) echo "[error] unknown arg: $1" >&2; exit 2 ;;
  esac
done
read -r -a VCPU_ARR <<< "$VCPUS"

log_event() {
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  python3 -c "
import json, sys
d = dict(ts='$ts')
for kv in sys.argv[1:]:
    k, _, v = kv.partition('=')
    d[k] = v
print(json.dumps(d, ensure_ascii=False))
" "$@" >> "$LOGFILE"
}
wait_postgres_healthy() {
  local timeout=60 elapsed=0
  while [ $elapsed -lt $timeout ]; do
    docker compose ps postgres --format json 2>/dev/null | grep -q '"Health":"healthy"' && return 0
    sleep 1; elapsed=$((elapsed + 1))
  done
  echo "[error] postgres not healthy within ${timeout}s" >&2; return 1
}
seed_db() {
  docker compose run --rm --entrypoint /bin/sh postgres \
    -c "PGPASSWORD=123 psql -h postgres -U postgres -d teste -q -f /fixtures/te_schema.sql" \
    >/dev/null 2>&1 || \
  docker run --rm --network ddc-bench-net -v "$(pwd)/../../benchmarks/fixtures:/fixtures:ro" \
    -e PGPASSWORD=123 postgres:16-alpine \
    psql -h postgres -U postgres -d teste -q -f /fixtures/te_schema.sql >/dev/null
}
wait_http_ready() {
  local service="$1" timeout=45 elapsed=0
  while [ $elapsed -lt $timeout ]; do
    docker run --rm --network ddc-bench-net curlimages/curl:latest \
      -sf --max-time 1 "http://${service}:8080/plaintext" >/dev/null 2>&1 && return 0
    sleep 1; elapsed=$((elapsed + 1))
  done
  return 1
}
endpoint_path() {
  case "$1" in
    plaintext) echo "/plaintext" ;; json) echo "/json" ;; db) echo "/db" ;;
    queries) echo "/queries?count=20" ;; updates) echo "/updates?count=20" ;; fortunes) echo "/fortunes" ;;
    *) echo "[error] endpoint desconhecido: $1" >&2; return 2 ;;
  esac
}

isolated_run() {
  local stack="$1" endpoint="$2" topology="$3" vcpu="$4" session="$5" rep="$6"
  local service="http-${stack}"
  local out="${OUTDIR}/http_${stack}_${endpoint}_${topology}_c${vcpu}_s${session}.csv"

  if [ "$DRY_RUN" = "1" ]; then echo "[dry] $stack $endpoint t=$topology c=$vcpu s=$session r=$rep"; return 0; fi

  # Opt-in resume (default off — no behaviour change unless SKIP_EXISTING=1):
  # skip combos whose CSV already has a data row. Lets a reaped background run
  # be relaunched and pick up where it stopped (counts CSVs, not completion markers).
  if [ "${SKIP_EXISTING:-0}" = "1" ] && [ -f "$out" ] && [ "$(wc -l < "$out")" -ge 2 ]; then
    echo "[skip] existe: $out"
    log_event event=skip reason=exists stack="$stack" endpoint="$endpoint" topology="$topology" vcpu="$vcpu" session="$session" rep="$rep"
    return 0
  fi

  docker compose down -v 2>/dev/null || true
  export HTTP_CPUS="$vcpu" POSTGRES_CPUS="$vcpu"
  docker compose up -d postgres >/dev/null
  wait_postgres_healthy || { log_event event=fail reason=pg stack="$stack"; return 1; }
  seed_db || { log_event event=fail reason=seed stack="$stack"; return 1; }
  POOL_SIZE="$topology" docker compose up -d "$service" >/dev/null \
    || { log_event event=fail reason=up stack="$stack"; return 1; }
  wait_http_ready "$service" || { log_event event=fail reason=notready stack="$stack"; docker compose down -v 2>/dev/null||true; return 1; }

  local url; url=$(endpoint_path "$endpoint")
  # warmup (descartado)
  docker compose run --rm --no-deps --entrypoint /usr/local/bin/wrk bench-loader \
    -t"$WRK_THREADS" -c"$WRK_CONNS" -d"${WARMUP_SEC}s" -H "Connection: keep-alive" \
    "http://${service}:8080${url}" >/dev/null 2>&1 || true
  # sustained (medido)
  local wrk_stdout; wrk_stdout=$(docker compose run --rm --no-deps --entrypoint /usr/local/bin/wrk bench-loader \
    -t"$WRK_THREADS" -c"$WRK_CONNS" -d"${SUSTAINED_SEC}s" --latency -H "Connection: keep-alive" \
    "http://${service}:8080${url}" 2>&1 || true)

  WRK_STDOUT="$wrk_stdout" STACK="$stack" ENDPOINT="$endpoint" TOPOLOGY="$topology" \
  VCPU="$vcpu" SESSION="$session" REP="$rep" WRK_OUT="$out" \
  python3 <<'EOF' >> "$out"
import os, re
out=os.environ["WRK_STDOUT"]
def grab(p,d="NaN"):
    m=re.search(p,out,re.MULTILINE); return m.group(1) if m else d
rps=grab(r"^\s*Requests/sec:\s+([\d.]+)")
def pct(p):
    m=re.search(rf"^\s*{p}(?:\.0+)?%\s+([\d.]+)(us|ms|s)\b",out,re.MULTILINE)
    if not m: return "NaN"
    v=float(m.group(1)); u=m.group(2); return str(v*(1 if u=='us' else 1000 if u=='ms' else 1_000_000))
p50,p75,p90,p99=pct("50"),pct("75"),pct("90"),pct("99")
w=os.environ["WRK_OUT"]
if (not os.path.exists(w)) or os.path.getsize(w)==0:
    print("stack,endpoint,topology,vcpu,session,rep,rps,p50_us,p75_us,p90_us,p99_us")
print(f"{os.environ['STACK']},{os.environ['ENDPOINT']},{os.environ['TOPOLOGY']},{os.environ['VCPU']},{os.environ['SESSION']},{os.environ['REP']},{rps},{p50},{p75},{p90},{p99}")
EOF

  docker compose down -v 2>/dev/null || true
  log_event event=ok stack="$stack" endpoint="$endpoint" topology="$topology" vcpu="$vcpu" session="$session" rep="$rep"
  sleep 5
}

if [ "$DRY_RUN" != "1" ]; then
  echo "[setup] build bench-loader ..."; docker compose build bench-loader 2>&1 | tail -2 || true
fi
n=$(( ${#VCPU_ARR[@]} * SESSIONS * ${#STACKS[@]} * ${#ENDPOINTS[@]} * ${#TOPOLOGIES[@]} * REPS ))
echo "[setup] $(date -u +%FT%TZ) | ${#VCPU_ARR[@]} vCPU × ${SESSIONS} sessões × ${#STACKS[@]} stacks × ${#ENDPOINTS[@]} endpoints × ${#TOPOLOGIES[@]} pool × ${REPS} reps = ${n} runs"
log_event event=session-start n="$n" vcpus="$VCPUS" sessions="$SESSIONS" stacks="${STACKS[*]}" endpoints="${ENDPOINTS[*]}" topologies="${TOPOLOGIES[*]}" reps="$REPS"

start=$(date +%s); failed=0; done_n=0
for vcpu in "${VCPU_ARR[@]}"; do
  for session in $(seq 1 "$SESSIONS"); do
    for stack in "${STACKS[@]}"; do
      for endpoint in "${ENDPOINTS[@]}"; do
        for topology in "${TOPOLOGIES[@]}"; do
          for rep in $(seq 1 "$REPS"); do
            echo "########## c=$vcpu s=$session/$SESSIONS | $stack $endpoint pool=$topology r=$rep ($(date -u +%H:%M:%S)Z) ##########"
            if ! isolated_run "$stack" "$endpoint" "$topology" "$vcpu" "$session" "$rep"; then
              failed=$((failed+1)); echo "[retry] $stack $endpoint $topology c=$vcpu s=$session"
              isolated_run "$stack" "$endpoint" "$topology" "$vcpu" "$session" "$rep" || echo "[skip] falha dupla: $stack $endpoint $topology c=$vcpu s=$session"
            fi
            done_n=$((done_n+1))
          done
        done
      done
    done
  done
done
end=$(date +%s); el=$((end-start))
echo "[done] ${done_n} runs em $((el/3600))h $(((el%3600)/60))m; ${failed} retries"
log_event event=session-end elapsed_s="$el" retries="$failed"
