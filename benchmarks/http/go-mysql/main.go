// Phase 3 HTTP server — Go (net/http stdlib) + database/sql + go-sql-driver/mysql.
//
// Six TechEmpower-style endpoints, same shape as the PG Go server
// (bench/http/go/main.go) and the Dart Shelf servers. This is the Go MySQL
// baseline. Pool size from POOL_SIZE env (default 8).
package main

import (
	"context"
	"database/sql"
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

	_ "github.com/go-sql-driver/mysql"
)

const worldRows = 10000

var db *sql.DB

type worldRow struct {
	ID           int `json:"id"`
	RandomNumber int `json:"randomNumber"`
}

type fortune struct {
	ID      int    `json:"id"`
	Message string `json:"message"`
}

func main() {
	poolSize, _ := strconv.Atoi(getenv("POOL_SIZE", "8"))
	if poolSize < 1 {
		poolSize = 8
	}
	host := getenv("MYSQL_HOST", "mysql")
	port := getenv("MYSQL_PORT", "3306")
	name := getenv("MYSQL_DB", "teste")
	user := getenv("MYSQL_USER", "bench")
	password := getenv("MYSQL_PASSWORD", "123")

	// DSN: user:pass@tcp(host:port)/db
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s", user, password, host, port, name)

	var err error
	db, err = sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("[go-mysql] open: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(poolSize)
	db.SetMaxIdleConns(poolSize)
	db.SetConnMaxLifetime(0)

	// Startup retry loop: survive DB not-yet-ready.
	ctx := context.Background()
	deadline := time.Now().Add(60 * time.Second)
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = db.PingContext(pingCtx)
		cancel()
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			log.Fatalf("[go-mysql] db not ready after retries: %v", err)
		}
		log.Printf("[go-mysql] waiting for db: %v", err)
		time.Sleep(1 * time.Second)
	}
	log.Printf("[go-mysql] pool ready (size=%d)", poolSize)

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
	log.Printf("[go-mysql] listening on %s", srv.Addr)
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
	rows, err := db.QueryContext(r.Context(), "SELECT id, message FROM fortune")
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
	if err := rows.Err(); err != nil {
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
	var wr worldRow
	err := db.QueryRowContext(ctx,
		"SELECT id, randomnumber FROM world WHERE id = ?", id).
		Scan(&wr.ID, &wr.RandomNumber)
	return wr, err
}

func updateWorld(ctx context.Context, id, newRand int) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	var _id, _rand int
	if err := tx.QueryRowContext(ctx,
		"SELECT id, randomnumber FROM world WHERE id = ?", id).Scan(&_id, &_rand); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		"UPDATE world SET randomnumber = ? WHERE id = ?", newRand, id); err != nil {
		return err
	}
	return tx.Commit()
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
