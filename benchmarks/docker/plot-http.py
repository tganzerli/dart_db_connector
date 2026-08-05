#!/usr/bin/env python3
"""Plot the HTTP end-to-end results. SVG is emitted by hand rather than via
matplotlib, which avoids an architecture-specific toolchain dependency.

Lê agg_http_stats.csv (stack,endpoint,topology,vcpu,n_sessions,mean_rps,sd,
cv_pct,ci95_lo,ci95_hi,mean_p99_us). Para um (topology,vcpu) alvo, emite:
  - http_rps_<ep>.svg  : barras horizontais rps por stack (±IC95), por endpoint.
  - http_p99_<ep>.svg  : barras horizontais p99 (ms) por stack, por endpoint.

Uso: python3 plot-http.py <agg_stats.csv> <outdir> <topology> <vcpu>
"""
import sys, csv, os

# Okabe-Ito (colorblind-safe), consistente com plot-driver.py nos 3 primeiros.
COLOR = {
    'dart-native': '#0072B2', 'dart-pkg': '#56B4E9', 'go': '#009E73',
    'rust': '#D55E00', 'node': '#E69F00', 'python': '#CC79A7', 'java': '#666666',
}
LABEL = {
    'dart-native': 'Dart (desenvolvido)', 'dart-pkg': 'Dart (pub.dev)', 'go': 'Go',
    'rust': 'Rust', 'node': 'Node', 'python': 'Python', 'java': 'Java',
}
EPS = ['plaintext', 'json', 'db', 'queries', 'updates', 'fortunes']


def esc(s):
    return str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def fmt(v):
    v = float(v)
    return f'{v:,.0f}' if v >= 100 else f'{v:,.1f}'


def hbars(title, rows, unit, out_path):
    """rows: list of (stack, value, lo, hi) já ordenada desc por value."""
    W, rowh, top, left, right = 720, 34, 64, 190, 90
    H = top + rowh * len(rows) + 30
    pw = W - left - right
    maxv = max((r[3] for r in rows), default=1) or 1  # usa hi p/ caber o whisker
    L = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="-apple-system,Segoe UI,Roboto,sans-serif">',
         f'<rect width="{W}" height="{H}" fill="white"/>',
         f'<text x="{left}" y="30" font-size="18" font-weight="700">{esc(title)}</text>',
         f'<text x="{left}" y="50" font-size="12" fill="#666">{esc(unit)}</text>']
    for i, (stack, v, lo, hi) in enumerate(rows):
        y = top + i * rowh
        bw = pw * (float(v) / maxv)
        c = COLOR.get(stack, '#999')
        L.append(f'<text x="{left-10}" y="{y+rowh/2+4}" font-size="12.5" text-anchor="end">{esc(LABEL.get(stack,stack))}</text>')
        L.append(f'<rect x="{left}" y="{y+6}" width="{bw:.1f}" height="{rowh-14}" fill="{c}" rx="2"/>')
        # whisker IC95
        xlo, xhi = left + pw*(float(lo)/maxv), left + pw*(float(hi)/maxv)
        ym = y + rowh/2
        L.append(f'<line x1="{xlo:.1f}" y1="{ym}" x2="{xhi:.1f}" y2="{ym}" stroke="#333" stroke-width="1.3"/>')
        for xx in (xlo, xhi):
            L.append(f'<line x1="{xx:.1f}" y1="{ym-4}" x2="{xx:.1f}" y2="{ym+4}" stroke="#333" stroke-width="1.3"/>')
        L.append(f'<text x="{left+bw+8:.1f}" y="{ym+4}" font-size="12" fill="#222">{fmt(v)}</text>')
    L.append('</svg>')
    open(out_path, 'w').write('\n'.join(L))
    return out_path


def main():
    stats, outdir, topo, vcpu = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    os.makedirs(outdir, exist_ok=True)
    rows = [r for r in csv.DictReader(open(stats)) if r['topology'] == topo and r['vcpu'] == vcpu]
    made = []
    for ep in EPS:
        sub = [r for r in rows if r['endpoint'] == ep]
        if not sub:
            continue
        # rps
        rr = sorted([(r['stack'], float(r['mean_rps']), float(r['ci95_lo']), float(r['ci95_hi'])) for r in sub],
                    key=lambda t: -t[1])
        made.append(hbars(f'/{ep} — throughput (pool={topo}, {vcpu} vCPU)', rr,
                          'requests/s - bar = mean across sessions, whisker = CI95',
                          os.path.join(outdir, f'http_rps_{ep}.svg')))
        # p99 (ms) — menor é melhor
        pp = sorted([(r['stack'], float(r['mean_p99_us'])/1000.0, float(r['mean_p99_us'])/1000.0, float(r['mean_p99_us'])/1000.0) for r in sub],
                    key=lambda t: t[1])
        made.append(hbars(f'/{ep} — cauda p99 (pool={topo}, {vcpu} vCPU)', pp,
                          'p99 latency in ms - lower is better',
                          os.path.join(outdir, f'http_p99_{ep}.svg')))
    print(f'[plot-http] {len(made)} SVGs em {outdir} (topo={topo}, vcpu={vcpu})')
    for m in made:
        print('  ', m)


if __name__ == '__main__':
    main()
