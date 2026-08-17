#!/usr/bin/env bash
# capture-host-load.sh - record what the HOST is doing during a benchmark run.
#
# WHY THIS EXISTS
#
#   Container-level instrumentation (docker stats, cgroup counters) tells you
#   what the workload consumed. It cannot tell you what ELSE was competing for
#   the machine. That blind spot is expensive: on the reference bench host a
#   throughput drop was attributed twice to the wrong cause -- first to the
#   measurement collector, then to swap pressure -- before anyone measured the
#   host itself and found background maintenance daemons taking more than a full
#   core.
#
#   The effect is not uniform, which is what makes it dangerous. It penalises
#   whichever stack is closest to saturating the machine and leaves the slower
#   ones untouched, so it does not average out: it silently reorders a
#   cross-stack comparison. On the reference host, background load of ~130% of
#   one CPU cost the two fastest stacks 17-29% of their throughput and had no
#   measurable effect on the rest.
#
#   Run this alongside any battery whose absolute numbers you intend to publish,
#   then join it against your run log by timestamp. A cell measured while
#   `foreign_cpu_pct` was high is a cell you cannot defend.
#
# COST, MEASURED BEFORE USE
#   16.0 ms per sample; at one sample per 10 s that is 0.16% of one core.
#   Measure your instrument before you trust it.
#
# COLUMNS
#   total_cpu_pct    every process on the machine
#   docker_cpu_pct   the Docker VM and helpers -- this IS your benchmark
#   daemon_cpu_pct   OS maintenance (macOS: Spotlight, photo analysis)
#   foreign_cpu_pct  everything else: the number that must stay low
#   top_foreign      name and cost of the largest foreign consumer, so an
#                    unknown contaminant is diagnosable and not merely visible
#
# NOTE ON PORTABILITY
#   Written for macOS hosts, where Docker runs inside a VM and the host OS
#   schedules its own maintenance work. On a dedicated Linux server the same
#   idea applies with different process names; adjust the awk patterns.
#
# USAGE
#   capture-host-load.sh <output.csv> [interval_s]   # runs until SIGTERM
set -uo pipefail

# A comma decimal separator (pt-BR, de-DE, fr-FR, ...) splits a CSV field in
# two. Forcing C here is required, not cosmetic.
export LC_ALL=C LC_NUMERIC=C

OUT="${1:?output csv path}"
INTERVAL="${2:-10}"

[ -f "$OUT" ] || echo "ts_epoch,iso,daemon_cpu_pct,load1,swap_used_mb,mem_free_pct,total_cpu_pct,docker_cpu_pct,foreign_cpu_pct,top_foreign" > "$OUT"

# One `ps` feeds all four aggregates, to avoid paying for four scans.
emit() {
  local snap load swap memfree
  snap=$(ps -Ao pcpu,comm | awk '
    NR == 1 { next }
    {
      cpu = $1; name = $2
      total += cpu
      # The watched list is deliberately wide. A narrower earlier version
      # reported daemon = 0.0% for an entire battery while Spotlight knowledge
      # indexing and APFS maintenance were between them taking 117% of a core.
      # Watching only the daemons you already suspect reproduces, in miniature,
      # the blind spot this file exists to close. Assume the list is still
      # incomplete -- that is why `foreign` is recorded next to it.
      if (name ~ /mediaanalysisd|mds|mdworker|photoanalysisd|spotlightknowledged|apfsd|XprotectService|mobileassetd/) { daemon += cpu; next }
      # Docker Desktop >= 29 on macOS runs its VM as
      # com.apple.Virtualization.VirtualMachine, which matches none of the
      # patterns below. Without this clause the VM -- that is, YOUR BENCHMARK --
      # lands in `foreign` at 300-800% and the covariate becomes unusable.
      if (name ~ /[Dd]ocker|qemu|virtiofsd|vpnkit|com\.docker|containerd|Virtualization\.VirtualMachine/) { dock += cpu; next }
      if (name ~ /ps$|awk$|sleep$/)                                        { next }
      foreign += cpu
      if (cpu > topcpu) { topcpu = cpu; topname = name }
    }
    END {
      n = topname; sub(/.*\//, "", n)
      printf "%.1f,%.1f,%.1f,%.1f,%s", total+0, dock+0, daemon+0, foreign+0,
             (topcpu > 3 ? n "(" sprintf("%.0f", topcpu) "%)" : "-")
    }')
  load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}' | tr ',' '.')
  swap=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.,]*\)M.*/\1/p' | tr ',' '.')
  memfree=$(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')
  local total dock daemon foreign top
  IFS=, read -r total dock daemon foreign top <<< "$snap"
  echo "$(date +%s),$(date -u +%FT%TZ),${daemon:-0},${load:-0},${swap:-0},${memfree:-0},${total:-0},${dock:-0},${foreign:-0},${top:--}" >> "$OUT"
}

trap 'emit; exit 0' TERM INT
while true; do emit; sleep "$INTERVAL"; done
