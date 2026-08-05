#!/usr/bin/env bash
# capture-docker-stats.sh — sample `docker stats` for a single container
# at ~1 Hz and append rows to a CSV.
#
# Usage:
#   capture-docker-stats.sh <container_name> <output_csv> [duration_seconds]
#
# - container_name : the running HTTP target (e.g. ddc-bench-http-go).
# - output_csv     : path where rows are appended; header is written if
#                    the file does not yet exist.
# - duration_seconds : optional cap (default: run until killed).
#
# CSV header: ts,cpu_pct,mem_mib
#
# Notes:
#   * Uses `docker stats --no-stream` per tick (cheaper than streaming
#     mode; ~50 ms overhead per call).
#   * MemUsage format is "X.YZ MiB / N GiB" — extract the first value
#     and normalise to MiB.
#   * Sampling drift under load is acceptable for our purposes; we
#     average and take peak after the fact.

set -euo pipefail

container="${1:?container name required}"
out="${2:?output CSV path required}"
duration="${3:-0}"

if [ ! -f "$out" ]; then
  echo "ts,cpu_pct,mem_mib" > "$out"
fi

start_epoch=$(date +%s)

while true; do
  ts=$(date +%s.%N)
  # `--format` keeps the read parseable. Suppress errors so a transient
  # missing container doesn't crash the loop — we'll just emit no row
  # that tick.
  line=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "$container" 2>/dev/null || true)
  if [ -n "$line" ]; then
    cpu_raw="${line%%|*}"
    mem_raw="${line##*|}"
    # cpu_raw e.g. "153.42%"; strip %.
    cpu_pct="${cpu_raw%\%}"
    # mem_raw e.g. "123.4MiB / 4GiB"; take the first token and
    # normalise units (MiB → MiB; KiB → /1024; GiB → *1024; B → /1024/1024).
    mem_used="${mem_raw%% / *}"
    # Strip spaces and split number/unit.
    mem_used="${mem_used// /}"
    if [[ "$mem_used" =~ ^([0-9.]+)([A-Za-z]+)$ ]]; then
      v="${BASH_REMATCH[1]}"
      u="${BASH_REMATCH[2]}"
      case "$u" in
        B)         mem_mib=$(awk -v v="$v" 'BEGIN{printf "%.4f", v/1048576}') ;;
        KiB|kB)    mem_mib=$(awk -v v="$v" 'BEGIN{printf "%.4f", v/1024}') ;;
        MiB|MB)    mem_mib="$v" ;;
        GiB|GB)    mem_mib=$(awk -v v="$v" 'BEGIN{printf "%.4f", v*1024}') ;;
        *)         mem_mib="$v" ;;
      esac
    else
      mem_mib="0"
    fi
    echo "$ts,$cpu_pct,$mem_mib" >> "$out"
  fi

  if [ "$duration" -gt 0 ]; then
    now=$(date +%s)
    elapsed=$((now - start_epoch))
    if [ "$elapsed" -ge "$duration" ]; then
      break
    fi
  fi
  sleep 1
done
