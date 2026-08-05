#!/usr/bin/env python3
"""SVGs for the final robust cross-language TPC-C bench — WITH error bars.


Reads the aggregator outputs (robust_tps_stats.csv, robust_p99_stats.csv) and
renders hand-rolled SVGs (no matplotlib — arm64 lesson, benchmark_protocol_rule
§4.7). TPS bars carry IC 95% whiskers (this is the deliverable that the May
`aggregate-driver.py` lacked — it drew plain bars only).

Outputs (into outputs_dir):
  - <DATE>_tpcc-cross-language-final-robust_1x1_tps.svg   (TPS ± IC95)
  - <DATE>_tpcc-cross-language-final-robust_4x4_tps.svg   (TPS ± IC95)
  - <DATE>_tpcc-cross-language-final-robust_1x1_p99.svg   (p99 by tx_type, log)
  - <DATE>_tpcc-cross-language-final-robust_4x4_p99.svg   (p99 by tx_type, log)

Usage: python3 plot-driver.py [outputs_dir] [DATE]
"""

import csv
import math
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "./outputs"
DATE = sys.argv[2] if len(sys.argv) > 2 else "REPLACE_DATE"
STEM = f"{OUT}/{DATE}_tpcc-cross-language-final-robust"

DRIVERS = [
    ("dart-developed", "Dart developed", "#0072B2"),
    ("dart-pkg", "Dart Pkg 3.5.11", "#56B4E9"),
    ("go", "Go pgx", "#009E73"),
    ("node", "Node postgres.js", "#E69F00"),
    ("python", "Python asyncpg", "#F0E442"),
    ("rust", "Rust tokio-postgres", "#D55E00"),
    ("java", "Java pgjdbc", "#CC79A7"),
]
COLOR = {k: c for k, _, c in DRIVERS}
LABEL = {k: l for k, l, _ in DRIVERS}
TX_ORDER = ["newOrder", "payment", "orderStatus", "delivery", "stockLevel"]


def load_tps_stats(outdir):
    """-> {topo: {driver: (mean, lo, hi, cv)}}"""
    out = {}
    with open(f"{outdir}/robust_tps_stats.csv") as f:
        for r in csv.DictReader(f):
            out.setdefault(r["topology"], {})[r["driver"]] = (
                float(r["mean_tps"]), float(r["ci95_lo"]),
                float(r["ci95_hi"]), float(r["cv_pct"]))
    return out


def load_p99_stats(outdir):
    """-> {topo: {tx_type: {driver: p99}}}"""
    out = {}
    with open(f"{outdir}/robust_p99_stats.csv") as f:
        for r in csv.DictReader(f):
            out.setdefault(r["topology"], {}).setdefault(r["tx_type"], {})[r["driver"]] = int(r["p99"])
    return out


def render_tps_bar(title, stats, out_path):
    """One bar per driver with IC95 whiskers."""
    W, H = 940, 480
    ml, mr, mt, mb = 80, 30, 60, 130
    pw, ph = W - ml - mr, H - mt - mb
    drivers = [d for d in DRIVERS if d[0] in stats]
    max_v = max(stats[k][2] for k, _, _ in drivers)  # top whisker
    mag = 10 ** math.floor(math.log10(max_v))
    y_max = next((m * mag for m in (1, 2, 5, 10, 20) if m * mag >= max_v), max_v)

    def yp(v):
        return mt + ph - v / y_max * ph

    n = len(drivers)
    bw = pw / (n * 1.4)
    gap = (pw - bw * n) / (n + 1)
    L = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
         f'font-family="-apple-system, system-ui, sans-serif" font-size="12">',
         f'<rect width="{W}" height="{H}" fill="white"/>',
         f'<text x="{W/2}" y="30" text-anchor="middle" font-size="16" font-weight="bold">{title}</text>',
         f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+ph}" stroke="black"/>']
    for i in range(6):
        v = y_max * i / 5
        y = yp(v)
        L.append(f'<line x1="{ml-5}" y1="{y}" x2="{ml}" y2="{y}" stroke="black"/>')
        L.append(f'<text x="{ml-8}" y="{y+4}" text-anchor="end">{int(v)}</text>')
        L.append(f'<line x1="{ml}" y1="{y}" x2="{ml+pw}" y2="{y}" stroke="#e0e0e0" stroke-dasharray="2,2"/>')
    L.append(f'<text x="20" y="{mt+ph/2}" text-anchor="middle" '
             f'transform="rotate(-90 20 {mt+ph/2})">TPS (mean across sessions +/- CI 95%)</text>')
    L.append(f'<line x1="{ml}" y1="{mt+ph}" x2="{ml+pw}" y2="{mt+ph}" stroke="black"/>')
    for bi, (k, label, color) in enumerate(drivers):
        mean, lo, hi, cv = stats[k]
        x = ml + gap + bi * (bw + gap)
        y = yp(mean)
        h = mt + ph - y
        L.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{h:.1f}" '
                 f'fill="{color}" stroke="white" stroke-width="0.5"/>')
        # IC95 whisker
        cx = x + bw / 2
        L.append(f'<line x1="{cx:.1f}" y1="{yp(hi):.1f}" x2="{cx:.1f}" y2="{yp(lo):.1f}" stroke="black" stroke-width="1.5"/>')
        L.append(f'<line x1="{cx-5:.1f}" y1="{yp(hi):.1f}" x2="{cx+5:.1f}" y2="{yp(hi):.1f}" stroke="black"/>')
        L.append(f'<line x1="{cx-5:.1f}" y1="{yp(lo):.1f}" x2="{cx+5:.1f}" y2="{yp(lo):.1f}" stroke="black"/>')
        L.append(f'<text x="{cx:.1f}" y="{yp(hi)-6:.1f}" text-anchor="middle" font-weight="bold">{mean:.0f}</text>')
        ly = mt + ph + 16
        L.append(f'<text x="{cx:.1f}" y="{ly:.1f}" text-anchor="end" '
                 f'transform="rotate(-35 {cx:.1f} {ly:.1f})">{label}</text>')
    L.append("</svg>")
    with open(out_path, "w") as f:
        f.write("\n".join(L))
    print(f"[svg] {out_path}")


def render_p99_grouped(title, values, out_path):
    W, H = 1200, 520
    ml, mr, mt, mb = 100, 30, 60, 100
    pw, ph = W - ml - mr, H - mt - mb
    drivers = [d for d in DRIVERS]
    ng, nb = len(TX_ORDER), len(drivers)
    gw = pw / ng
    bw = (gw * 0.85) / nb
    bgap = (gw * 0.15) / 2
    max_v = max((values.get(t, {}).get(k, 0) for t in TX_ORDER for k, _, _ in drivers), default=1)
    y_max = 10 ** math.ceil(math.log10(max(max_v, 10)))
    y_min = 100

    def yp(v):
        v = max(v, y_min)
        return mt + ph - (math.log10(v) - math.log10(y_min)) / (math.log10(y_max) - math.log10(y_min)) * ph

    L = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
         f'font-family="-apple-system, system-ui, sans-serif" font-size="12">',
         f'<rect width="{W}" height="{H}" fill="white"/>',
         f'<text x="{W/2}" y="30" text-anchor="middle" font-size="16" font-weight="bold">{title}</text>',
         f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+ph}" stroke="black"/>']
    decade = math.log10(y_min)
    while 10 ** decade <= y_max:
        v = 10 ** decade
        y = yp(v)
        L.append(f'<line x1="{ml-5}" y1="{y}" x2="{ml}" y2="{y}" stroke="black"/>')
        L.append(f'<text x="{ml-8}" y="{y+4}" text-anchor="end">{int(v)}</text>')
        L.append(f'<line x1="{ml}" y1="{y}" x2="{ml+pw}" y2="{y}" stroke="#e0e0e0" stroke-dasharray="2,2"/>')
        decade += 1
    L.append(f'<text x="20" y="{mt+ph/2}" text-anchor="middle" '
             f'transform="rotate(-90 20 {mt+ph/2})">p99 latency (μs, log)</text>')
    L.append(f'<line x1="{ml}" y1="{mt+ph}" x2="{ml+pw}" y2="{mt+ph}" stroke="black"/>')
    for gi, tx in enumerate(TX_ORDER):
        gx = ml + gi * gw
        L.append(f'<text x="{gx+gw/2}" y="{mt+ph+18}" text-anchor="middle" font-weight="bold">{tx}</text>')
        for bi, (k, _, color) in enumerate(drivers):
            v = values.get(tx, {}).get(k, 0)
            if not v:
                continue
            x = gx + bgap + bi * bw
            y = yp(v)
            h = mt + ph - y
            L.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{h:.1f}" '
                     f'fill="{color}" stroke="white" stroke-width="0.5"/>')
    lx, ly = ml + pw - 290, mt + 5
    L.append(f'<rect x="{lx-8}" y="{ly-12}" width="290" height="{len(drivers)*16+14}" fill="white" stroke="#888" stroke-width="0.5"/>')
    for bi, (_, label, color) in enumerate(drivers):
        yy = ly + bi * 16
        L.append(f'<rect x="{lx}" y="{yy}" width="14" height="10" fill="{color}"/>')
        L.append(f'<text x="{lx+20}" y="{yy+9}">{label}</text>')
    L.append("</svg>")
    with open(out_path, "w") as f:
        f.write("\n".join(L))
    print(f"[svg] {out_path}")


def main():
    tps = load_tps_stats(OUT)
    p99 = load_p99_stats(OUT)
    for topo in sorted(tps):
        render_tps_bar(
            f"TPC-C TPS — {topo} — strict isolation, IC 95% entre sessões",
            tps[topo], f"{STEM}_{topo}_tps.svg")
    for topo in sorted(p99):
        render_p99_grouped(
            f"TPC-C p99 por tx_type — {topo} — log scale",
            p99[topo], f"{STEM}_{topo}_p99.svg")


if __name__ == "__main__":
    main()
