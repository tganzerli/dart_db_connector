#!/usr/bin/env bash
# Extract wall-clock TPS from the robust runner's per-session .log files
# into a single versioned CSV: robust_tps.csv (driver,topology,session,rep,tps).
#
# TPS lives ONLY in runner stdout (metrics.dart CSV has no TPS column). The
# robust runner tee's every session to <stem>_s<N>.log; here we parse the
# per-rep lines. All 7 harnesses share the vocabulary (execution log D2):
#   [rep <N>] ... tps=<float>
#   TPS avg across reps: <float>   (aggregate — session mean; recomputed here)
#
# Filename shape: robust_<driver>_<topo>_s<N>.log  (driver has no '_').
#
# Usage: cd docker/bench && bash extract-throughput.sh [OUTDIR]
# Output: $OUTDIR/robust_tps.csv

set -euo pipefail
cd "$(dirname "$0")"
OUTDIR="${1:-./outputs}"
OUT="$OUTDIR/robust_tps.csv"

echo "driver,topology,session,rep,tps" > "$OUT"

shopt -s nullglob
n=0
for log in "$OUTDIR"/robust_*_s*.log; do
  base="$(basename "$log" .log)"        # robust_<driver>_<topo>_s<N>
  rest="${base#robust_}"                 # <driver>_<topo>_s<N>
  session="${rest##*_s}"                 # N
  wo_session="${rest%_s*}"               # <driver>_<topo>
  topo="${wo_session##*_}"               # 1x1 | 4x4
  driver="${wo_session%_*}"              # <driver> (may contain '-')

  # Per-rep TPS lines, in order. Portable (BSD/GNU grep+sed; no gawk arrays):
  # grep pulls each "[rep N] ... tps=X" line, sed rewrites it to "N,X".
  grep -oE '\[rep [0-9]+\].*tps=[0-9]+\.[0-9]+' "$log" 2>/dev/null \
    | sed -E 's/\[rep ([0-9]+)\].*tps=([0-9]+\.[0-9]+)/\1,\2/' \
    | while IFS=, read -r rep tps; do
        printf '%s,%s,%s,%s,%s\n' "$driver" "$topo" "$session" "$rep" "$tps"
      done >> "$OUT"
  n=$((n + 1))
done
shopt -u nullglob

rows=$(($(wc -l < "$OUT") - 1))
echo "[extract-tps] parsed $n logs → $rows rep-rows in $OUT"
if [ "$rows" -eq 0 ]; then
  echo "[extract-tps][warn] no TPS rows parsed — check log format / regex" >&2
fi
