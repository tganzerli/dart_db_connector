// YCSB baseline for MongoDB using the official Go driver (mongo-go-driver).
// Mirrors the Dart YCSB runner: load phase populates --records documents,
// then --conns goroutines each run --ops/N operations under a fixed-seed
// uniform key distribution (matching the Dart cross-language run). Emits the
// same per-op CSV schema so the shared aggregator consumes it uniformly.
package main

import (
	"context"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"strings"
	"sync"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

const (
	dbName   = "ycsb"
	collName = "usertable"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func uri() string {
	return fmt.Sprintf("mongodb://%s:%s@%s:%s/?authSource=admin",
		env("MONGO_USER", "root"), env("MONGO_PASSWORD", "123"),
		env("MONGO_HOST", "127.0.0.1"), env("MONGO_PORT", "27017"))
}

func main() {
	workload := flag.String("workload", "C", "YCSB workload A|B|C")
	conns := flag.Int("conns", 4, "concurrent workers")
	ops := flag.Int("ops", 40000, "run-phase operations")
	records := flag.Int("records", 10000, "load-phase records")
	reps := flag.Int("reps", 3, "measured repetitions")
	warmup := flag.Int("warmup", 500, "unmeasured warmup ops")
	seed := flag.Int64("seed", 12345, "base RNG seed")
	topology := flag.String("topology", "", "topology label for CSV")
	csvPath := flag.String("csv", "", "output CSV path")
	driver := flag.String("driver", "go-mongo", "driver label for CSV")
	batch := flag.Int("batch", 1, "write-heavy (W) bulk batch size: 1=InsertOne, >1=InsertMany")
	flag.Parse()

	wl := strings.ToUpper(*workload)
	readProp := map[string]float64{"A": 0.50, "B": 0.95, "C": 1.00}[wl]

	ctx := context.Background()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(uri()).
		SetMaxPoolSize(uint64(*conns+2)).SetMinPoolSize(uint64(*conns)))
	must(err)
	defer client.Disconnect(ctx)
	coll := client.Database(dbName).Collection(collName)

	// ── Write-heavy (W): measured insert throughput, unitary vs bulk ──
	if wl == "W" {
		runWriteHeavyGo(ctx, coll, *conns, *ops, *reps, *warmup, *batch,
			*driver, *topology, *csvPath)
		return
	}

	// ── Load phase ──
	fmt.Fprintf(os.Stderr, "[load] inserting %d records (go-mongo)…\n", *records)
	_ = coll.Drop(ctx)
	fields := ycsbFields()
	for i := 0; i < *records; i++ {
		doc := bson.M{"_id": i}
		for k, v := range fields {
			doc[k] = v
		}
		if _, err := coll.InsertOne(ctx, doc); err != nil {
			fmt.Fprintf(os.Stderr, "[load] insert %d: %v\n", i, err)
		}
	}

	// ── Warmup ──
	wr := rand.New(rand.NewSource(*seed))
	for i := 0; i < *warmup; i++ {
		doOp(ctx, coll, wr.Intn(*records), wr.Float64() < readProp, wr.Intn(10))
	}

	var sb strings.Builder
	sb.WriteString("run_id,driver,tx_type,latency_us,success,worker_id,topology\n")

	for rep := 1; rep <= *reps; rep++ {
		perLoop := (*ops + *conns - 1) / *conns
		var wg sync.WaitGroup
		rows := make([]string, *conns)
		start := time.Now()
		for k := 0; k < *conns; k++ {
			wg.Add(1)
			go func(k int) {
				defer wg.Done()
				r := rand.New(rand.NewSource(*seed + int64(rep)*1000 + int64(k)))
				var local strings.Builder
				for i := 0; i < perLoop; i++ {
					isRead := r.Float64() < readProp
					key := r.Intn(*records)
					field := r.Intn(10)
					t0 := time.Now()
					err := doOp(ctx, coll, key, isRead, field)
					lat := time.Since(t0).Microseconds()
					ok := 1
					if err != nil {
						ok = 0
					}
					op := "update"
					if isRead {
						op = "read"
					}
					fmt.Fprintf(&local, "%d,%s,%s,%d,%d,%d,%s\n",
						rep, *driver, op, lat, ok, k, *topology)
				}
				rows[k] = local.String()
			}(k)
		}
		wg.Wait()
		elapsed := time.Since(start)
		done := perLoop * *conns
		for _, r := range rows {
			sb.WriteString(r)
		}
		tps := float64(done) / elapsed.Seconds()
		fmt.Printf("rep %d: driver=%s wl=%s conns=%d ops=%d wall=%dms ops/s=%.0f\n",
			rep, *driver, *workload, *conns, done, elapsed.Milliseconds(), tps)
	}

	if *csvPath != "" {
		must(os.WriteFile(*csvPath, []byte(sb.String()), 0o644))
		fmt.Fprintf(os.Stderr, "[csv] wrote %s\n", *csvPath)
	}
}

// runWriteHeavyGo mirrors the Dart write-heavy run phase: each goroutine
// inserts a DISJOINT range of new documents, unitary (batch==1) or bulk
// (batch>1, InsertMany — the F1 lever). Throughput is documents/sec by
// wall-clock. _ids are unique across (rep, worker) so no drop is needed.
func runWriteHeavyGo(ctx context.Context, coll *mongo.Collection,
	conns, ops, reps, warmup, batch int, driver, topology, csvPath string) {

	_ = coll.Drop(ctx)
	fields := ycsbFields()
	buildDoc := func(id int) bson.M {
		doc := bson.M{"_id": id}
		for k, v := range fields {
			doc[k] = v
		}
		return doc
	}
	txType := "insert"
	if batch > 1 {
		txType = "insert_bulk"
	}

	// Warmup (unmeasured), negative ids (disjoint from the measured range).
	for i := 0; i < warmup; i++ {
		_, _ = coll.InsertOne(ctx, buildDoc(-1-i))
	}

	var sb strings.Builder
	sb.WriteString("run_id,driver,tx_type,latency_us,success,worker_id,topology\n")

	perLoop := (ops + conns - 1) / conns
	for rep := 1; rep <= reps; rep++ {
		var wg sync.WaitGroup
		rows := make([]string, conns)
		start := time.Now()
		for k := 0; k < conns; k++ {
			wg.Add(1)
			go func(k int) {
				defer wg.Done()
				base := (rep*conns + k) * perLoop
				var local strings.Builder
				for i := 0; i < perLoop; i += batch {
					take := batch
					if i+take > perLoop {
						take = perLoop - i
					}
					t0 := time.Now()
					var err error
					if batch == 1 {
						_, err = coll.InsertOne(ctx, buildDoc(base+i))
					} else {
						docs := make([]interface{}, take)
						for j := 0; j < take; j++ {
							docs[j] = buildDoc(base + i + j)
						}
						_, err = coll.InsertMany(ctx, docs)
					}
					lat := time.Since(t0).Microseconds()
					ok := 1
					if err != nil {
						ok = 0
					}
					fmt.Fprintf(&local, "%d,%s,%s,%d,%d,%d,%s\n",
						rep, driver, txType, lat, ok, k, topology)
				}
				rows[k] = local.String()
			}(k)
		}
		wg.Wait()
		elapsed := time.Since(start)
		for _, r := range rows {
			sb.WriteString(r)
		}
		done := perLoop * conns
		tps := float64(done) / elapsed.Seconds()
		fmt.Printf("rep %d: driver=%s wl=W batch=%d conns=%d docs=%d wall=%dms docs/s=%.0f\n",
			rep, driver, batch, conns, done, elapsed.Milliseconds(), tps)
	}

	if csvPath != "" {
		must(os.WriteFile(csvPath, []byte(sb.String()), 0o644))
		fmt.Fprintf(os.Stderr, "[csv] wrote %s\n", csvPath)
	}
}

func doOp(ctx context.Context, coll *mongo.Collection, key int, isRead bool, field int) error {
	if isRead {
		var result bson.M
		err := coll.FindOne(ctx, bson.M{"_id": key}).Decode(&result)
		if err == mongo.ErrNoDocuments {
			return nil
		}
		return err
	}
	_, err := coll.UpdateOne(ctx, bson.M{"_id": key},
		bson.M{"$set": bson.M{fmt.Sprintf("f%d", field): strings.Repeat("y", 100)}})
	return err
}

func ycsbFields() bson.M {
	v := strings.Repeat("x", 100)
	m := bson.M{}
	for f := 0; f < 10; f++ {
		m[fmt.Sprintf("f%d", f)] = v
	}
	return m
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
