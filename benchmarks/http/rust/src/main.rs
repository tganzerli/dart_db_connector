//! Phase 3 HTTP server — Rust (axum + tokio-postgres + deadpool).
//!
//! Six TechEmpower-style endpoints; same shape as the Dart/Go servers.
//! POOL_SIZE env (default 64) controls deadpool max size.

use std::env;
use std::net::SocketAddr;

use axum::{
    extract::{Query, State},
    http::header,
    response::{Html, IntoResponse, Response},
    routing::get,
    Json, Router,
};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use rand::Rng;
use serde::{Deserialize, Serialize};
use tokio_postgres::{Config, NoTls};

const WORLD_ROWS: i32 = 10_000;

#[derive(Clone)]
struct AppState {
    pool: Pool,
}

#[derive(Serialize, Clone)]
struct WorldRow {
    id: i32,
    #[serde(rename = "randomNumber")]
    random_number: i32,
}

#[derive(Serialize)]
struct HelloMessage {
    message: &'static str,
}

#[derive(Deserialize)]
struct CountQuery {
    count: Option<String>,
}

#[tokio::main]
async fn main() {
    let pool_size: usize = env::var("POOL_SIZE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(64);

    let mut cfg = Config::new();
    cfg.host(&env::var("POSTGRES_HOST").unwrap_or_else(|_| "postgres".into()));
    cfg.port(
        env::var("POSTGRES_PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(5432),
    );
    cfg.dbname(&env::var("POSTGRES_DB").unwrap_or_else(|_| "teste".into()));
    cfg.user(&env::var("POSTGRES_USER").unwrap_or_else(|_| "postgres".into()));
    cfg.password(env::var("POSTGRES_PASSWORD").unwrap_or_else(|_| "123".into()));

    let mgr = Manager::from_config(
        cfg,
        NoTls,
        ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        },
    );
    let pool = Pool::builder(mgr)
        .max_size(pool_size)
        .build()
        .expect("[rust] pool build failed");
    println!("[rust] pool ready (size={})", pool_size);

    let state = AppState { pool };

    let app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/json", get(json_handler))
        .route("/db", get(db_handler))
        .route("/queries", get(queries_handler))
        .route("/updates", get(updates_handler))
        .route("/fortunes", get(fortunes_handler))
        .with_state(state);

    let addr: SocketAddr = "0.0.0.0:8080".parse().unwrap();
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    println!("[rust] listening on http://{}", addr);
    axum::serve(listener, app).await.unwrap();
}

async fn plaintext() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
        "Hello, World!",
    )
}

async fn json_handler() -> Json<HelloMessage> {
    Json(HelloMessage {
        message: "Hello, World!",
    })
}

async fn db_handler(State(s): State<AppState>) -> Result<Json<WorldRow>, AppError> {
    let id = rand::thread_rng().gen_range(1..=WORLD_ROWS);
    Ok(Json(select_world(&s.pool, id).await?))
}

async fn queries_handler(
    State(s): State<AppState>,
    Query(q): Query<CountQuery>,
) -> Result<Json<Vec<WorldRow>>, AppError> {
    let count = clamp_count(q.count.as_deref());
    let ids: Vec<i32> = (0..count)
        .map(|_| rand::thread_rng().gen_range(1..=WORLD_ROWS))
        .collect();
    let mut handles = Vec::with_capacity(count as usize);
    for id in ids {
        let pool = s.pool.clone();
        handles.push(tokio::spawn(async move { select_world(&pool, id).await }));
    }
    let mut rows = Vec::with_capacity(count as usize);
    for h in handles {
        rows.push(h.await.map_err(|e| AppError(e.to_string()))??);
    }
    Ok(Json(rows))
}

async fn updates_handler(
    State(s): State<AppState>,
    Query(q): Query<CountQuery>,
) -> Result<Json<Vec<WorldRow>>, AppError> {
    let count = clamp_count(q.count.as_deref());
    let mut handles = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let pool = s.pool.clone();
        handles.push(tokio::spawn(async move {
            let id = rand::thread_rng().gen_range(1..=WORLD_ROWS);
            let new_rand = rand::thread_rng().gen_range(1..=WORLD_ROWS);
            update_world(&pool, id, new_rand).await?;
            Ok::<WorldRow, AppError>(WorldRow {
                id,
                random_number: new_rand,
            })
        }));
    }
    let mut rows = Vec::with_capacity(count as usize);
    for h in handles {
        rows.push(h.await.map_err(|e| AppError(e.to_string()))??);
    }
    Ok(Json(rows))
}

async fn fortunes_handler(State(s): State<AppState>) -> Result<Response, AppError> {
    let conn = s.pool.get().await.map_err(|e| AppError(e.to_string()))?;
    let rows = conn
        .query("SELECT id, message FROM fortune", &[])
        .await
        .map_err(|e| AppError(e.to_string()))?;
    let mut fortunes: Vec<(i32, String)> = rows
        .iter()
        .map(|r| (r.get::<_, i32>(0), r.get::<_, String>(1)))
        .collect();
    fortunes.push((0, "Additional fortune added at request time.".into()));
    fortunes.sort_by(|a, b| a.1.cmp(&b.1));

    let mut html = String::with_capacity(2048);
    html.push_str("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>");
    for (id, msg) in &fortunes {
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td></tr>",
            id,
            html_escape(msg)
        ));
    }
    html.push_str("</table></body></html>");
    Ok(Html(html).into_response())
}

async fn select_world(pool: &Pool, id: i32) -> Result<WorldRow, AppError> {
    let conn = pool.get().await.map_err(|e| AppError(e.to_string()))?;
    let row = conn
        .query_one(
            "SELECT id, randomnumber FROM world WHERE id = $1",
            &[&id],
        )
        .await
        .map_err(|e| AppError(e.to_string()))?;
    Ok(WorldRow {
        id: row.get(0),
        random_number: row.get(1),
    })
}

async fn update_world(pool: &Pool, id: i32, new_rand: i32) -> Result<(), AppError> {
    let mut conn = pool.get().await.map_err(|e| AppError(e.to_string()))?;
    let tx = conn
        .transaction()
        .await
        .map_err(|e| AppError(e.to_string()))?;
    tx.query_one(
        "SELECT id, randomnumber FROM world WHERE id = $1",
        &[&id],
    )
    .await
    .map_err(|e| AppError(e.to_string()))?;
    tx.execute(
        "UPDATE world SET randomnumber = $1 WHERE id = $2",
        &[&new_rand, &id],
    )
    .await
    .map_err(|e| AppError(e.to_string()))?;
    tx.commit().await.map_err(|e| AppError(e.to_string()))?;
    Ok(())
}

fn clamp_count(raw: Option<&str>) -> i32 {
    let v: i32 = raw.and_then(|s| s.parse().ok()).unwrap_or(1);
    v.clamp(1, 500)
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

struct AppError(String);
impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        (axum::http::StatusCode::INTERNAL_SERVER_ERROR, self.0).into_response()
    }
}
