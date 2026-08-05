# benchmarks/http/dart-native-mongo — Shelf + dart_db_connector MongoDB (FFI over
# libmongoc). HTTP MySQL/MongoDB benchmark. Combina o bundle HTTP (dart build cli) do
# benchmarks/http/dart-native/Dockerfile com o build de libnative_mongo.so do
# benchmarks/docker/Dockerfile.dart-mongo.
#
# ⚠ CMakeLists.txt tem find_package(PostgreSQL REQUIRED) + option BUILD_NATIVE_*.
#   Buildamos SÓ o target native_mongo, desligando mysql/sqlite (senão o
#   configure exige libmysqlclient/libsqlite3 ausentes) — libpq-dev é
#   necessário só para o find_package(PostgreSQL) do configure.

# ─────────── Stage 1: builder ───────────
FROM dart:stable AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config libpq-dev libmongoc-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build

# Cache pub get (path-dep dart_db_connector).
COPY dart/pubspec.* /build/packages/dart_db_connector/
COPY benchmarks/http/dart-native-mongo/pubspec.* /build/benchmarks/http/dart-native-mongo/
RUN mkdir -p /build/packages/dart_db_connector/lib \
    && echo "library dart_db_connector;" > /build/packages/dart_db_connector/lib/dart_db_connector.dart \
    && cd /build/packages/dart_db_connector && dart pub get \
    && cd /build/benchmarks/harness-dart/http/dart-native-mongo && dart pub get

# Fontes reais.
COPY packages/dart_db_connector /build/packages/dart_db_connector
COPY benchmarks/http/dart-native-mongo /build/benchmarks/http/dart-native-mongo
RUN rm -rf /build/packages/dart_db_connector/native/c/build \
    && find /build -type d -name '.dart_tool' -exec rm -rf {} + 2>/dev/null || true
RUN cd /build/packages/dart_db_connector && dart pub get --offline \
    && cd /build/benchmarks/harness-dart/http/dart-native-mongo && dart pub get --offline

# libnative_mongo.so (só o target mongo; mysql/sqlite off).
RUN cd /build/packages/dart_db_connector/native/c \
    && cmake -B build -S . -DCMAKE_BUILD_TYPE=Release \
         -DBUILD_NATIVE_MYSQL=OFF -DBUILD_NATIVE_SQLITE=OFF \
    && cmake --build build --target native_mongo

# AOT bundle.
RUN cd /build/benchmarks/harness-dart/http/dart-native-mongo \
    && dart build cli --target bin/server.dart -o /out

# Stage libnative_mongo.so no bundle: flat ao lado do exe (path #2 flat) e no
# mirror lib/_native/<plat>/ (path #2 mirror).
RUN MACHINE="$(uname -m)" \
    && case "$MACHINE" in aarch64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) ARCH="$MACHINE" ;; esac \
    && PLAT="linux-$ARCH" \
    && cp /build/packages/dart_db_connector/native/c/build/libnative_mongo.so /out/bundle/bin/ \
    && mkdir -p "/out/bundle/lib/_native/$PLAT" \
    && cp /build/packages/dart_db_connector/native/c/build/libnative_mongo.so "/out/bundle/lib/_native/$PLAT/"

# ─────────── Stage 2: runtime ───────────
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libmongoc-1.0-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/bundle/ /app/
ENV LD_LIBRARY_PATH=/app/bin:/app/lib:${LD_LIBRARY_PATH}
EXPOSE 8080
CMD ["/app/bin/server"]
