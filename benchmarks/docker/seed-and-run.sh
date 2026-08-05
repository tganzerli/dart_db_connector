#!/usr/bin/env bash
# Wrapper: reset schema + seed + run bench, dentro do container.
# Os 3 passos compartilham o mesmo POSTGRES_HOST/PORT/etc. via env.
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/outputs}"
mkdir -p "$OUTPUT_DIR"

echo "[setup] schema reset..."
PGPASSWORD="$POSTGRES_PASSWORD" psql \
  -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -f /app/tpcc_schema.sql

echo "[setup] seed..."
/app/bench_seed

echo "[bench] $@"
exec "$@"
