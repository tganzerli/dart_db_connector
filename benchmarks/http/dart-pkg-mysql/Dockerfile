# benchmarks/http/dart-pkg-mysql — Shelf + mysql_client 0.0.27 (pub.dev).
#
# Pure-Dart driver — no native lib, no C toolchain (mysql_client speaks the
# MySQL wire protocol directly, so no libmysqlclient/libmariadb at runtime).
# Uses the Dart team's canonical AOT recipe from https://hub.docker.com/_/dart:
#
#   1. builder (dart:stable): cache `pub get` by copying pubspec.* first,
#      then `dart build cli` to produce a structured bundle in
#      build/cli/<platform>/bundle/{bin, lib}.
#   2. runtime (scratch): copy the SDK's `/runtime/` (ld-linux, libc,
#      nsswitch.conf, CA certs) + the bundle. Pure-Dart driver means
#      we need no native client lib — scratch is enough.

# ─────────── Stage 1: builder ───────────
FROM dart:stable AS build

WORKDIR /app

# Cache `pub get` on its own layer — `pubspec.lock` is committed so the
# offline run is reproducible.
COPY benchmarks/http/dart-pkg-mysql/pubspec.* ./
RUN dart pub get

# Now bring in the rest of the source; rerun pub get --offline to
# refresh anything that might have changed locally but not in pubspec.
COPY benchmarks/http/dart-pkg-mysql/ ./
RUN dart pub get --offline

# Structured AOT bundle: build/cli/<platform>/bundle/{bin/server, lib/}.
RUN dart build cli --target bin/server.dart -o /out

# ─────────── Stage 2: runtime ───────────
FROM scratch

# `/runtime/` ships with dart:stable: ld-linux + libc + nsswitch.conf
# + CA certs. Required for AOT exes to run on a minimal base.
COPY --from=build /runtime/ /
COPY --from=build /out/bundle/ /app/

EXPOSE 8080
CMD ["/app/bin/server"]
