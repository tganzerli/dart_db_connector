#!/usr/bin/env python3
"""Statistical aggregator for the final robust cross-language TPC-C bench.


Inputs (from docker/bench/outputs/):
  - robust_tps.csv                        (driver,topology,session,rep,tps)
  - robust_<driver>_<topo>_s<N>.csv       (run_id,driver,tx_type,latency_us,success,worker_id,topology)

Statistical unit for inter-session inference = the SESSION MEAN TPS (mean of a
session's reps). The threats this bench closes (#2/#7/#11 of the May page) are
all inter-session, so reps within a session are NOT independent replicates.

Outputs (stdout tables + versioned CSVs):
  - robust_tps_stats.csv       driver,topology,n_sessions,mean_tps,sd_tps,cv_pct,ci95_lo,ci95_hi
  - robust_p99_stats.csv       driver,topology,tx_type,n,p50,p95,p99,tail_ratio,flag
  - robust_significance.csv    topology,pair,mean_a,mean_b,delta_pct,welch_t,welch_df,welch_p,mw_u,mw_p,verdict

Pure stdlib (no scipy/matplotlib — arm64 lesson, benchmark_protocol_rule §4.7):
  - normal CDF via math.erf
  - Student-t two-sided p via regularized incomplete beta (continued fraction)
  - Mann-Whitney U exact null distribution by rank enumeration (n≤~10)

Usage: python3 aggregate-driver.py [outputs_dir]
"""

import csv
import math
import os
import statistics
import sys
from collections import defaultdict
from itertools import combinations

OUT = sys.argv[1] if len(sys.argv) > 1 else "./outputs"
TX_ORDER = ["newOrder", "payment", "orderStatus", "delivery", "stockLevel"]

# driver display order / labels
DRIVERS = [
    ("dart-developed", "Dart developed"),
    ("dart-pkg", "Dart Pkg 3.5.11"),
    ("go", "Go pgx"),
    ("node", "Node postgres.js"),
    ("python", "Python asyncpg"),
    ("rust", "Rust tokio-postgres"),
    ("java", "Java pgjdbc"),
]
LABEL = dict(DRIVERS)

# Student-t two-sided critical values (95%) by df, for the CI whiskers.
T_CRIT_95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
             7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 12: 2.179, 15: 2.131,
             20: 2.086, 24: 2.064, 30: 2.042}


def t_crit(df):
    if df in T_CRIT_95:
        return T_CRIT_95[df]
    # nearest lower key (conservative-ish); fall back to normal for large df
    keys = sorted(T_CRIT_95)
    for k in reversed(keys):
        if k <= df:
            return T_CRIT_95[k]
    return 1.96


# ---- incomplete beta (Numerical Recipes betacf/betai) → Student-t p-value ----
def _betacf(a, b, x):
    MAXIT, EPS, FPMIN = 200, 3e-12, 1e-300
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < FPMIN:
        d = FPMIN
    d = 1.0 / d
    h = d
    for m in range(1, MAXIT + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < FPMIN:
            d = FPMIN
        c = 1.0 + aa / c
        if abs(c) < FPMIN:
            c = FPMIN
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < FPMIN:
            d = FPMIN
        c = 1.0 + aa / c
        if abs(c) < FPMIN:
            c = FPMIN
        d = 1.0 / d
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < EPS:
            break
    return h


def betai(a, b, x):
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbeta = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
    bt = math.exp(lbeta + a * math.log(x) + b * math.log(1.0 - x))
    if x < (a + 1.0) / (a + b + 2.0):
        return bt * _betacf(a, b, x) / a
    return 1.0 - bt * _betacf(b, a, 1.0 - x) / b


def welch_ttest(a, b):
    """Return (t, df, two_sided_p). Requires len>=2 in each group."""
    n1, n2 = len(a), len(b)
    m1, m2 = statistics.mean(a), statistics.mean(b)
    v1, v2 = statistics.variance(a), statistics.variance(b)
    if v1 == 0 and v2 == 0:
        return (float("inf") if m1 != m2 else 0.0), n1 + n2 - 2, 0.0 if m1 != m2 else 1.0
    se2 = v1 / n1 + v2 / n2
    t = (m1 - m2) / math.sqrt(se2)
    df = se2 ** 2 / ((v1 / n1) ** 2 / (n1 - 1) + (v2 / n2) ** 2 / (n2 - 1))
    p = betai(0.5 * df, 0.5, df / (df + t * t))  # two-sided
    return t, df, p


def mannwhitney_exact(a, b):
    """Exact two-sided Mann-Whitney U p-value via rank enumeration (no ties
    assumed — TPS floats). Returns (U, p)."""
    n1, n2 = len(a), len(b)
    N = n1 + n2
    combined = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks = {}
    for i, (v, g) in enumerate(combined, start=1):
        ranks[(v, g)] = i
    R1 = sum(ranks[(v, 0)] for v in a)
    U1 = R1 - n1 * (n1 + 1) / 2
    U_obs = min(U1, n1 * n2 - U1)
    # Exact null: enumerate all C(N,n1) ways to assign ranks 1..N to group A.
    all_ranks = list(range(1, N + 1))
    mean_R1 = n1 * (N + 1) / 2
    total = 0
    extreme = 0
    obs_dev = abs(R1 - mean_R1)
    for combo in combinations(all_ranks, n1):
        total += 1
        r1 = sum(combo)
        if abs(r1 - mean_R1) >= obs_dev - 1e-9:
            extreme += 1
    p = extreme / total
    return U_obs, min(p, 1.0)


def pct(arr, p):
    if not arr:
        return 0
    s = sorted(arr)
    return s[round(p * (len(s) - 1))]


# ---------------------------------------------------------------------------
def load_tps(outdir):
    """-> {(driver,topo): {session: [rep_tps,...]}}"""
    path = f"{outdir}/robust_tps.csv"
    data = defaultdict(lambda: defaultdict(list))
    if not os.path.exists(path):
        print(f"[error] missing {path} — run extract-throughput.sh first", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        for row in csv.DictReader(f):
            key = (row["driver"], row["topology"])
            data[key][row["session"]].append(float(row["tps"]))
    return data


def session_means(tps_by_session):
    """Ordered list of per-session mean TPS (the inference unit)."""
    return [statistics.mean(reps) for _, reps in sorted(tps_by_session.items())]


def load_latencies(outdir):
    """-> {(driver,topo): {tx_type: [latency_us,...]}} pooled over sessions+reps."""
    data = defaultdict(lambda: defaultdict(list))
    for fn in os.listdir(outdir):
        if not (fn.startswith("robust_") and fn.endswith(".csv")):
            continue
        if fn == "robust_tps.csv" or "_stats" in fn or "significance" in fn:
            continue
        # robust_<driver>_<topo>_s<N>.csv
        stem = fn[len("robust_"):-len(".csv")]
        try:
            rest, _sess = stem.rsplit("_s", 1)
            driver, topo = rest.rsplit("_", 1)
        except ValueError:
            continue
        with open(os.path.join(outdir, fn)) as f:
            for row in csv.DictReader(f):
                if row.get("success") != "1":
                    continue
                data[(driver, topo)][row["tx_type"]].append(int(row["latency_us"]))
    return data


def main():
    tps = load_tps(OUT)
    lat = load_latencies(OUT)
    topos = sorted({t for (_, t) in tps.keys()})

    # ---- TPS stats per combo ----
    tps_stats = {}  # (driver,topo) -> dict
    with open(f"{OUT}/robust_tps_stats.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["driver", "topology", "n_sessions", "mean_tps", "sd_tps",
                    "cv_pct", "ci95_lo", "ci95_hi"])
        for topo in topos:
            for dkey, _ in DRIVERS:
                key = (dkey, topo)
                if key not in tps:
                    continue
                means = session_means(tps[key])
                n = len(means)
                mean = statistics.mean(means)
                sd = statistics.stdev(means) if n > 1 else 0.0
                cv = 100 * sd / mean if mean else 0.0
                half = t_crit(n - 1) * sd / math.sqrt(n) if n > 1 else 0.0
                stat = dict(n=n, mean=mean, sd=sd, cv=cv,
                            lo=mean - half, hi=mean + half, samples=means)
                tps_stats[key] = stat
                w.writerow([dkey, topo, n, f"{mean:.1f}", f"{sd:.1f}",
                            f"{cv:.1f}", f"{stat['lo']:.1f}", f"{stat['hi']:.1f}"])

    # ---- p99 / tail per tx_type ----
    with open(f"{OUT}/robust_p99_stats.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["driver", "topology", "tx_type", "n", "p50", "p95", "p99",
                    "tail_ratio", "flag"])
        for topo in topos:
            for dkey, _ in DRIVERS:
                key = (dkey, topo)
                if key not in lat:
                    continue
                for tx in TX_ORDER:
                    arr = lat[key].get(tx, [])
                    if not arr:
                        continue
                    p50, p95, p99 = pct(arr, .5), pct(arr, .95), pct(arr, .99)
                    ratio = p99 / p50 if p50 else 0
                    flag = "tail-outlier" if ratio > 10 else ""
                    w.writerow([dkey, topo, tx, len(arr), p50, p95, p99,
                                f"{ratio:.1f}", flag])

    # ---- pairwise significance ----
    # Test every adjacent pair in the TPS ranking per topology (the disputed
    # rankings surface automatically) + always report the podium pair.
    sig_rows = []
    for topo in topos:
        ranked = sorted(
            [(k[0], s) for k, s in tps_stats.items() if k[1] == topo],
            key=lambda kv: kv[1]["mean"], reverse=True)
        for (da, sa), (db, sb) in zip(ranked, ranked[1:]):
            a, b = sa["samples"], sb["samples"]
            if len(a) < 2 or len(b) < 2:
                continue
            t, df, wp = welch_ttest(a, b)
            u, mp = mannwhitney_exact(a, b)
            delta = 100 * (sa["mean"] - sb["mean"]) / sb["mean"]
            verdict = ("distinguível" if (wp < 0.05 and mp < 0.05)
                       else "indistinguível (noise floor)")
            sig_rows.append([topo, f"{LABEL[da]} vs {LABEL[db]}",
                             f"{sa['mean']:.1f}", f"{sb['mean']:.1f}",
                             f"{delta:+.1f}", f"{t:.2f}", f"{df:.1f}",
                             f"{wp:.4f}", f"{u:.0f}", f"{mp:.4f}", verdict])
    with open(f"{OUT}/robust_significance.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["topology", "pair", "mean_a", "mean_b", "delta_pct",
                    "welch_t", "welch_df", "welch_p", "mw_u", "mw_p", "verdict"])
        w.writerows(sig_rows)

    # ---- human summary ----
    for topo in topos:
        print(f"\n=== TPS {topo} (mean of {tps_stats.get((DRIVERS[0][0], topo), {}).get('n', '?')} sessions +/- CI95) ===")
        ranked = sorted([(k[0], s) for k, s in tps_stats.items() if k[1] == topo],
                        key=lambda kv: kv[1]["mean"], reverse=True)
        for dkey, s in ranked:
            print(f"  {LABEL[dkey]:22s} {s['mean']:7.1f}  ± {s['hi']-s['mean']:5.1f}"
                  f"  (CV {s['cv']:4.1f}%, n={s['n']})")
    print("\n=== Significância (pares adjacentes no ranking) ===")
    for r in sig_rows:
        print(f"  [{r[0]}] {r[1]:40s} Δ{r[4]}%  Welch p={r[7]}  MW p={r[9]}  → {r[10]}")

    print(f"\n[ok] wrote robust_tps_stats.csv, robust_p99_stats.csv, robust_significance.csv in {OUT}")


if __name__ == "__main__":
    main()
