# Native layer

C sources for the four native libraries the Dart package loads through `dart:ffi`.

Pre-built binaries ship with the package for four platforms, so most consumers never
build this. You need it when working from a clone, or on a platform without a
pre-built binary.

## What gets built

| Target | Links against | Output |
|---|---|---|
| `native_db` | `libpq` | `libnative_db.{so,dylib}` |
| `native_mysql` | `libmysqlclient` | `libnative_mysql.{so,dylib}` |
| `native_mongo` | `libmongoc` | `libnative_mongo.{so,dylib}` |
| `native_sqlite` | `libsqlite3` | `libnative_sqlite.{so,dylib}` |

Each is independent: its own ABI version, its own pool, no shared state. A driver
you do not use costs nothing at runtime, because loading is lazy.

## Building

```bash
cmake -S native/c -B native/c/build
cmake --build native/c/build
```

Requires CMake 3.20+, a C11 compiler, and the development headers of whichever
clients you want. Skip the ones whose client library is missing:

```bash
cmake -S native/c -B native/c/build \
  -DBUILD_NATIVE_MYSQL=OFF \
  -DBUILD_NATIVE_MONGO=OFF \
  -DBUILD_NATIVE_SQLITE=OFF
```

On macOS the Homebrew formulas for `libpq`, `mysql-client` and `mongo-c-driver` are
keg-only, so they are not on the default search path. The build script probes the
usual Homebrew prefixes; if you installed them elsewhere, pass `PostgreSQL_ROOT` or
extend `PKG_CONFIG_PATH`.

## Design

Each pool owns **N OS threads, one per connection**. A worker thread runs the
blocking client call and, when the result is ready, posts to a Dart Native Port via
`Dart_PostCObject_DL`. The Dart side never blocks an isolate on I/O, and never
polls.

Results stay in native memory; Dart reads them through typed views rather than
copying. This is why `ResultSet` has an explicit `release()` — the Dart object is a
handle to memory this layer owns.

`src/dart_api_dl.c` and `include/dart/` are vendored from the Dart SDK. Do not edit
them.

## Changing the ABI

The headers here are a contract with the Dart bindings. Read the ABI stability
policy in the repository's `CONTRIBUTING.md` before touching any signature in
`include/*.h` — a mismatch corrupts memory rather than failing to compile.
