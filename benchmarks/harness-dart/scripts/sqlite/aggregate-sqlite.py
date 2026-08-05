#!/usr/bin/env python3
"""
Aggregate the  (SQLite) robust battery with the SAME methodology as
docker/bench/aggregate-2env.py (PG  / MySQL-Mongo 2env):

  - Statistical unit = per-SESSION throughput (mean of that session's reps).
  - N sessions -> mean, sd, cv%, CI95 via Student-t (df = n-1).
  - Welch t-test + exact Mann-Whitney on ADJACENT ranked pairs within each
    (workload, topology) group (here the two drivers: developed vs pub sqlite3).
  - p50/p95/p99 + tail_ratio (p99/p50) + P13 flag (>10) from the per-op
    latency_us in the CSVs, pooled per (driver, topology, workload, tx_type).

Throughput comes from the harness stdout captured in run.out:
  `rep N: driver=D wl=W conns=C ops=.. wall=..ms ops/s=NNN`
grouped by the session marker the wrapper emits:
  `########## SQLITE SESSION s=N driver=D wl=W topo=T conns=C ... ##########`

Usage:  python3 aggregate-sqlite.py <outdir>
Writes: <outdir>/agg_stats.csv, agg_significance.csv, agg_p99.csv  (+ summary)
"""
import sys, os, re, math, statistics, csv as _csv

T_CRIT_95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
             7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228}
def t_crit(df):
    if df <= 0: return float('nan')
    return T_CRIT_95.get(df, 1.96)

# --- Welch t-test (two-sided p via incomplete beta) ---
def _betacf(a, b, x):
    MAXIT, EPS, FPMIN = 200, 3e-12, 1e-300
    qab, qap, qam = a + b, a + 1, a - 1
    c = 1.0; d = 1 - qab * x / qap
    if abs(d) < FPMIN: d = FPMIN
    d = 1 / d; h = d
    for m in range(1, MAXIT + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1 + aa * d
        if abs(d) < FPMIN: d = FPMIN
        c = 1 + aa / c
        if abs(c) < FPMIN: c = FPMIN
        d = 1 / d; h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1 + aa * d
        if abs(d) < FPMIN: d = FPMIN
        c = 1 + aa / c
        if abs(c) < FPMIN: c = FPMIN
        d = 1 / d; de = d * c; h *= de
        if abs(de - 1) < EPS: break
    return h
def betai(a, b, x):
    if x <= 0: return 0.0
    if x >= 1: return 1.0
    bt = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
                  + a * math.log(x) + b * math.log(1 - x))
    if x < (a + 1) / (a + b + 2):
        return bt * _betacf(a, b, x) / a
    return 1 - bt * _betacf(b, a, 1 - x) / b
def welch(a, b):
    n1, n2 = len(a), len(b)
    if n1 < 2 or n2 < 2: return (float('nan'), float('nan'), float('nan'))
    m1, m2 = statistics.mean(a), statistics.mean(b)
    v1, v2 = statistics.variance(a), statistics.variance(b)
    se2 = v1 / n1 + v2 / n2
    if se2 == 0: return (float('inf'), float('nan'), 0.0)
    t = (m1 - m2) / math.sqrt(se2)
    df = se2**2 / ((v1/n1)**2/(n1-1) + (v2/n2)**2/(n2-1))
    p = betai(df/2, 0.5, df/(df + t*t))
    return (t, df, p)
def mannwhitney(a, b):
    n1, n2 = len(a), len(b); N = n1 + n2
    if n1 == 0 or n2 == 0: return (float('nan'), float('nan'))
    lab = [(v, 0) for v in a] + [(v, 1) for v in b]
    lab.sort()
    ranks = [0.0]*N; i = 0
    while i < N:
        j = i
        while j+1 < N and lab[j+1][0] == lab[i][0]: j += 1
        r = (i + j)/2 + 1
        for k in range(i, j+1): ranks[k] = r
        i = j + 1
    R1 = sum(ranks[k] for k in range(N) if lab[k][1] == 0)
    U1 = R1 - n1*(n1+1)/2; U = min(U1, n1*n2 - U1)
    mu = n1*n2/2; sd = math.sqrt(n1*n2*(N+1)/12)
    if sd == 0: return (U, float('nan'))
    z = (abs(U - mu) - 0.5)/sd
    p = math.erfc(z/math.sqrt(2))
    return (U, p)

def pct(arr, p):
    if not arr: return 0
    s = sorted(arr)
    return s[round(p * (len(s) - 1))]

def stats(vals):
    n = len(vals); m = statistics.mean(vals)
    sd = statistics.stdev(vals) if n > 1 else 0.0
    cv = 100*sd/m if m else 0.0
    h = t_crit(n-1)*sd/math.sqrt(n) if n > 1 else 0.0
    return n, m, sd, cv, m-h, m+h

def parse(runout):
    """run.out -> {(driver,topo,wl): {session: [per-rep ops/s]}}."""
    re_mark = re.compile(
        r'SQLITE SESSION s=(\d+) driver=(\S+) wl=(\S+) topo=(\S+) conns=(\S+)')
    re_ops = re.compile(r'rep \d+:.*\bops/s=([\d.]+)')
    data = {}
    sess = None; combo = None
    for line in open(runout, encoding='utf-8', errors='replace'):
        m = re_mark.search(line)
        if m:
            sess = int(m.group(1))
            combo = (m.group(2), m.group(4), m.group(3))  # driver, topo, wl
            data.setdefault(combo, {}).setdefault(sess, [])
            continue
        m = re_ops.search(line)
        if m and combo is not None:
            data[combo][sess].append(float(m.group(1)))
    return data

def load_latencies(outdir):
    """Pool latency_us per (driver, topo, wl, tx_type) from sqlite_*.csv (success only).
    driver/wl/topo come from the FILE NAME: sqlite_<driver>_<wl>_<topo>_s<N>.csv."""
    lat = {}
    for fn in os.listdir(outdir):
        if not fn.startswith('sqlite_') or not fn.endswith('.csv'): continue
        stem = fn[:-4][len('sqlite_'):]           # <driver>_<wl>_<topo>_s<N>
        parts = stem.rsplit('_', 1)               # [..., s<N>]
        if len(parts) != 2 or not parts[1].startswith('s'): continue
        head = parts[0].split('_')
        if len(head) != 3: continue               # driver, wl, topo
        driver, wl, topo = head
        with open(os.path.join(outdir, fn), encoding='utf-8', errors='replace') as f:
            for row in _csv.DictReader(f):
                if row.get('success') != '1': continue
                try: v = int(row['latency_us'])
                except (KeyError, ValueError): continue
                lat.setdefault((driver, topo, wl, row.get('tx_type', '')), []).append(v)
    return lat

def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-sqlite.py <outdir>"); sys.exit(2)
    outdir = sys.argv[1]
    runout = os.path.join(outdir, 'run.out')
    if not os.path.exists(runout):
        print(f"[erro] {runout} não encontrado"); sys.exit(1)
    data = parse(runout)

    # per-combo per-session value = mean of that session's reps
    combo_sessions = {}
    rows = []
    for combo, byses in data.items():
        svals = [statistics.mean(reps) for _, reps in sorted(byses.items()) if reps]
        if not svals: continue
        combo_sessions[combo] = svals
        n, m, sd, cv, lo, hi = stats(svals)
        drv, topo, wl = combo
        rows.append((drv, topo, wl, n, m, sd, cv, lo, hi))

    stats_path = os.path.join(outdir, 'agg_stats.csv')
    with open(stats_path, 'w') as f:
        f.write("driver,topology,workload,n_sessions,mean_ops_s,sd,cv_pct,ci95_lo,ci95_hi\n")
        for r in sorted(rows, key=lambda x: (x[2], x[1], -x[4])):
            f.write(f"{r[0]},{r[1]},{r[2]},{r[3]},{r[4]:.1f},{r[5]:.1f},{r[6]:.2f},{r[7]:.1f},{r[8]:.1f}\n")

    # ---- p99 / cauda ----
    lat = load_latencies(outdir)
    p99_path = os.path.join(outdir, 'agg_p99.csv')
    with open(p99_path, 'w') as f:
        f.write("driver,topology,workload,tx_type,n,p50,p95,p99,tail_ratio,flag\n")
        for (drv, topo, wl, tx), arr in sorted(lat.items()):
            if not arr: continue
            p50, p95, p99 = pct(arr, .5), pct(arr, .95), pct(arr, .99)
            ratio = p99 / p50 if p50 else 0
            flag = "P13" if ratio > 10 else ""
            f.write(f"{drv},{topo},{wl},{tx},{len(arr)},{p50},{p95},{p99},{ratio:.1f},{flag}\n")

    # ---- significance: adjacent ranked pairs within each (workload, topo) ----
    groups = {}
    for r in rows: groups.setdefault((r[2], r[1]), []).append(r)  # (wl, topo)
    sig_path = os.path.join(outdir, 'agg_significance.csv')
    with open(sig_path, 'w') as f:
        f.write("workload,topology,driver_hi,driver_lo,mean_hi,mean_lo,delta_pct,welch_p,mw_p\n")
        for (wl, topo), rs in sorted(groups.items()):
            rs = sorted(rs, key=lambda x: -x[4])   # by mean desc
            for i in range(len(rs) - 1):
                hi, lo = rs[i], rs[i+1]
                a, b = combo_sessions[(hi[0], hi[1], hi[2])], combo_sessions[(lo[0], lo[1], lo[2])]
                _, _, wp = welch(a, b)
                _, mwp = mannwhitney(a, b)
                delta = 100 * (hi[4] - lo[4]) / lo[4] if lo[4] else 0
                f.write(f"{wl},{topo},{hi[0]},{lo[0]},{hi[4]:.1f},{lo[4]:.1f},"
                        f"{delta:.1f},{wp:.4f},{mwp:.4f}\n")

    # ---- console summary ----
    print("\n=== throughput (per-session mean ops/s; N sessions, CI95) ===")
    for r in sorted(rows, key=lambda x: (x[2], x[1], -x[4])):
        print(f"  {r[2]:<6} {r[1]:<5} {r[0]:<14} "
              f"n={r[3]} mean={r[4]:8.0f} cv={r[6]:4.1f}% ci95=[{r[7]:.0f},{r[8]:.0f}]")
    print("\n=== cauda (tail_ratio p99/p50; flag P13 se >10) ===")
    worst = {}
    for (drv, topo, wl, tx), arr in lat.items():
        p50, p99 = pct(arr, .5), pct(arr, .99)
        ratio = p99 / p50 if p50 else 0
        k = (drv, topo, wl)
        if k not in worst or ratio > worst[k]: worst[k] = ratio
    for (drv, topo, wl), ratio in sorted(worst.items()):
        flag = "⚑ P13" if ratio > 10 else "ok"
        print(f"  {wl:<6} {topo:<5} {drv:<14} tail_ratio={ratio:6.1f}  {flag}")
    print(f"\n[ok] escrito: {stats_path}\n           {p99_path}\n           {sig_path}")

if __name__ == '__main__':
    main()
