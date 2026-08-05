# Multi-stage build para o bench harness Go (pgx/v5).
#
# Stage 1 (builder, golang:1.23): baixa deps, compila estaticamente
# CGO_ENABLED=0 para produzir binário portátil.
#
# Stage 2 (runtime, debian:stable-slim): só o binário + ca-certs.
# Imagem final ~25MB.

FROM golang:1.23 AS builder

WORKDIR /src

COPY bench/go/go.mod bench/go/go.sum ./
RUN go mod download

COPY bench/go/ .

ENV CGO_ENABLED=0
RUN go build -o /out/bench-go -ldflags="-s -w" .

FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /out/bench-go /app/bench-go

VOLUME ["/outputs"]

ENTRYPOINT ["/app/bench-go"]
CMD ["--workers", "1", "--conns-per-worker", "1", "--tx-count", "5000", "--reps", "3"]
