// TPC-C bench harness for postgres.js (postgres@3).
//
// Mirrors the Dart `tpcc_multi.dart` harness in semantics: each "worker"
// is a Node Worker thread with its own postgres pool (max=connsPerWorker).
//
// Usage:
//   node index.js --workers 4 --conns-per-worker 4 --tx-count 5000 --reps 3

import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { parseArgs } from 'node:util';
import fs from 'node:fs';
import path from 'node:path';
import postgres from 'postgres';

import { TpccMix, TxType } from './mix.js';
import { TpccRunner } from './transactions.js';

const DRIVER = 'postgresjs';

function buildConnOpts() {
  return {
    host: process.env.POSTGRES_HOST ?? 'localhost',
    port: Number(process.env.POSTGRES_PORT ?? 5432),
    database: process.env.POSTGRES_DB ?? 'teste',
    username: process.env.POSTGRES_USER ?? 'postgres',
    password: process.env.POSTGRES_PASSWORD ?? '123',
  };
}

function runTyped(runner, mix, type) {
  switch (type) {
    case TxType.newOrder:
      return runner.newOrder(mix.newOrder());
    case TxType.payment:
      return runner.payment(mix.payment());
    case TxType.orderStatus:
      return runner.orderStatus(mix.orderStatus());
    case TxType.delivery:
      return runner.delivery(mix.delivery());
    case TxType.stockLevel:
      return runner.stockLevel(mix.stockLevel());
  }
}

async function workerRun({ workerId, repId, txCount, connsPerWorker, warmup, seed }) {
  const opts = { ...buildConnOpts(), max: connsPerWorker, prepare: false };
  const sql = postgres(opts);
  const runner = new TpccRunner(sql);
  const mix = new TpccMix(seed);

  for (let i = 0; i < warmup; i++) {
    try { await runTyped(runner, mix, mix.nextType()); } catch (_) {}
  }

  const samples = [];
  for (let i = 0; i < txCount; i++) {
    const t = mix.nextType();
    const start = process.hrtime.bigint();
    let success = true;
    try { await runTyped(runner, mix, t); } catch (_) { success = false; }
    const latUs = Number((process.hrtime.bigint() - start) / 1000n);
    samples.push({
      runId: repId,
      driver: DRIVER,
      txType: t,
      latencyUs: latUs,
      success,
      workerId,
    });
  }
  await sql.end({ timeout: 5 });
  return samples;
}

function percentile(arr, p) {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  return sorted[Math.round(p * (sorted.length - 1))];
}

function summarize(samples, repTPS) {
  console.log(`\n=== summary (${DRIVER}) ===`);
  const byType = new Map();
  for (const s of samples) {
    if (!s.success) continue;
    if (!byType.has(s.txType)) byType.set(s.txType, []);
    byType.get(s.txType).push(s.latencyUs);
  }
  for (const t of ['newOrder', 'payment', 'orderStatus', 'delivery', 'stockLevel']) {
    const ls = byType.get(t) ?? [];
    if (ls.length === 0) {
      console.log(`  ${t}: 0 samples`);
      continue;
    }
    const mean = ls.reduce((a, b) => a + b, 0) / ls.length;
    console.log(
      `  ${t}: n=${ls.length} mean=${mean.toFixed(0)}us ` +
        `p50=${percentile(ls, 0.5)}us p95=${percentile(ls, 0.95)}us p99=${percentile(ls, 0.99)}us`,
    );
  }
  const avg = repTPS.reduce((a, b) => a + b, 0) / repTPS.length;
  console.log(`\nTPS avg across reps: ${avg.toFixed(1)}`);
}

async function writeCSV(csvPath, samples) {
  const exists = fs.existsSync(csvPath);
  fs.mkdirSync(path.dirname(csvPath), { recursive: true });
  const fd = fs.openSync(csvPath, 'a');
  if (!exists) {
    fs.writeSync(fd, 'run_id,driver,tx_type,latency_us,success,worker_id,topology\n');
  }
  for (const s of samples) {
    fs.writeSync(
      fd,
      `${s.runId},${s.driver},${s.txType},${s.latencyUs},${s.success ? 1 : 0},${s.workerId},\n`,
    );
  }
  fs.closeSync(fd);
}

if (!isMainThread) {
  workerRun(workerData)
    .then((samples) => parentPort.postMessage({ ok: true, samples }))
    .catch((err) => parentPort.postMessage({ ok: false, error: String(err) }));
} else {
  const { values } = parseArgs({
    options: {
      workers: { type: 'string', default: '1' },
      'conns-per-worker': { type: 'string', default: '1' },
      'tx-count': { type: 'string', default: '5000' },
      reps: { type: 'string', default: '3' },
      csv: { type: 'string', default: '/outputs/bench-node.csv' },
      warmup: { type: 'string', default: '100' },
    },
  });
  const workers = Number(values.workers);
  const connsPerWorker = Number(values['conns-per-worker']);
  const txCount = Number(values['tx-count']);
  const reps = Number(values.reps);
  const csvPath = values.csv;
  const warmup = Number(values.warmup);
  const perWorker = Math.floor(txCount / workers);
  if (perWorker * workers !== txCount) {
    console.error(
      `[warn] tx-count ${txCount} not divisible by workers ${workers}; effective per-rep = ${perWorker * workers}`,
    );
  }

  console.log('=== TPC-C Node (postgres.js) ===');
  console.log(
    `driver=${DRIVER} workers=${workers} conns-per-worker=${connsPerWorker} total-conns=${workers * connsPerWorker}`,
  );
  console.log(`per-rep tx: ${perWorker} × ${workers} = ${perWorker * workers}, reps=${reps}`);
  console.log(`csv=${csvPath}`);

  (async () => {
    const allSamples = [];
    const repTPS = [];

    for (let rep = 1; rep <= reps; rep++) {
      console.log(`\n--- rep ${rep}/${reps} ---`);
      const repStart = process.hrtime.bigint();

      const workerPromises = [];
      for (let w = 0; w < workers; w++) {
        workerPromises.push(
          new Promise((resolve, reject) => {
            const wk = new Worker(new URL(import.meta.url), {
              workerData: {
                workerId: w,
                repId: rep,
                txCount: perWorker,
                connsPerWorker,
                warmup,
                seed: 42 + rep * 1000 + w,
              },
            });
            wk.on('message', (msg) => {
              if (msg.ok) resolve(msg.samples);
              else reject(new Error(msg.error));
            });
            wk.on('error', reject);
          }),
        );
      }
      const workerSamples = await Promise.all(workerPromises);
      const wallNs = process.hrtime.bigint() - repStart;
      const wallSec = Number(wallNs) / 1e9;
      const totalSamples = workerSamples.reduce((a, b) => a + b.length, 0);
      const tps = totalSamples / wallSec;
      repTPS.push(tps);
      for (const ws of workerSamples) allSamples.push(...ws);
      console.log(
        `[rep ${rep}] wall=${wallSec.toFixed(2)}s samples=${totalSamples} tps=${tps.toFixed(1)} ` +
          `peakRSS=${Math.round(process.memoryUsage().rss / 1024 / 1024)}MiB`,
      );
    }

    await writeCSV(csvPath, allSamples);
    summarize(allSamples, repTPS);
  })().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
