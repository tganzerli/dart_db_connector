# Changelog

## 0.1.0

First public release.

A multi-database connector for Dart backends built on `dart:ffi` over native C
drivers, with a thread-per-connection pool outside the Dart VM and Dart Native Ports
for completion notification.

### Drivers

- **PostgreSQL** over `libpq` — native ABI MAJOR 2, MINOR 2. Connection pool,
  simple and extended query protocols, bound parameters, pipelining, multi-read in
  one round-trip, zero-copy result decoding, `Repository` / `UnitOfWork`, and a
  non-transactional fast path (`withPostgresConnection`).
- **MySQL** over `libmysqlclient` — native ABI MAJOR 1. Connection pool, batched
  writes and reads, decode-plan cache, non-transactional fast path, and native error
  messages surfaced as readable Dart exceptions.
- **MongoDB** over `libmongoc` — native ABI MAJOR 1, MINOR 1. Connection pool,
  zero-copy BSON decoding, typed collection operations, bulk writes, and
  `MongoRepository` reusing the agnostic `Repository` contract.
- **SQLite** over `libsqlite3` — native ABI MAJOR 1, MINOR 2. WAL pool, batching and
  a conditional synchronous fast path.

### Distribution

- Pre-built native binaries for `linux-x64`, `linux-arm64`, `macos-x64` and
  `macos-arm64`, resolved automatically from `lib/_native/<platform>/`.
- Windows is not supported: the native pool uses POSIX threads and has no Win32 path.
- Binaries link dynamically against each database's client library, so those must be
  installed. Dynamic linking is deliberate — statically linking `libmysqlclient`
  (GPLv2) would change the licence of an MIT package.
- Drivers load lazily, and each can be excluded at build time
  (`-DBUILD_NATIVE_MYSQL=OFF` and friends), so you only need the client libraries
  for the databases you actually use.

### Notes

The public API surface has been audited but may still change before 1.0.0. Pin a
version range rather than tracking `any`.

`ResultSet` owns native memory. A finalizer reclaims it, but calling `release()`
explicitly is what keeps resident memory flat under sustained load.
