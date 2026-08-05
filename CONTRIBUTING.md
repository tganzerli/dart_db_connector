# Contributing

Thanks for looking. This document covers the two things most likely to trip you up:
the ABI contract between Dart and C, and the rule that performance claims need
evidence.

## Repository layout

```
packages/dart_db_connector/   the published package (Dart + native C sources)
benchmarks/                   reproduction suite (not published to pub.dev)
```

Publishing is scoped to the package directory. Nothing under `benchmarks/` reaches
pub.dev, so put anything measurement-related there.

## Building

```bash
cd packages/dart_db_connector
cmake -S native/c -B native/c/build
cmake --build native/c/build
dart pub get
dart test
```

Tests that touch a real database need one running. Unit tests (BSON round-trip,
decode plans, parameter marshalling, public API surface) need nothing.

## ABI stability policy

The Dart bindings and the C headers are a single contract expressed in two
languages. Breaking that contract silently produces memory corruption, not a
compile error, so it is versioned explicitly.

Each driver carries its own independent ABI version, exposed by C
(`native_db_abi_version`, `native_mysql_abi_version`, ...) and asserted from Dart
at load time.

- **MAJOR** — any change to an existing signature: parameter added or removed, type
  or size changed, semantics of a return value changed, struct layout altered.
- **MINOR** — purely additive: a new function, a new constant. Existing symbols must
  behave identically. Resets on every MAJOR bump.

A change to any `native/c/include/*.h` requires, **in the same pull request**:

1. the ABI constant bumped in C;
2. the matching expectation updated in `lib/src/bindings/_*_abi_constants.dart`;
3. the Dart binding updated to match the new signature;
4. an entry in `CHANGELOG.md` explaining what changed and why.

Splitting these across pull requests leaves the repository in a state where Dart and
C disagree, which the load-time assertion will catch as a runtime failure — but only
for whoever runs it next.

## Performance claims

Any quantitative claim — throughput, latency, percentiles, CPU, memory, FFI
overhead — needs a reproducible measurement behind it. Not a number from a local
run, but a command someone else can execute.

Concretely, a pull request claiming a performance change should state the hardware,
OS and library versions; the exact command; the baseline compared against; and
enough repetitions to support a confidence interval. `benchmarks/README.md`
describes the protocol the existing results use.

Two things that will get a claim rejected:

- **Battery-mode measurement.** Running several drivers inside one Docker session.
  State leaks between runs; see the isolation protocol.
- **Re-running until the number is favourable.** If a hypothesis is refuted, report
  the refutation. A negative result under a clearly stated condition is worth more
  than a flattering number with an unclear one.

## Style

- Code, comments, identifiers and commit messages in English.
- `dart format` before committing; CI enforces it.
- `dart analyze` must be clean.
- Comments should explain *why*. If the reason lives in a document the reader cannot
  open, the comment is not useful — write the reason inline.

## Reporting bugs

A native crash is far easier to diagnose with: the driver, the platform and
architecture, whether the binary was pre-built or locally compiled, and the client
library version. If you can reproduce it against a public database image, include
the Compose snippet.
