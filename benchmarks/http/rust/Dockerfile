# benchmarks/http/rust — axum + tokio-postgres + deadpool.

FROM rust:1.85-bookworm AS build
WORKDIR /src
COPY benchmarks/http/rust/Cargo.toml ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo fetch
COPY benchmarks/http/rust/src ./src
RUN cargo build --release --locked || cargo build --release
RUN cp /src/target/release/bench_http_rust /out

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out /server
EXPOSE 8080
ENTRYPOINT ["/server"]
