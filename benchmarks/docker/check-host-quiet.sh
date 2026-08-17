#!/usr/bin/env bash
# check-host-quiet.sh - refuse to start a battery on a busy machine.
#
# WHY THIS EXISTS
#
#   A full HTTP battery takes hours. Starting one while the host is busy does
#   not produce noisy results that average out; it produces results biased
#   against whichever stack is closest to saturation (see capture-host-load.sh).
#   Discovering that afterwards costs the whole run.
#
#   Checking takes seconds. Do it.
#
# CRITERIA (all must hold, for N consecutive samples)
#   foreign CPU  < MAX_FOREIGN  (default 25%)   nothing else running
#   free memory >= MIN_MEMFREE  (default 50%)   no memory pressure
#   swap not growing between samples            no active paging
#
#   High but STABLE swap does not block: pages parked in swap cost nothing while
#   there is no active paging, and demanding zero swap would force a reboot,
#   which is not this script's call to make.
#
# USAGE
#   check-host-quiet.sh [samples] [interval_s] [max_wait_s]
#     exit 0  host is quiet, safe to start
#     exit 1  gave up waiting; do not measure
#
#   Use samples=1 interval=1 max_wait=1 for a one-shot check that only reports.
set -uo pipefail

NEED="${1:-10}"
INTERVAL="${2:-30}"
MAX_WAIT="${3:-21600}"
MAX_FOREIGN="${MAX_FOREIGN:-25}"
MIN_MEMFREE="${MIN_MEMFREE:-50}"
export LC_ALL=C

probe() {
  ps -Ao pcpu,comm | awk '
    NR == 1 { next }
    { cpu = $1; n = $2
      # Docker Desktop >= 29 on macOS names its VM
      # com.apple.Virtualization.VirtualMachine and it matches none of the other
      # patterns, so without this the gate counts your own containers as foreign
      # contention and never opens once anything is running.
      if (n ~ /[Dd]ocker|qemu|virtiofsd|vpnkit|com\.docker|containerd|Virtualization\.VirtualMachine/) next
      if (n ~ /ps$|awk$|sleep$/) next
      f += cpu
      if (cpu > tc) { tc = cpu; tn = n }
    }
    END { s = tn; sub(/.*\//, "", s); printf "%.1f|%s|%.0f", f+0, (tc > 3 ? s : "-"), tc+0 }'
}
memfree() { memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'; }
swapmb()  { sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.,]*\)M.*/\1/p' | tr ',' '.'; }

echo "[host-quiet] criteria: foreign<${MAX_FOREIGN}%, free>=${MIN_MEMFREE}%, swap stable"

ok=0; t0=$(date +%s); prev_swap=$(swapmb); last=0
while :; do
  IFS='|' read -r foreign topname topcpu <<< "$(probe)"
  mf=$(memfree); sw=$(swapmb)
  growing=$(awk -v a="$sw" -v b="$prev_swap" 'BEGIN{print (a > b + 20) ? 1 : 0}')
  quiet=$(awk -v f="$foreign" -v mx="$MAX_FOREIGN" -v m="${mf:-0}" -v mm="$MIN_MEMFREE" -v g="$growing" \
          'BEGIN{print (f < mx && m >= mm && g == 0) ? 1 : 0}')
  prev_swap="$sw"
  [ "$quiet" = "1" ] && ok=$((ok+1)) || ok=0

  now=$(date +%s); el=$((now - t0))
  if [ "$ok" -ge "$NEED" ]; then
    echo "[host-quiet] QUIET after $((el/60))m - foreign=${foreign}% free=${mf}% swap=${sw}MB"
    exit 0
  fi
  if [ $((now - last)) -ge 300 ] || [ "$el" -lt "$INTERVAL" ]; then
    echo "[host-quiet] $((el/60))m | foreign=${foreign}% (top: ${topname} ${topcpu}%) free=${mf}% swap=${sw}MB growing=${growing} | quiet ${ok}/${NEED}"
    last=$now
  fi
  if [ "$el" -ge "$MAX_WAIT" ]; then
    echo "[host-quiet] gave up after $((MAX_WAIT/60))m - refusing to measure under contention"
    exit 1
  fi
  sleep "$INTERVAL"
done
