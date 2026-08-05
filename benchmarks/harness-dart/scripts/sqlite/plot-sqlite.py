#!/usr/bin/env python3
"""Hand-rolled SVGs for  (SQLite robusto). NO matplotlib — same convention
as docker/bench/plot-2env.py (arm64 lesson, benchmark_protocol_rule §4.7).

Reads agg_stats.csv + agg_p99.csv (from aggregate-sqlite.py) and writes, into
<outdir>:
  <stem>_read_ops.svg   grouped bars: [1x1, 4x4] x {native, pkg}, IC95 whiskers
  <stem>_mixed_ops.svg  idem for the mixed workload (pkg's wide IC95 = variance story)
  <stem>_tail_p99.svg   p99 (log) for the update path per topo — surfaces the P13

Usage: python3 plot-sqlite.py <outdir> <stem>
"""
import csv, math, os, sys

# selo palette: developed = strong blue, pub package = light blue.
DRIVERS = [("native-sqlite", "Dart developed", "#0072B2"),
           ("pkg-sqlite3", "Dart Pkg (pub sqlite3)", "#56B4E9")]
COLOR = {k: c for k, _, c in DRIVERS}
LABEL = {k: l for k, l, _ in DRIVERS}
TOPOS = ["1x1", "4x4"]


def _svg_head(W, H, title):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
            f'font-family="-apple-system, system-ui, sans-serif" font-size="12">',
            f'<rect width="{W}" height="{H}" fill="white"/>',
            f'<text x="{W/2}" y="30" text-anchor="middle" font-size="16" '
            f'font-weight="bold">{title}</text>']


def _legend(L, x, y):
    L.append(f'<rect x="{x-8}" y="{y-12}" width="210" height="{len(DRIVERS)*16+14}" '
             f'fill="white" stroke="#888" stroke-width="0.5"/>')
    for bi, (_, label, color) in enumerate(DRIVERS):
        yy = y + bi*16
        L.append(f'<rect x="{x}" y="{yy}" width="14" height="10" fill="{color}"/>')
        L.append(f'<text x="{x+20}" y="{yy+9}">{label}</text>')


def render_grouped_bars(title, groups, data, unit_label, out_path, log=False):
    """groups: x-axis group labels. data: {group: {driver: (mean, lo, hi)}}.
    Linear (throughput) or log (p99) y. IC95 whiskers only when lo/hi given (linear)."""
    W, H = 820, 480
    ml, mr, mt, mb = 100, 30, 70, 90
    pw, ph = W - ml - mr, H - mt - mb
    vals = [data[g][k][0] for g in groups for _, _, _ in [(0,0,0)]
            for k in COLOR if k in data.get(g, {})]
    if not vals:
        return
    max_v = max(data[g][k][2] if not log else data[g][k][0]
                for g in groups for k in data.get(g, {}))
    if log:
        y_min = 1
        y_max = 10 ** math.ceil(math.log10(max(max_v, 10)))
        def yp(v):
            v = max(v, y_min)
            return mt+ph - (math.log10(v)-math.log10(y_min)) / \
                (math.log10(y_max)-math.log10(y_min))*ph
    else:
        mag = 10 ** math.floor(math.log10(max_v))
        y_max = next((m*mag for m in (1, 2, 5, 10, 20, 50) if m*mag >= max_v), max_v)
        def yp(v):
            return mt + ph - v / y_max * ph

    ng, nb = len(groups), len(DRIVERS)
    gw = pw / ng
    bw = (gw*0.7) / nb
    bgap = (gw*0.3) / 2
    L = _svg_head(W, H, title)
    # y axis + gridlines
    L.append(f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+ph}" stroke="black"/>')
    if log:
        d = 0
        while 10**d <= y_max:
            v = 10**d
            y = yp(v)
            L.append(f'<line x1="{ml-5}" y1="{y}" x2="{ml}" y2="{y}" stroke="black"/>')
            L.append(f'<text x="{ml-8}" y="{y+4}" text-anchor="end">{int(v)}</text>')
            L.append(f'<line x1="{ml}" y1="{y}" x2="{ml+pw}" y2="{y}" '
                     f'stroke="#e0e0e0" stroke-dasharray="2,2"/>')
            d += 1
    else:
        for i in range(6):
            v = y_max*i/5
            y = yp(v)
            L.append(f'<line x1="{ml-5}" y1="{y}" x2="{ml}" y2="{y}" stroke="black"/>')
            L.append(f'<text x="{ml-8}" y="{y+4}" text-anchor="end">{int(v)}</text>')
            L.append(f'<line x1="{ml}" y1="{y}" x2="{ml+pw}" y2="{y}" '
                     f'stroke="#e0e0e0" stroke-dasharray="2,2"/>')
    L.append(f'<text x="20" y="{mt+ph/2}" text-anchor="middle" '
             f'transform="rotate(-90 20 {mt+ph/2})">{unit_label}</text>')
    L.append(f'<line x1="{ml}" y1="{mt+ph}" x2="{ml+pw}" y2="{mt+ph}" stroke="black"/>')
    for gi, g in enumerate(groups):
        gx = ml + gi*gw
        L.append(f'<text x="{gx+gw/2:.1f}" y="{mt+ph+22}" text-anchor="middle" '
                 f'font-weight="bold">{g}</text>')
        for bi, (k, _, color) in enumerate(DRIVERS):
            if k not in data.get(g, {}):
                continue
            mean, lo, hi = data[g][k]
            x = gx + bgap + bi*bw
            y = yp(mean)
            h = mt+ph-y
            cx = x + bw/2
            L.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{h:.1f}" '
                     f'fill="{color}" stroke="white" stroke-width="0.5"/>')
            if not log and hi > lo:
                L.append(f'<line x1="{cx:.1f}" y1="{yp(hi):.1f}" x2="{cx:.1f}" '
                         f'y2="{yp(lo):.1f}" stroke="black" stroke-width="1.5"/>')
                L.append(f'<line x1="{cx-4:.1f}" y1="{yp(hi):.1f}" x2="{cx+4:.1f}" '
                         f'y2="{yp(hi):.1f}" stroke="black"/>')
                L.append(f'<line x1="{cx-4:.1f}" y1="{yp(lo):.1f}" x2="{cx+4:.1f}" '
                         f'y2="{yp(lo):.1f}" stroke="black"/>')
            lbl = f'{mean:.0f}'
            L.append(f'<text x="{cx:.1f}" y="{(yp(hi) if not log else y)-6:.1f}" '
                     f'text-anchor="middle" font-weight="bold" font-size="11">{lbl}</text>')
    _legend(L, ml+pw-202, mt+2)
    L.append("</svg>")
    open(out_path, "w").write("\n".join(L))
    print(f"[svg] {out_path}")


def main():
    outdir, stem = sys.argv[1], sys.argv[2]
    S = os.path.join(outdir, stem)
    stats = list(csv.DictReader(open(f"{outdir}/agg_stats.csv")))
    p99 = list(csv.DictReader(open(f"{outdir}/agg_p99.csv")))

    # throughput: one grouped chart per workload
    for wl, nice in (("read", "leitura"), ("mixed", "mista (read/update)")):
        data = {}
        for r in stats:
            if r["workload"] != wl:
                continue
            data.setdefault(r["topology"], {})[r["driver"]] = (
                float(r["mean_ops_s"]), float(r["ci95_lo"]), float(r["ci95_hi"]))
        render_grouped_bars(
            f"SQLite — carga {nice}: ops/s por topologia (± IC 95%)",
            TOPOS, data, "ops/s (± IC 95%)", f"{S}_{wl}_ops.svg", log=False)

    # tail: p99 of the update path per topo (mixed workload) — surfaces the P13.
    data = {}
    for r in p99:
        if r["workload"] == "mixed" and r["tx_type"] == "update":
            data.setdefault(r["topology"], {})[r["driver"]] = (int(r["p99"]), 0, 0)
    render_grouped_bars(
        "SQLite — p99 do UPDATE (carga mista) por topologia — log (P13 no 4×4 developed)",
        TOPOS, data, "p99 latency (μs, log)", f"{S}_tail_p99.svg", log=True)


if __name__ == "__main__":
    main()
