// Phase 3 HTTP server — Go (net/http stdlib) + MongoDB (official mongo-driver).
//
// The MongoDB Go baseline. Six TechEmpower-style endpoints, same shapes as the
// PG Go server (bench/http/go/main.go) and the Dart Shelf servers.
// Pool size from POOL_SIZE env (default 8).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

const (
	worldRows = 10000
	dbName    = "teste"
)

var (
	worldColl   *mongo.Collection
	fortuneColl *mongo.Collection
)

type worldRow struct {
	ID           int `bson:"_id" json:"id"`
	RandomNumber int `bson:"randomnumber" json:"randomNumber"`
}

type fortune struct {
	ID      int    `bson:"_id" json:"id"`
	Message string `bson:"message" json:"message"`
}

func main() {
	poolSize, _ := strconv.Atoi(getenv("POOL_SIZE", "8"))
	mongoURI := getenv("MONGO_URI", "mongodb://mongo:27017")

	ctx := context.Background()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI(mongoURI).
		SetMaxPoolSize(uint64(poolSize)))
	if err != nil {
		log.Fatalf("[go-mongo] connect: %v", err)
	}
	defer func() { _ = client.Disconnect(ctx) }()

	// Startup retry loop: survive Mongo not-yet-ready.
	for i := 0; ; i++ {
		pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := client.Ping(pingCtx, nil)
		cancel()
		if err == nil {
			break
		}
		log.Printf("[go-mongo] waiting for mongo (attempt %d): %v", i+1, err)
		time.Sleep(1 * time.Second)
	}

	db := client.Database(dbName)
	worldColl = db.Collection("world")
	fortuneColl = db.Collection("fortune")
	log.Printf("[go-mongo] connected (pool_size=%d)", poolSize)

	mux := http.NewServeMux()
	mux.HandleFunc("/plaintext", plaintextHandler)
	mux.HandleFunc("/json", jsonHandler)
	mux.HandleFunc("/db", dbHandler)
	mux.HandleFunc("/queries", queriesHandler)
	mux.HandleFunc("/updates", updatesHandler)
	mux.HandleFunc("/fortunes", fortunesHandler)

	srv := &http.Server{
		Addr:         "0.0.0.0:8080",
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	}
	log.Printf("[go-mongo] listening on %s", srv.Addr)
	log.Fatal(srv.ListenAndServe())
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func plaintextHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("Hello, World!"))
}

func jsonHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "Hello, World!"})
}

func dbHandler(w http.ResponseWriter, r *http.Request) {
	row, err := selectWorld(r.Context(), rand.IntN(worldRows)+1)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(row)
}

func queriesHandler(w http.ResponseWriter, r *http.Request) {
	count := clampCount(r.URL.Query().Get("count"))
	rows := make([]worldRow, count)
	var wg sync.WaitGroup
	errs := make([]error, count)
	for i := 0; i < count; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			row, err := selectWorld(r.Context(), rand.IntN(worldRows)+1)
			if err != nil {
				errs[i] = err
				return
			}
			rows[i] = row
		}(i)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			http.Error(w, e.Error(), http.StatusInternalServerError)
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(rows)
}

func updatesHandler(w http.ResponseWriter, r *http.Request) {
	count := clampCount(r.URL.Query().Get("count"))
	rows := make([]worldRow, count)
	var wg sync.WaitGroup
	errs := make([]error, count)
	for i := 0; i < count; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := rand.IntN(worldRows) + 1
			newRand := rand.IntN(worldRows) + 1
			err := updateWorld(r.Context(), id, newRand)
			if err != nil {
				errs[i] = err
				return
			}
			rows[i] = worldRow{ID: id, RandomNumber: newRand}
		}(i)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			http.Error(w, e.Error(), http.StatusInternalServerError)
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(rows)
}

func fortunesHandler(w http.ResponseWriter, r *http.Request) {
	cur, err := fortuneColl.Find(r.Context(), bson.M{})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer cur.Close(r.Context())
	var fortunes []fortune
	if err := cur.All(r.Context(), &fortunes); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	fortunes = append(fortunes, fortune{ID: 0, Message: "Additional fortune added at request time."})
	sort.Slice(fortunes, func(i, j int) bool { return fortunes[i].Message < fortunes[j].Message })

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = fmt.Fprint(w, `<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>`)
	for _, f := range fortunes {
		_, _ = fmt.Fprintf(w, `<tr><td>%d</td><td>%s</td></tr>`, f.ID, html.EscapeString(f.Message))
	}
	_, _ = fmt.Fprint(w, `</table></body></html>`)
}

func selectWorld(ctx context.Context, id int) (worldRow, error) {
	var row worldRow
	err := worldColl.FindOne(ctx, bson.M{"_id": id}).Decode(&row)
	return row, err
}

func updateWorld(ctx context.Context, id, newRand int) error {
	var row worldRow
	if err := worldColl.FindOne(ctx, bson.M{"_id": id}).Decode(&row); err != nil {
		return err
	}
	_, err := worldColl.UpdateOne(ctx, bson.M{"_id": id},
		bson.M{"$set": bson.M{"randomnumber": newRand}})
	return err
}

func clampCount(raw string) int {
	v, err := strconv.Atoi(raw)
	if err != nil || v < 1 {
		return 1
	}
	if v > 500 {
		return 500
	}
	return v
}
