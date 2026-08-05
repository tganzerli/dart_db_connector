package io.github.tganzerli.bench;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.*;
import java.util.concurrent.*;

import io.github.tganzerli.bench.Mix.TxType;

public class Main {
    static final String DRIVER = "pgjdbc";

    static String env(String k, String def) {
        String v = System.getenv(k);
        return (v == null || v.isEmpty()) ? def : v;
    }

    static String jdbcUrl() {
        return "jdbc:postgresql://" + env("POSTGRES_HOST", "localhost") + ":" +
               env("POSTGRES_PORT", "5432") + "/" + env("POSTGRES_DB", "teste");
    }

    static class Args {
        int workers = 1;
        int connsPerWorker = 1;
        int txCount = 5000;
        int reps = 3;
        String csv = "/outputs/bench-java.csv";
        int warmup = 500;
    }

    static Args parseArgs(String[] argv) {
        Args a = new Args();
        for (int i = 0; i < argv.length; i++) {
            String k = argv[i];
            String v = (i + 1 < argv.length) ? argv[++i] : "";
            switch (k) {
                case "--workers": a.workers = Integer.parseInt(v); break;
                case "--conns-per-worker": a.connsPerWorker = Integer.parseInt(v); break;
                case "--tx-count": a.txCount = Integer.parseInt(v); break;
                case "--reps": a.reps = Integer.parseInt(v); break;
                case "--csv": a.csv = v; break;
                case "--warmup": a.warmup = Integer.parseInt(v); break;
            }
        }
        return a;
    }

    static class Sample {
        final int repId; final String tx; final long latUs;
        final boolean success; final int workerId;
        Sample(int r, String tx, long l, boolean s, int w) {
            this.repId = r; this.tx = tx; this.latUs = l; this.success = s; this.workerId = w;
        }
    }

    static void runTyped(Connection c, Mix mix, TxType t) throws Exception {
        switch (t) {
            case NEW_ORDER -> Transactions.newOrder(c, mix.newOrder());
            case PAYMENT -> Transactions.payment(c, mix.payment());
            case ORDER_STATUS -> Transactions.orderStatus(c, mix.orderStatus());
            case DELIVERY -> Transactions.delivery(c, mix.delivery());
            case STOCK_LEVEL -> Transactions.stockLevel(c, mix.stockLevel());
        }
    }

    static List<Sample> workerRun(int workerId, int repId, int txCount, int warmup, long seed,
                                  String url, String user, String pass) throws Exception {
        // 1 conn por worker (cpw=1) — para cpw>1, Java teria que multiplexar, mas o pattern
        // do bench tem 1 conn por worker numa pool externa. Mantemos 1 conn por thread.
        try (Connection conn = DriverManager.getConnection(url, user, pass)) {
            Mix mix = new Mix(seed);
            for (int i = 0; i < warmup; i++) {
                try { runTyped(conn, mix, mix.nextType()); } catch (Exception ignore) {}
            }
            List<Sample> samples = new ArrayList<>(txCount);
            for (int i = 0; i < txCount; i++) {
                TxType t = mix.nextType();
                long start = System.nanoTime();
                boolean ok = true;
                try { runTyped(conn, mix, t); } catch (Exception e) { ok = false; }
                long lat = (System.nanoTime() - start) / 1000;
                samples.add(new Sample(repId, t.name, lat, ok, workerId));
            }
            return samples;
        }
    }

    static long percentile(long[] s, double p) {
        if (s.length == 0) return 0;
        int i = (int) Math.round(p * (s.length - 1));
        return s[i];
    }

    static void writeCSV(String path, List<Sample> samples) throws IOException {
        File f = new File(path);
        boolean exists = f.exists();
        File parent = f.getParentFile();
        if (parent != null) parent.mkdirs();
        try (BufferedWriter w = new BufferedWriter(new FileWriter(f, true))) {
            if (!exists) w.write("run_id,driver,tx_type,latency_us,success,worker_id,topology\n");
            for (Sample s : samples) {
                w.write(s.repId + "," + DRIVER + "," + s.tx + "," + s.latUs + "," +
                        (s.success ? 1 : 0) + "," + s.workerId + ",\n");
            }
        }
    }

    static void summarize(List<Sample> samples, double[] repTPS) {
        System.out.println("\n=== summary (" + DRIVER + ") ===");
        String[] order = {"newOrder", "payment", "orderStatus", "delivery", "stockLevel"};
        for (String t : order) {
            List<Long> ls = new ArrayList<>();
            for (Sample s : samples) if (s.success && s.tx.equals(t)) ls.add(s.latUs);
            if (ls.isEmpty()) { System.out.println("  " + t + ": 0 samples"); continue; }
            long[] arr = ls.stream().mapToLong(Long::longValue).sorted().toArray();
            long sum = 0; for (long x : arr) sum += x;
            double mean = (double) sum / arr.length;
            System.out.printf(Locale.ROOT,
                    "  %s: n=%d mean=%.0fus p50=%dus p95=%dus p99=%dus%n",
                    t, arr.length, mean,
                    percentile(arr, 0.5), percentile(arr, 0.95), percentile(arr, 0.99));
        }
        double avg = 0; for (double v : repTPS) avg += v;
        System.out.printf(Locale.ROOT, "%nTPS avg across reps: %.1f%n", avg / repTPS.length);
    }

    public static void main(String[] argv) throws Exception {
        Args args = parseArgs(argv);
        Class.forName("org.postgresql.Driver");
        String url = jdbcUrl();
        String user = env("POSTGRES_USER", "postgres");
        String pass = env("POSTGRES_PASSWORD", "123");
        int perWorker = args.txCount / args.workers;
        if (perWorker * args.workers != args.txCount) {
            System.err.println("[warn] tx-count not divisible by workers; effective per-rep = " + (perWorker * args.workers));
        }
        System.out.println("=== TPC-C Java (" + DRIVER + ") ===");
        System.out.println("driver=" + DRIVER + " workers=" + args.workers +
                " conns-per-worker=" + args.connsPerWorker +
                " total-conns=" + (args.workers * args.connsPerWorker));
        System.out.println("per-rep tx: " + perWorker + " × " + args.workers + " = " +
                (perWorker * args.workers) + ", reps=" + args.reps + ", warmup=" + args.warmup);
        System.out.println("csv=" + args.csv);

        List<Sample> allSamples = new ArrayList<>(perWorker * args.workers * args.reps);
        double[] repTPS = new double[args.reps];

        // Java is synchronous JDBC; map workers×cpw → totalThreads with 1 conn each.
        // Matches the effective server-side load of the other drivers (max workers×cpw conns).
        int totalThreads = Math.max(1, args.workers * args.connsPerWorker);
        int perThread = args.txCount / totalThreads;
        System.out.println("[java mapping] totalThreads=" + totalThreads + " perThread=" + perThread);

        for (int rep = 1; rep <= args.reps; rep++) {
            System.out.println("\n--- rep " + rep + "/" + args.reps + " ---");
            long repStart = System.nanoTime();
            ExecutorService pool = Executors.newFixedThreadPool(totalThreads);
            List<Future<List<Sample>>> futures = new ArrayList<>();
            final int repFinal = rep;
            for (int w = 0; w < totalThreads; w++) {
                final int wId = w;
                futures.add(pool.submit(() ->
                        workerRun(wId, repFinal, perThread, args.warmup, 42L + repFinal * 1000L + wId, url, user, pass)));
            }
            for (Future<List<Sample>> f : futures) allSamples.addAll(f.get());
            pool.shutdown();
            long wallNs = System.nanoTime() - repStart;
            double wallSec = wallNs / 1e9;
            int totalThisRep = perThread * totalThreads;
            double tps = totalThisRep / wallSec;
            repTPS[rep - 1] = tps;
            Runtime rt = Runtime.getRuntime();
            long rssMiB = (rt.totalMemory() - rt.freeMemory()) / (1024 * 1024);
            System.out.printf(Locale.ROOT, "[rep %d] wall=%.2fs samples=%d tps=%.1f heapUsed=%dMiB%n",
                    rep, wallSec, totalThisRep, tps, rssMiB);
        }

        writeCSV(args.csv, allSamples);
        summarize(allSamples, repTPS);
    }
}
