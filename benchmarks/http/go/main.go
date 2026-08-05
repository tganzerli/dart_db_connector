// Phase 3 HTTP server — Go (net/http stdlib) + pgx v5.
//
// Six TechEmpower-style endpoints, same shape as the Dart Shelf servers.
// Pool size from POOL_SIZE env (default 64).
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

	"github.com/jackc/pgx/v5/pgxpool"
)

const worldRows = 10000

var pool *pgxpool.Pool

type worldRow struct {
	ID           int `json:"id"`
	RandomNumber int `json:"randomNumber"`
}

type fortune struct {
	ID      int    `json:"id"`
	Message string `json:"message"`
}

func main() {
	poolSize, _ := strconv.Atoi(getenv("POOL_SIZE", "64"))
	host := getenv("POSTGRES_HOST", "postgres")
	port := getenv("POSTGRES_PORT", "5432")
	db := getenv("POSTGRES_DB", "teste")
	user := getenv("POSTGRES_USER", "postgres")
	password := getenv("POSTGRES_PASSWORD", "123")

	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable&pool_max_conns=%d&pool_min_conns=%d",
		user, password, host, port, db, poolSize, poolSize)

	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("[go] parse config: %v", err)
	}
	ctx := context.Background()
	pool, err = pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		log.Fatalf("[go] pool: %v", err)
	}
	defer pool.Close()
	log.Printf("[go] pool ready (size=%d)", poolSize)

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
	log.Printf("[go] listening on %s", srv.Addr)
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
	rows, err := pool.Query(r.Context(), "SELECT id, message FROM fortune")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	var fortunes []fortune
	for rows.Next() {
		var f fortune
		if err := rows.Scan(&f.ID, &f.Message); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		fortunes = append(fortunes, f)
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
	var w worldRow
	err := pool.QueryRow(ctx,
		"SELECT id, randomnumber FROM world WHERE id = $1", id).
		Scan(&w.ID, &w.RandomNumber)
	return w, err
}

func updateWorld(ctx context.Context, id, newRand int) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var _id, _rand int
	if err := tx.QueryRow(ctx,
		"SELECT id, randomnumber FROM world WHERE id = $1", id).Scan(&_id, &_rand); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		"UPDATE world SET randomnumber = $1 WHERE id = $2", newRand, id); err != nil {
		return err
	}
	return tx.Commit(ctx)
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
