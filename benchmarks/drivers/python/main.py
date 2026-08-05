"""TPC-C bench harness for asyncpg.

Mirrors the Dart `tpcc_multi.dart` harness: each "worker" is an asyncio
task with its own asyncpg.Pool (min=max=connsPerWorker), running
warmup + tx_count transactions and emitting CSV samples.

Usage:
  python main.py --workers 4 --conns-per-worker 4 --tx-count 5000 --reps 3
"""

import argparse
import asyncio
import os
import resource
import sys
import time

import asyncpg

from mix import (
    TX_DELIVERY,
    TX_NEW_ORDER,
    TX_ORDER_STATUS,
    TX_PAYMENT,
    TX_STOCK_LEVEL,
    TpccMix,
)
from transactions import TpccRunner

DRIVER = "asyncpg"
TX_ORDER = [TX_NEW_ORDER, TX_PAYMENT, TX_ORDER_STATUS, TX_DELIVERY, TX_STOCK_LEVEL]


def build_dsn() -> str:
    return (
        f"postgres://{os.environ.get('POSTGRES_USER', 'postgres')}:"
        f"{os.environ.get('POSTGRES_PASSWORD', '123')}@"
        f"{os.environ.get('POSTGRES_HOST', 'localhost')}:"
        f"{os.environ.get('POSTGRES_PORT', '5432')}/"
        f"{os.environ.get('POSTGRES_DB', 'teste')}"
    )


async def run_typed(runner: TpccRunner, mix: TpccMix, tx_type: str) -> None:
    if tx_type == TX_NEW_ORDER:
        await runner.new_order(mix.new_order())
    elif tx_type == TX_PAYMENT:
        await runner.payment(mix.payment())
    elif tx_type == TX_ORDER_STATUS:
        await runner.order_status(mix.order_status())
    elif tx_type == TX_DELIVERY:
        await runner.delivery(mix.delivery())
    elif tx_type == TX_STOCK_LEVEL:
        await runner.stock_level(mix.stock_level())


async def worker_run(
    worker_id: int,
    rep_id: int,
    tx_count: int,
    conns_per_worker: int,
    warmup: int,
    seed: int,
    dsn: str,
) -> list[tuple]:
    pool = await asyncpg.create_pool(
        dsn=dsn,
        min_size=conns_per_worker,
        max_size=conns_per_worker,
        statement_cache_size=0,
    )
    try:
        runner = TpccRunner(pool)
        mix = TpccMix(seed)

        for _ in range(warmup):
            try:
                await run_typed(runner, mix, mix.next_type())
            except Exception:  # noqa: BLE001
                pass

        samples: list[tuple] = []
        for _ in range(tx_count):
            t = mix.next_type()
            start = time.perf_counter_ns()
            success = True
            try:
                await run_typed(runner, mix, t)
            except Exception:  # noqa: BLE001
                success = False
            lat_us = (time.perf_counter_ns() - start) // 1000
            samples.append((rep_id, DRIVER, t, lat_us, 1 if success else 0, worker_id))
        return samples
    finally:
        await pool.close()


def peak_rss_mib() -> int:
    """Linux returns ru_maxrss in kilobytes; macOS in bytes."""
    raw = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":
        return raw // (1024 * 1024)
    return raw // 1024


def percentile(arr: list[int], p: float) -> int:
    if not arr:
        return 0
    s = sorted(arr)
    i = round(p * (len(s) - 1))
    return s[i]


def summarize(samples: list[tuple], rep_tps: list[float]) -> None:
    print(f"\n=== summary ({DRIVER}) ===")
    by_type: dict[str, list[int]] = {t: [] for t in TX_ORDER}
    for rep, _drv, tx_type, lat, success, _w in samples:
        if success and tx_type in by_type:
            by_type[tx_type].append(lat)
    for t in TX_ORDER:
        ls = by_type[t]
        if not ls:
            print(f"  {t}: 0 samples")
            continue
        mean = sum(ls) / len(ls)
        print(
            f"  {t}: n={len(ls)} mean={mean:.0f}us "
            f"p50={percentile(ls, 0.5)}us p95={percentile(ls, 0.95)}us "
            f"p99={percentile(ls, 0.99)}us"
        )
    if rep_tps:
        avg = sum(rep_tps) / len(rep_tps)
        print(f"\nTPS avg across reps: {avg:.1f}")


def write_csv(path: str, samples: list[tuple]) -> None:
    exists = os.path.exists(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a") as f:
        if not exists:
            f.write("run_id,driver,tx_type,latency_us,success,worker_id,topology\n")
        for rep, drv, tx_type, lat, success, worker_id in samples:
            f.write(f"{rep},{drv},{tx_type},{lat},{success},{worker_id},\n")


async def main_async(args: argparse.Namespace) -> None:
    dsn = build_dsn()
    per_worker = args.tx_count // args.workers
    if per_worker * args.workers != args.tx_count:
        print(
            f"[warn] tx-count {args.tx_count} not divisible by workers {args.workers}; "
            f"effective per-rep = {per_worker * args.workers}",
            file=sys.stderr,
        )

    print(f"=== TPC-C Python ({DRIVER}) ===")
    print(
        f"driver={DRIVER} workers={args.workers} conns-per-worker={args.conns_per_worker} "
        f"total-conns={args.workers * args.conns_per_worker}"
    )
    print(f"per-rep tx: {per_worker} × {args.workers} = {per_worker * args.workers}, reps={args.reps}")
    print(f"csv={args.csv}")

    all_samples: list[tuple] = []
    rep_tps: list[float] = []

    for rep in range(1, args.reps + 1):
        print(f"\n--- rep {rep}/{args.reps} ---")
        rep_start = time.perf_counter()

        tasks = [
            worker_run(
                worker_id=w,
                rep_id=rep,
                tx_count=per_worker,
                conns_per_worker=args.conns_per_worker,
                warmup=args.warmup,
                seed=42 + rep * 1000 + w,
                dsn=dsn,
            )
            for w in range(args.workers)
        ]
        results = await asyncio.gather(*tasks)
        wall = time.perf_counter() - rep_start

        total = sum(len(r) for r in results)
        tps = total / wall
        rep_tps.append(tps)
        for r in results:
            all_samples.extend(r)
        print(
            f"[rep {rep}] wall={wall:.2f}s samples={total} tps={tps:.1f} "
            f"peakRSS={peak_rss_mib()}MiB"
        )

    write_csv(args.csv, all_samples)
    summarize(all_samples, rep_tps)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--workers", type=int, default=1)
    p.add_argument("--conns-per-worker", type=int, default=1)
    p.add_argument("--tx-count", type=int, default=5000)
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--csv", type=str, default="/outputs/bench-python.csv")
    p.add_argument("--warmup", type=int, default=100)
    args = p.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
