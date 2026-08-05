# bench/http/dart-pkg-mongo — Shelf + mongo_dart 0.10.9 (pub.dev).
#
# Pure-Dart driver — no native lib, no C toolchain, no mongoc. Uses the
# Dart team's canonical AOT recipe from https://hub.docker.com/_/dart:
#
#   1. builder (dart:stable): cache `pub get` by copying pubspec.* first,
#      then `dart build cli` to produce a structured bundle in
#      build/cli/<platform>/bundle/{bin, lib}.
#   2. runtime (debian:stable-slim): copy the SDK's `/runtime/` (ld-linux,
#      libc, nsswitch.conf, CA certs) + the bundle. mongo_dart is pure
#      Dart, so no libmongoc / native dependency is needed.

# ─────────── Stage 1: builder ───────────
FROM dart:stable AS build

WORKDIR /app

# Cache `pub get` on its own layer — `pubspec.lock` is committed so the
# offline run is reproducible.
COPY bench/http/dart-pkg-mongo/pubspec.* ./
RUN dart pub get

# Now bring in the rest of the source; rerun pub get --offline to
# refresh anything that might have changed locally but not in pubspec.
COPY bench/http/dart-pkg-mongo/ ./
RUN dart pub get --offline

# Structured AOT bundle: build/cli/<platform>/bundle/{bin/server, lib/}.
RUN dart build cli --target bin/server.dart -o /out

# ─────────── Stage 2: runtime ───────────
# scratch (not debian-slim): mongo_dart is pure Dart, so the /runtime/ of the
# dart:stable (ld-linux + libc) basta. Em debian-slim, /lib é symlink
# (merged-usr) e o COPY /runtime/ falha com "cannot copy to non-directory".
FROM scratch

# `/runtime/` ships with dart:stable: ld-linux + libc + nsswitch.conf
# + CA certs. Required for AOT exes to run on a minimal base.
COPY --from=build /runtime/ /
COPY --from=build /out/bundle/ /app/

EXPOSE 8080
CMD ["/app/bin/server"]
