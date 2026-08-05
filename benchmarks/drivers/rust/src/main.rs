mod mix;
mod transactions;

use std::env;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use clap::Parser;
use deadpool_postgres::{Config, ManagerConfig, RecyclingMethod, Runtime};
use tokio_postgres::NoTls;

use crate::mix::{TpccMix, TxType};
use crate::transactions::TpccRunner;

const DRIVER: &str = "tokio-postgres";

#[derive(Parser, Debug)]
struct Args {
    #[arg(long, default_value_t = 1)]
    workers: usize,
    #[arg(long, default_value_t = 1)]
    conns_per_worker: usize,
    #[arg(long, default_value_t = 5000)]
    tx_count: usize,
    #[arg(long, default_value_t = 3)]
    reps: usize,
    #[arg(long, default_value = "/outputs/bench-rust.csv")]
    csv: String,
    #[arg(long, default_value_t = 100)]
    warmup: usize,
}

#[derive(Clone, Debug)]
struct Sample {
    rep_id: usize,
    driver: String,
    tx_type: String,
    latency_us: u64,
    success: bool,
    worker_id: usize,
}

fn build_config(conns: usize) -> Config {
    let mut cfg = Config::new();
    cfg.host = Some(env::var("POSTGRES_HOST").unwrap_or_else(|_| "localhost".into()));
    cfg.port = env::var("POSTGRES_PORT").ok().and_then(|s| s.parse().ok()).or(Some(5432));
    cfg.user = Some(env::var("POSTGRES_USER").unwrap_or_else(|_| "postgres".into()));
    cfg.password = Some(env::var("POSTGRES_PASSWORD").unwrap_or_else(|_| "123".into()));
    cfg.dbname = Some(env::var("POSTGRES_DB").unwrap_or_else(|_| "teste".into()));
    cfg.manager = Some(ManagerConfig { recycling_method: RecyclingMethod::Fast });
    cfg.pool = Some(deadpool_postgres::PoolConfig {
        max_size: conns,
        ..Default::default()
    });
    cfg
}

async fn run_typed(runner: &TpccRunner, mix: &mut TpccMix, t: TxType) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    match t {
        TxType::NewOrder => runner.new_order(mix.new_order()).await,
        TxType::Payment => runner.payment(mix.payment()).await,
        TxType::OrderStatus => runner.order_status(mix.order_status()).await,
        TxType::Delivery => runner.delivery(mix.delivery()).await,
        TxType::StockLevel => runner.stock_level(mix.stock_level()).await,
    }
}

async fn worker_run(
    worker_id: usize,
    rep_id: usize,
    tx_count: usize,
    conns_per_worker: usize,
    warmup: usize,
    seed: u64,
) -> Vec<Sample> {
    let cfg = build_config(conns_per_worker);
    let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls).expect("pool create");
    let runner = TpccRunner::new(pool);
    let mut mix = TpccMix::new(seed);

    for _ in 0..warmup {
        let t = mix.next_type();
        let _ = run_typed(&runner, &mut mix, t).await;
    }

    let mut samples = Vec::with_capacity(tx_count);
    for _ in 0..tx_count {
        let t = mix.next_type();
        let start = Instant::now();
        let success = run_typed(&runner, &mut mix, t).await.is_ok();
        let lat_us = start.elapsed().as_micros() as u64;
        samples.push(Sample {
            rep_id,
            driver: DRIVER.to_string(),
            tx_type: t.name().to_string(),
            latency_us: lat_us,
            success,
            worker_id,
        });
    }
    samples
}

fn percentile(arr: &[u64], p: f64) -> u64 {
    if arr.is_empty() { return 0; }
    let mut v = arr.to_vec();
    v.sort_unstable();
    let i = (p * (v.len() - 1) as f64).round() as usize;
    v[i]
}

fn summarize(samples: &[Sample], rep_tps: &[f64]) {
    println!("\n=== summary ({}) ===", DRIVER);
    let tx_order = ["newOrder", "payment", "orderStatus", "delivery", "stockLevel"];
    for t in &tx_order {
        let lats: Vec<u64> = samples.iter()
            .filter(|s| s.success && s.tx_type == *t)
            .map(|s| s.latency_us)
            .collect();
        if lats.is_empty() {
            println!("  {}: 0 samples", t);
            continue;
        }
        let mean: f64 = lats.iter().sum::<u64>() as f64 / lats.len() as f64;
        println!(
            "  {}: n={} mean={:.0}us p50={}us p95={}us p99={}us",
            t, lats.len(), mean,
            percentile(&lats, 0.5),
            percentile(&lats, 0.95),
            percentile(&lats, 0.99),
        );
    }
    let avg: f64 = rep_tps.iter().sum::<f64>() / rep_tps.len() as f64;
    println!("\nTPS avg across reps: {:.1}", avg);
}

fn write_csv(path: &str, samples: &[Sample]) -> std::io::Result<()> {
    let exists = Path::new(path).exists();
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    if !exists {
        writeln!(f, "run_id,driver,tx_type,latency_us,success,worker_id,topology")?;
    }
    for s in samples {
        writeln!(
            f, "{},{},{},{},{},{},",
            s.rep_id, s.driver, s.tx_type, s.latency_us,
            if s.success { 1 } else { 0 }, s.worker_id
        )?;
    }
    Ok(())
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let args = Arc::new(Args::parse());
    let per_worker = args.tx_count / args.workers;
    if per_worker * args.workers != args.tx_count {
        eprintln!(
            "[warn] tx-count {} not divisible by workers {}; effective per-rep = {}",
            args.tx_count, args.workers, per_worker * args.workers
        );
    }

    println!("=== TPC-C Rust ({}) ===", DRIVER);
    println!(
        "driver={} workers={} conns-per-worker={} total-conns={}",
        DRIVER, args.workers, args.conns_per_worker, args.workers * args.conns_per_worker
    );
    println!("per-rep tx: {} × {} = {}, reps={}", per_worker, args.workers, per_worker * args.workers, args.reps);
    println!("csv={}", args.csv);

    let mut all_samples: Vec<Sample> = Vec::new();
    let mut rep_tps: Vec<f64> = Vec::new();

    for rep in 1..=args.reps {
        println!("\n--- rep {}/{} ---", rep, args.reps);
        let rep_start = Instant::now();

        let mut handles = Vec::with_capacity(args.workers);
        for w in 0..args.workers {
            let args_c = Arc::clone(&args);
            let w_id = w;
            let r_id = rep;
            handles.push(tokio::spawn(async move {
                worker_run(
                    w_id,
                    r_id,
                    per_worker,
                    args_c.conns_per_worker,
                    args_c.warmup,
                    42 + (r_id as u64) * 1000 + w_id as u64,
                ).await
            }));
        }
        let mut total = 0usize;
        for h in handles {
            let s = h.await.expect("worker join");
            total += s.len();
            all_samples.extend(s);
        }
        let wall = rep_start.elapsed();
        let tps = total as f64 / wall.as_secs_f64();
        rep_tps.push(tps);
        println!("[rep {}] wall={:.2}s samples={} tps={:.1}", rep, wall.as_secs_f64(), total, tps);
    }

    write_csv(&args.csv, &all_samples).expect("csv write");
    summarize(&all_samples, &rep_tps);
}
