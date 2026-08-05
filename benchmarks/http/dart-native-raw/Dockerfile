# benchmarks/http/dart-native-raw — raw dart:io HttpServer + dart_db_connector
# (FFI over libpq). Sibling of benchmarks/http/dart-native (Shelf); identical build,
# only the transport layer differs in bin/server.dart. See that Dockerfile for
# the rationale behind each stage (pub-get cache layer, PG-only native build,
# .so placement + ENV belt-and-suspenders).

# ─────────── Stage 1: builder ───────────
FROM dart:stable AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        libpq-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 1) Cache `pub get`. dart_db_connector is a path-dep, so dart/pubspec.* come first.
COPY dart/pubspec.* /build/packages/dart_db_connector/
COPY benchmarks/http/dart-native-raw/pubspec.* /build/benchmarks/http/dart-native-raw/

RUN mkdir -p /build/packages/dart_db_connector/lib \
    && echo "library dart_db_connector;" > /build/packages/dart_db_connector/lib/dart_db_connector.dart \
    && cd /build/packages/dart_db_connector && dart pub get \
    && cd /build/benchmarks/harness-dart/http/dart-native-raw && dart pub get

# 2) Real source: native, dart/, then the server.
COPY packages/dart_db_connector /build/packages/dart_db_connector
COPY benchmarks/http/dart-native-raw /build/benchmarks/http/dart-native-raw

RUN rm -rf /build/packages/dart_db_connector/native/c/build \
    && find /build -type d -name '.dart_tool' -exec rm -rf {} + 2>/dev/null || true

RUN cd /build/packages/dart_db_connector && dart pub get --offline \
    && cd /build/benchmarks/harness-dart/http/dart-native-raw && dart pub get --offline

# 3) libnative_db.so (Linux, current arch). PG-only.
RUN cd /build/packages/dart_db_connector/native/c \
    && cmake -B build -S . -DCMAKE_BUILD_TYPE=Release \
         -DBUILD_NATIVE_MYSQL=OFF -DBUILD_NATIVE_MONGO=OFF -DBUILD_NATIVE_SQLITE=OFF \
    && cmake --build build --target native_db

# 4) AOT bundle.
RUN dart --version
RUN cd /build/benchmarks/harness-dart/http/dart-native-raw \
    && dart build cli --target bin/server.dart -o /out

# 5) Stage libnative_db.so next to the exe + mirror path.
RUN MACHINE="$(uname -m)" \
    && case "$MACHINE" in \
         aarch64) ARCH=arm64 ;; \
         x86_64)  ARCH=x64 ;; \
         *)       ARCH="$MACHINE" ;; \
       esac \
    && PLAT="linux-$ARCH" \
    && cp /build/packages/dart_db_connector/native/c/build/libnative_db.so /out/bundle/bin/ \
    && mkdir -p "/out/bundle/lib/_native/$PLAT" \
    && cp /build/packages/dart_db_connector/native/c/build/libnative_db.so "/out/bundle/lib/_native/$PLAT/" \
    && echo "$PLAT" > /out/.platform

# ─────────── Stage 2: runtime ───────────
FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/bundle/ /app/

ENV DART_DB_CONNECTOR_NATIVE_LIB_PATH=/app/bin/libnative_db.so
ENV LD_LIBRARY_PATH=/app/bin:/app/lib:${LD_LIBRARY_PATH}

EXPOSE 8080
CMD ["/app/bin/server"]
