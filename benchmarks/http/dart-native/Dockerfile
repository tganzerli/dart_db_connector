# bench/http/dart-native — Shelf + dart_db_connector (FFI over libpq).
#
# Multi-stage; runtime stays on debian:stable-slim because libpq5 is a
# runtime dependency of libnative_db.so (rules out FROM scratch — static
# linking libpq is a separate change
# adjacent and out of scope here).
#
# Recipe adapted from https://hub.docker.com/_/dart with:
#   * `pub get` cache layer (copy pubspec.* first; faster iteration).
#   * `dart build cli` for a structured bundle (bin/server + lib/).
#   * libnative_db.so placed at `lib/_native/<os>-<arch>/` (the resolver's
#     pub-cache mirror path).

# ─────────── Stage 1: builder ───────────
FROM dart:stable AS build

# Toolchain for libnative_db.so (CMake + libpq-dev) only — heavy deps
# stay in the build stage, never reach the runtime image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        libpq-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 1) Cache `pub get` on its own layer. dart_db_connector is a path-dep,
#    so the dart/pubspec.yaml + dart/pubspec.lock are also copied first.
COPY dart/pubspec.* /build/dart/
COPY bench/http/dart-native/pubspec.* /build/bench/http/dart-native/

# Resolve dart_db_connector + the server's pubspec in two cache-friendly
# layers. `dart pub get` against the path-dep needs lib/ structure to
# pick up the package; we provide a minimal stub of `dart/lib/` to
# satisfy that without invalidating the cache when only sources change.
# (Once we copy the real lib/ below, `dart pub get --offline` picks up
#  the actual code without re-fetching anything.)
RUN mkdir -p /build/dart/lib \
    && echo "library dart_db_connector;" > /build/dart/lib/dart_db_connector.dart \
    && cd /build/dart && dart pub get \
    && cd /build/bench/http/dart-native && dart pub get

# 2) Real source. native first (CMake build), then dart/, then the server.
COPY native /build/native
COPY dart   /build/dart
COPY bench/http/dart-native /build/bench/http/dart-native

# Strip any host build artefacts that snuck in via the COPY (build dirs,
# .dart_tool with absolute host paths).
RUN rm -rf /build/native/c/build \
    && find /build -type d -name '.dart_tool' -exec rm -rf {} + 2>/dev/null || true

# Refresh pub against the real sources (no network).
RUN cd /build/dart && dart pub get --offline \
    && cd /build/bench/http/dart-native && dart pub get --offline

# 3) libnative_db.so (Linux, current arch). PG-only: toggle the MySQL/Mongo/
# SQLite drivers OFF (added to CMakeLists in July F4.*; this PG HTTP image only
# ships libpq-dev, so building them would FATAL on mysql_config/libmongoc).
RUN cd /build/native/c \
    && cmake -B build -S . -DCMAKE_BUILD_TYPE=Release \
         -DBUILD_NATIVE_MYSQL=OFF -DBUILD_NATIVE_MONGO=OFF -DBUILD_NATIVE_SQLITE=OFF \
    && cmake --build build --target native_db

# 4) AOT bundle (bin/server + lib/).
RUN dart --version  # logged in build output for reproducibility
RUN cd /build/bench/http/dart-native \
    && dart build cli --target bin/server.dart -o /out

# 5) Stage libnative_db.so. With `dart build cli` the exe lives in
#    bundle/bin/server, so the resolver's path #2 (`<exe_dir>/...`)
#    resolves to /app/bin/... in the runtime stage — not where the
#    bundle puts its lib/. Two ways out:
#      (a) write the .so to /out/bundle/bin/ (flat next to the exe) —
#          resolver path #2 flat finds it.
#      (b) set DART_DB_CONNECTOR_NATIVE_LIB_PATH env in the runtime
#          stage — resolver path #1 wins regardless of layout.
#    We do (a) (works without ENV reliance — robust if the env var is
#    ever stripped by an orchestrator) AND set the ENV in stage 2 as
#    belt-and-suspenders.
RUN MACHINE="$(uname -m)" \
    && case "$MACHINE" in \
         aarch64) ARCH=arm64 ;; \
         x86_64)  ARCH=x64 ;; \
         *)       ARCH="$MACHINE" ;; \
       esac \
    && PLAT="linux-$ARCH" \
    && cp /build/native/c/build/libnative_db.so /out/bundle/bin/ \
    && mkdir -p "/out/bundle/lib/_native/$PLAT" \
    && cp /build/native/c/build/libnative_db.so "/out/bundle/lib/_native/$PLAT/" \
    && echo "$PLAT" > /out/.platform

# ─────────── Stage 2: runtime ───────────
FROM debian:stable-slim

# Only what the runtime actually needs: libpq5 for the .so to link.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/bundle/ /app/

# Three layers of resolution belt-and-suspenders:
#   1. ENV var (resolver path #1) — wins regardless of layout.
#   2. .so co-located with exe at /app/bin/ (resolver path #2 flat).
#   3. .so at /app/bin/lib/_native/<plat>/... (resolver path #2 mirror).
# LD_LIBRARY_PATH lets the dynamic loader find libnative_db.so once
# dart:ffi opens it.
ENV DART_DB_CONNECTOR_NATIVE_LIB_PATH=/app/bin/libnative_db.so
ENV LD_LIBRARY_PATH=/app/bin:/app/lib:${LD_LIBRARY_PATH}

EXPOSE 8080
CMD ["/app/bin/server"]
