# Multi-stage build para o bench harness Dart.
#
# Stage 1 (builder): compila a libnative_db.so Linux + AOT-compila os
# binários de bench. Usa imagem Dart oficial (host arch — em macOS arm64
# host, produz binários Linux ARM64; em x86_64, produz x86_64).
#
# Stage 2 (runtime): só libpq5 + binários AOT + libnative_db.so.
# Imagem final ~80-100MB (Debian slim base).

# ─────────── Stage 1: builder ───────────
FROM dart:stable AS builder

# Toolchain C + libpq dev headers + cmake para construir libnative_db.so.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        libpq-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copia código fonte. .dockerignore evita copiar build artifacts e CSVs.
COPY native /build/native
COPY dart /build/dart
COPY benchmarks /build/benchmarks

# Limpa artefatos de build do host (host build/ pode ser macOS arm64,
# .dart_tool/.packages podem ter paths absolutos do host).
RUN rm -rf /build/native/c/build \
    && find /build -type d -name '.dart_tool' -exec rm -rf {} + 2>/dev/null || true \
    && find /build -type d -name 'build' -path '*/native/*' -exec rm -rf {} + 2>/dev/null || true

# Constrói libnative_db.so para Linux. Só o driver Postgres — os outros
# (MySQL/Mongo/SQLite, default ON no CMakeLists desde a F4) exigem dev
# headers this builder does not install; disabling them explicitly avoids
# o FATAL_ERROR de `find_program(mysql_config)`. O bench Postgres só linka
# libnative_db.so.
RUN cd /build/native/c \
    && cmake -B build -S . -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_NATIVE_MYSQL=OFF \
        -DBUILD_NATIVE_MONGO=OFF \
        -DBUILD_NATIVE_SQLITE=OFF \
    && cmake --build build

# Resolve Dart dependencies (the host runs `dart pub get` before the copies
# poderem ter `.dart_tool` antigos; rodamos novamente aqui para garantir
# resolução compatível com o SDK do builder).
RUN cd /build/dart && dart pub get
RUN cd /build/benchmarks && dart pub get

# AOT-compile the bench binaries. `dart compile exe` produces a native
# do arch host do builder. Os binários linkam libnative_db.so via
# DynamicLibrary em runtime (LD_LIBRARY_PATH no runtime stage).
RUN mkdir -p /out \
    && cd /build/benchmarks \
    && dart compile exe scripts/tpcc_small.dart -o /out/bench_tpcc_small \
    && dart compile exe scripts/tpcc_multi.dart -o /out/bench_tpcc_multi \
    && dart compile exe scripts/pipeline_vs_sequential.dart -o /out/bench_pipeline \
    && dart compile exe scripts/pool_topology_sweep.dart -o /out/bench_pool_topology \
    && dart compile exe scripts/micro_ffi.dart -o /out/bench_micro_ffi \
    && dart compile exe scripts/pool_diagnostics.dart -o /out/bench_pool_diagnostics \
    && dart compile exe scripts/tpcc_single_isolate.dart -o /out/bench_tpcc_single_isolate \
    && dart compile exe scripts/micro_redundant_rollback.dart -o /out/bench_rollback_micro \
    && dart compile exe fixtures/tpcc_seed.dart -o /out/bench_seed

# Copia .so para o /out usando o path canônico do resolver
# This layout mirrors the structure
# futura `~/.pub-cache/.../lib/_native/<os>-<arch>/libnative_db.so`
# que o repo pub.dev vai popular via CI. O resolver da biblioteca
# (`dart/lib/src/native_lib_loader.dart` path #2 — variante
# pub-cache mirror) localiza este caminho automaticamente quando
# the AOT exe sits at `/app/<exe>` and the library at
# `/app/lib/_native/<platform>/<fileName>`.
#
# The architecture is detected with `uname -m` on the host that is
# construindo a imagem (Docker Desktop em Apple Silicon = aarch64;
# x86_64 host = x86_64). Normalização para o convention do resolver:
#   aarch64  → arm64
#   x86_64   → x64
#
# Smoke test: `f1a-single-isolate.sh` ou `f1b-tail-sweep.sh` validam
# end-to-end que o exe encontra a lib.
RUN MACHINE="$(uname -m)" \
    && case "$MACHINE" in \
         aarch64) ARCH=arm64 ;; \
         x86_64)  ARCH=x64 ;; \
         *)       ARCH="$MACHINE" ;; \
       esac \
    && PLAT="linux-$ARCH" \
    && mkdir -p "/out/lib/_native/$PLAT" \
    && cp /build/native/c/build/libnative_db.so "/out/lib/_native/$PLAT/" \
    && echo "[dockerfile] native lib placed at /out/lib/_native/$PLAT/libnative_db.so"

# Copia fixtures SQL para uso no runtime (reset DB).
RUN cp /build/benchmarks/fixtures/tpcc_schema.sql /out/

# ─────────── Stage 2: runtime ───────────
FROM debian:stable-slim

# Só libpq client + ca-certificates (TLS futuro).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        ca-certificates \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Binários AOT + lib nativa + fixture schema.
COPY --from=builder /out/ /app/

# Garante que dart:ffi.DynamicLibrary.open encontre a .so.
ENV LD_LIBRARY_PATH=/app:${LD_LIBRARY_PATH}

# Volume mount /outputs para CSVs/SVGs.
VOLUME ["/outputs"]

# Default: TPC-C single-isolate, 3 reps × 5k tx, native driver.
# Override via `docker compose run bench-dart <other-args>`.
ENTRYPOINT ["/app/bench_tpcc_small"]
CMD ["--driver", "native", "--tx-count", "5000", "--reps", "3"]
