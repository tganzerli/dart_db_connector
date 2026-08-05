#!/usr/bin/env python3
"""Plot para o benchmark F1b-PG (multi-read no Postgres).

Lê os 4 CSVs A/B da run isolada P18 (developed vs multiread × 1x1/4x4)
em docker/bench/outputs/ e produz um PNG com dois painéis:

  1. Latência p50/p95/p99 por (topologia × driver) — agregada sobre
     todas as transações bem-sucedidas.
  2. Latência p50/p99 só do newOrder (a transação com mais reads, onde
     a alavanca F1b concentra o efeito).

Reprodutível: roda sobre os CSVs versionados. TPS (não está no CSV — o
harness o imprime no stdout) é reportado na página do benchmark a partir
do log da run, não aqui.

Uso:
    python3 scripts/plot_pg_multiread.py \
        --outputs ../docker/bench/outputs \
        --out ../docker/bench/outputs/pg_multiread.png
"""
import argparse
import csv
import os
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


# (file-stem key, legend label). Files: pg_multiread_{key}_{topo}.csv —
# dedicated A/B names so they never collide with the cross-lang matrix's
# isolated_dart-developed_*.csv artifacts.
DRIVERS = [
    ("developed", "sequential (baseline)"),
    ("multiread", "multi-read (F1b)"),
]
TOPOS = ["1x1", "4x4"]


def percentile(sorted_vals, q):
    if not sorted_vals:
        return 0.0
    idx = min(len(sorted_vals) - 1, int(round(q * (len(sorted_vals) - 1))))
    return sorted_vals[idx]


def load(outputs_dir):
    """Retorna latencies[driver_key][topo][tx_type] = [latency_us...] (só sucesso)."""
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for driver_key, _ in DRIVERS:
        for topo in TOPOS:
            path = os.path.join(outputs_dir, f"pg_multiread_{driver_key}_{topo}.csv")
            if not os.path.exists(path):
                print(f"[warn] ausente: {path}")
                continue
            with open(path, newline="") as f:
                for row in csv.DictReader(f):
                    if row.get("success") not in ("1", "true", "True"):
                        continue
                    data[driver_key][topo][row["tx_type"]].append(
                        int(row["latency_us"])
                    )
    return data


def agg(latencies):
    allv = sorted(v for lst in latencies.values() for v in lst)
    return allv


def to_ms(us):
    return us / 1000.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outputs", default="../docker/bench/outputs")
    ap.add_argument("--out", default="../docker/bench/outputs/pg_multiread.png")
    args = ap.parse_args()

    data = load(args.outputs)

    fig, axes = plt.subplots(1, 2, figsize=(13, 5.2))
    colors = {"developed": "#8892a6", "multiread": "#2f6fb0"}

    # ── Painel 1: p50/p95/p99 agregado por topologia ──
    ax = axes[0]
    metrics = ["p50", "p95", "p99"]
    qmap = {"p50": 0.50, "p95": 0.95, "p99": 0.99}
    group_w = 0.8
    n_bars = len(DRIVERS) * len(TOPOS)
    bar_w = group_w / n_bars
    x = range(len(metrics))
    for di, (dk, dlabel) in enumerate(DRIVERS):
        for ti, topo in enumerate(TOPOS):
            allv = agg(data[dk][topo])
            vals = [to_ms(percentile(allv, qmap[m])) for m in metrics]
            offset = (di * len(TOPOS) + ti) * bar_w - group_w / 2 + bar_w / 2
            positions = [xi + offset for xi in x]
            hatch = "" if topo == "1x1" else "//"
            ax.bar(
                positions,
                vals,
                bar_w,
                label=f"{dlabel} · {topo}",
                color=colors[dk],
                hatch=hatch,
                edgecolor="white",
                linewidth=0.5,
            )
    ax.set_xticks(list(x))
    ax.set_xticklabels(metrics)
    ax.set_ylabel("latência (ms)")
    ax.set_title("Latência agregada (todas as transações)")
    ax.legend(fontsize=8)
    ax.grid(axis="y", alpha=0.3)

    # ── Painel 2: newOrder p50/p99 por topologia ──
    ax = axes[1]
    metrics2 = ["p50", "p99"]
    x2 = range(len(TOPOS))
    bw = 0.35
    for di, (dk, dlabel) in enumerate(DRIVERS):
        p50s = []
        p99s = []
        for topo in TOPOS:
            no = sorted(data[dk][topo].get("newOrder", []))
            p50s.append(to_ms(percentile(no, 0.50)))
            p99s.append(to_ms(percentile(no, 0.99)))
        pos = [xi + (di - 0.5) * bw for xi in x2]
        ax.bar(pos, p50s, bw, color=colors[dk], label=f"{dlabel} p50",
               edgecolor="white", linewidth=0.5)
        ax.bar(pos, [p99 - p50 for p99, p50 in zip(p99s, p50s)], bw,
               bottom=p50s, color=colors[dk], alpha=0.4,
               label=f"{dlabel} p99", edgecolor="white", linewidth=0.5)
    ax.set_xticks(list(x2))
    ax.set_xticklabels(TOPOS)
    ax.set_xlabel("topologia (isolates × conns)")
    ax.set_ylabel("latência newOrder (ms)")
    ax.set_title("newOrder: p50 (sólido) + p99 (translúcido)")
    ax.legend(fontsize=8)
    ax.grid(axis="y", alpha=0.3)

    fig.suptitle(
        "F1b-PG — multi-read no Postgres (P18, 5 reps × 5000 tx)",
        fontsize=13,
        fontweight="bold",
    )
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(args.out, dpi=130)
    print(f"[ok] {args.out}")


if __name__ == "__main__":
    main()
