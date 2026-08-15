#!/usr/bin/env bash
# capture-cgroup-stats.sh - container CPU and memory, read straight from cgroup v2.
#
# WHY THIS EXISTS, next to capture-docker-stats.sh
#
#   Measured on the reference host (macOS, Docker Desktop, VM kernel 6.12
#   linuxkit, cgroup v2):
#
#     docker stats --no-stream    1050 to 2000 ms per sample
#     direct cgroup read          0.25 to 0.35 ms per sample
#
#   Three orders of magnitude. The CLI has to reach the daemon, and to produce a
#   percentage Docker needs two reads about a second apart. At 5 Hz this helper
#   spends ~1.5 ms per second, roughly 0.15% of one core.
#
#   ACCURACY IS THE STRONGER REASON. `cpu.stat:usage_usec` is a cumulative
#   counter, so CPU over a window is (delta usage / delta wall clock) -- exact,
#   rather than an average of sampled percentages. It is also the model
#   production monitoring consumes (counter plus rate), whereas `docker stats`
#   is a developer tool. Sampled percentages let a container appear to exceed
#   its own quota: on a 4-CPU limit we recorded 467%, 476% and 420%, which is
#   physically impossible. A cumulative counter cannot exceed the quota by
#   construction. Checking whether a measurement respects the container's limit
#   is the cheapest sanity test available, and it is worth wiring in.
#
# LIMITATION, STATED PLAINLY
#
#   `memory.peak` is NOT resettable on this kernel: the write returns success
#   and is ignored (verified with a read-write mount and --privileged). So:
#     mem_peak_bytes    exact peak since container CREATION (includes startup);
#                       exact, but scoped to the session, not to the window.
#     per-window peak   max(mem_current_bytes), still a sampled estimate -- but
#                       at 5 Hz that is ~225 samples in a 45 s window.
#   Report both and say which is which. A sampled peak is a floor, not a peak.
#
# THROTTLING
#
#   nr_periods, nr_throttled and throttled_usec come from the same cpu.stat that
#   is already being read, so they cost nothing extra, and they measure directly
#   how much the CPU quota BLOCKED the workload -- that is, how close to its
#   ceiling a stack ran. That turned out to be the variable that decides which
#   stacks suffer from host contention and which shrug it off.
#
# The helper container starts BEFORE the load and is removed AFTER, so no CLI
# call happens inside the measured window.
#
# CSV: ts_epoch,uptime_s,usage_usec,user_usec,system_usec,mem_current_bytes,
#      mem_peak_bytes,nr_periods,nr_throttled,throttled_usec
#      Use `uptime_s` (/proc/uptime, monotonic, centiseconds) for deltas. Do NOT
#      use ts_epoch: BusyBox `date` has no %N, so it resolves to whole seconds.
#      The first and last rows give the exact window boundaries.
#
# USAGE
#   capture-cgroup-stats.sh start <target_container> <output.csv> [interval_s]
#   capture-cgroup-stats.sh stop  <target_container>
set -euo pipefail

SIDECAR_IMAGE="${SIDECAR_IMAGE:-alpine:3.20}"
CGSTAT_INTERVAL_DEFAULT="${CGSTAT_INTERVAL_DEFAULT:-0.2}"

sidecar_name() { echo "bench-cgstat-${1}"; }

cmd_start() {
  local target="${1:?target container}" out="${2:?output csv}"
  local interval="${3:-$CGSTAT_INTERVAL_DEFAULT}"
  local name; name=$(sidecar_name "$target")

  # Pre-emptive removal: a helper leaked by a previous window dies here, by
  # deterministic name. Makes leak accumulation impossible.
  docker rm -f "$name" >/dev/null 2>&1 || true

  local cid
  cid=$(docker inspect -f '{{.Id}}' "$target" 2>/dev/null) || {
    echo "[cgstat] target '$target' not found" >&2; return 1; }

  local outdir outfile
  outdir=$(cd "$(dirname "$out")" && pwd)
  outfile=$(basename "$out")

  docker run -d --name "$name" \
    --cgroupns=host \
    -v /sys/fs/cgroup:/hostcg:ro \
    -v "${outdir}:/out" \
    -e CID="$cid" -e OUTFILE="$outfile" -e INTERVAL="$interval" \
    "$SIDECAR_IMAGE" sh -c '
      d="/hostcg/docker/$CID"
      [ -d "$d" ] || d=$(find /hostcg -maxdepth 4 -type d -name "$CID*" 2>/dev/null | head -1)
      [ -d "$d" ] || { echo "cgroup not found for $CID" >&2; exit 1; }

      f="/out/$OUTFILE"
      [ -f "$f" ] || echo "ts_epoch,uptime_s,usage_usec,user_usec,system_usec,mem_current_bytes,mem_peak_bytes,nr_periods,nr_throttled,throttled_usec" > "$f"

      # A single awk per sample (~0.25 ms) instead of two awks and two cats.
      emit() {
        awk -v ts="$(date +%s)" -v up="$(cut -d" " -f1 /proc/uptime)" "
          FILENAME ~ /cpu.stat/ {
            if (\$1 == \"usage_usec\")     u  = \$2
            if (\$1 == \"user_usec\")      us = \$2
            if (\$1 == \"system_usec\")    sy = \$2
            if (\$1 == \"nr_periods\")     np = \$2
            if (\$1 == \"nr_throttled\")   nt = \$2
            if (\$1 == \"throttled_usec\") tu = \$2
          }
          FILENAME ~ /memory.current/ { mc = \$1 }
          FILENAME ~ /memory.peak/    { mp = \$1 }
          END { if (u != \"\") print ts \",\" up \",\" u \",\" us \",\" sy \",\" mc \",\" mp \",\" np+0 \",\" nt+0 \",\" tu+0 }
        " "$d/cpu.stat" "$d/memory.current" "$d/memory.peak" >> "$f" 2>/dev/null || true
      }

      # Guaranteed final row on shutdown, so the closing boundary is exact even
      # when the helper is stopped mid-sleep.
      trap "emit; exit 0" TERM INT

      emit
      while true; do sleep "$INTERVAL" & wait $!; emit; done
    ' >/dev/null
}

cmd_stop() {
  local target="${1:?target container}"
  local name; name=$(sidecar_name "$target")
  # SIGTERM first, so the trap writes the closing boundary before removal.
  docker stop -t 3 "$name" >/dev/null 2>&1 || true
  docker rm -f "$name"     >/dev/null 2>&1 || true
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop)  shift; cmd_stop  "$@" ;;
  *) grep '^# ' "$0" | sed 's/^# //' >&2; exit 2 ;;
esac
