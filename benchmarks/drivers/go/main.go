package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"runtime"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const driverName = "pgx"

type cliArgs struct {
	workers        int
	connsPerWorker int
	txCount        int
	reps           int
	csvPath        string
	warmup         int
}

func parseArgs() cliArgs {
	a := cliArgs{}
	flag.IntVar(&a.workers, "workers", 1, "number of worker goroutines")
	flag.IntVar(&a.connsPerWorker, "conns-per-worker", 1, "connections per worker")
	flag.IntVar(&a.txCount, "tx-count", 5000, "total transactions per rep across all workers")
	flag.IntVar(&a.reps, "reps", 3, "number of repetitions")
	flag.StringVar(&a.csvPath, "csv", "/outputs/bench-go.csv", "output CSV path")
	flag.IntVar(&a.warmup, "warmup", 100, "warmup transactions per worker (not recorded)")
	flag.Parse()
	return a
}

type sample struct {
	repID     int
	driver    string
	txType    string
	latencyUs int64
	success   bool
	workerID  int
}

func main() {
	args := parseArgs()
	connStr := buildConnStr()

	perWorker := args.txCount / args.workers
	if perWorker*args.workers != args.txCount {
		fmt.Fprintf(os.Stderr, "[warn] tx-count %d not divisible by workers %d; effective per-rep = %d\n",
			args.txCount, args.workers, perWorker*args.workers)
	}

	fmt.Printf("=== TPC-C Go (pgx) ===\n")
	fmt.Printf("driver=%s workers=%d conns-per-worker=%d total-conns=%d\n",
		driverName, args.workers, args.connsPerWorker, args.workers*args.connsPerWorker)
	fmt.Printf("per-rep tx: %d × %d workers = %d, reps=%d\n",
		perWorker, args.workers, perWorker*args.workers, args.reps)
	fmt.Printf("csv=%s\n", args.csvPath)

	allSamples := make([]sample, 0, perWorker*args.workers*args.reps)
	repTPS := make([]float64, 0, args.reps)

	for rep := 1; rep <= args.reps; rep++ {
		fmt.Printf("\n--- rep %d/%d ---\n", rep, args.reps)
		repStart := time.Now()

		var wg sync.WaitGroup
		var mu sync.Mutex

		for w := 0; w < args.workers; w++ {
			wg.Add(1)
			go func(workerID int) {
				defer wg.Done()
				cfg, err := pgxpool.ParseConfig(connStr)
				if err != nil {
					fmt.Fprintf(os.Stderr, "[worker %d] parse config: %v\n", workerID, err)
					return
				}
				cfg.MaxConns = int32(args.connsPerWorker)
				cfg.MinConns = int32(args.connsPerWorker)
				ctx := context.Background()
				pool, err := pgxpool.NewWithConfig(ctx, cfg)
				if err != nil {
					fmt.Fprintf(os.Stderr, "[worker %d] new pool: %v\n", workerID, err)
					return
				}
				defer pool.Close()
				runner := NewTpccRunner(pool)
				mix := NewTpccMix(int64(42 + rep*1000 + workerID))

				// Warmup
				for i := 0; i < args.warmup; i++ {
					_ = runTyped(ctx, runner, mix, mix.NextType())
				}

				local := make([]sample, 0, perWorker)
				for i := 0; i < perWorker; i++ {
					t := mix.NextType()
					start := time.Now()
					err := runTyped(ctx, runner, mix, t)
					lat := time.Since(start).Microseconds()
					local = append(local, sample{
						repID:     rep,
						driver:    driverName,
						txType:    t.Name(),
						latencyUs: lat,
						success:   err == nil,
						workerID:  workerID,
					})
				}
				mu.Lock()
				allSamples = append(allSamples, local...)
				mu.Unlock()
			}(w)
		}
		wg.Wait()
		wall := time.Since(repStart)
		tps := float64(perWorker*args.workers) / wall.Seconds()
		repTPS = append(repTPS, tps)
		fmt.Printf("[rep %d] wall=%s tps=%.1f peakRSS=%dMiB\n",
			rep, wall, tps, peakRssMiB())
	}

	if err := writeCSV(args.csvPath, allSamples); err != nil {
		fmt.Fprintf(os.Stderr, "csv write: %v\n", err)
		os.Exit(1)
	}
	summarize(allSamples, repTPS)
}

func runTyped(ctx context.Context, r *TpccRunner, m *TpccMix, t TxType) error {
	switch t {
	case TxNewOrder:
		return r.NewOrder(ctx, m.NewOrder())
	case TxPayment:
		return r.Payment(ctx, m.Payment())
	case TxOrderStatus:
		return r.OrderStatus(ctx, m.OrderStatus())
	case TxDelivery:
		return r.Delivery(ctx, m.Delivery())
	case TxStockLevel:
		return r.StockLevel(ctx, m.StockLevel())
	}
	return nil
}

func buildConnStr() string {
	get := func(k, def string) string {
		v := os.Getenv(k)
		if v == "" {
			return def
		}
		return v
	}
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
		get("POSTGRES_USER", "postgres"),
		get("POSTGRES_PASSWORD", "123"),
		get("POSTGRES_HOST", "localhost"),
		get("POSTGRES_PORT", "5432"),
		get("POSTGRES_DB", "teste"))
}

func peakRssMiB() uint64 {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return ms.Sys / 1024 / 1024
}

func writeCSV(path string, samples []sample) error {
	exists := false
	if _, err := os.Stat(path); err == nil {
		exists = true
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	if !exists {
		fmt.Fprintln(f, "run_id,driver,tx_type,latency_us,success,worker_id,topology")
	}
	for _, s := range samples {
		succ := 0
		if s.success {
			succ = 1
		}
		fmt.Fprintf(f, "%d,%s,%s,%d,%d,%d,\n",
			s.repID, s.driver, s.txType, s.latencyUs, succ, s.workerID)
	}
	return nil
}

func summarize(samples []sample, repTPS []float64) {
	fmt.Printf("\n=== summary (%s) ===\n", driverName)
	byType := map[string][]int64{}
	for _, s := range samples {
		if !s.success {
			continue
		}
		byType[s.txType] = append(byType[s.txType], s.latencyUs)
	}
	for _, t := range []string{"newOrder", "payment", "orderStatus", "delivery", "stockLevel"} {
		ls := byType[t]
		if len(ls) == 0 {
			fmt.Printf("  %s: 0 samples\n", t)
			continue
		}
		sort.Slice(ls, func(i, j int) bool { return ls[i] < ls[j] })
		var sum int64
		for _, x := range ls {
			sum += x
		}
		mean := float64(sum) / float64(len(ls))
		p50 := ls[int(0.5*float64(len(ls)-1)+0.5)]
		p95 := ls[int(0.95*float64(len(ls)-1)+0.5)]
		p99 := ls[int(0.99*float64(len(ls)-1)+0.5)]
		fmt.Printf("  %s: n=%d mean=%.0fus p50=%dus p95=%dus p99=%dus\n",
			t, len(ls), mean, p50, p95, p99)
	}
	var total float64
	for _, v := range repTPS {
		total += v
	}
	fmt.Printf("\nTPS avg across reps: %.1f\n", total/float64(len(repTPS)))
}
