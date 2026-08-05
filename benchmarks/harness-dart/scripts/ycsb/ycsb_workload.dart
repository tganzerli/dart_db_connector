/// YCSB-style workload model for the MongoDB benchmark.
///
/// A minimal, self-contained reimplementation of the YCSB core workload —
/// enough for a FAIR cross-driver comparison, without the Java harness.
/// Data model: `recordcount` documents keyed by `_id` (int), each with
/// `fieldcount` string fields of `fieldlength` bytes (default 10×100 ≈ 1 KB).
/// Run phase mixes read/update per the chosen workload, drawing keys from a
/// fixed-seed distribution so every driver hits the SAME key sequence.
library;

import 'dart:math';

/// Operation kinds exercised in the run phase.
enum YcsbOp { read, update, insert }

/// Static parameters shared by load + run.
class YcsbConfig {
  final int recordCount;
  final int fieldCount;
  final int fieldLength;

  const YcsbConfig({
    this.recordCount = 10000,
    this.fieldCount = 10,
    this.fieldLength = 100,
  });
}

/// Builds the field map for a record (deterministic: fixed-length filler).
Map<String, Object?> ycsbFields(YcsbConfig cfg) {
  final value = 'x' * cfg.fieldLength;
  return {for (var f = 0; f < cfg.fieldCount; f++) 'f$f': value};
}

/// A single field update (YCSB updates one random field).
Map<String, Object?> ycsbUpdateField(YcsbConfig cfg, int fieldIndex) {
  return {'f$fieldIndex': 'y' * cfg.fieldLength};
}

/// Read/update ratios of the standard core workloads.
class YcsbWorkload {
  final String name;
  final double readProportion;
  const YcsbWorkload(this.name, this.readProportion);

  static const a = YcsbWorkload('A', 0.50); // 50/50 read/update
  static const b = YcsbWorkload('B', 0.95); // 95/5
  static const c = YcsbWorkload('C', 1.00); // read-only
  static const w = YcsbWorkload('W', 0.00); // write-heavy: pure insert (F1-Mongo)

  /// A write-heavy insert workload: the run phase inserts new documents
  /// (unitary `insertOne` when `--batch 1`, bulk `insertMany` otherwise),
  /// isolating the F1 batching lever. Handled by a dedicated run path in the
  /// runner (does not go through [YcsbMix], which models read/update).
  bool get isWriteHeavy => name == 'W';

  static YcsbWorkload byName(String n) => switch (n.toUpperCase()) {
        'A' => a,
        'B' => b,
        'C' => c,
        'W' => w,
        _ => throw ArgumentError('unknown YCSB workload: $n (use A|B|C|W)'),
      };
}

/// Deterministic operation generator: given a seed, emits the same sequence
/// of (op, key, fieldIndex) for every driver.
class YcsbMix {
  final YcsbConfig cfg;
  final YcsbWorkload workload;
  final Random _rng;
  final _KeyDist _dist;

  YcsbMix(this.cfg, this.workload, int seed, {bool zipfian = true})
      : _rng = Random(seed),
        _dist = zipfian
            ? _Zipfian(cfg.recordCount, seed + 1)
            : _Uniform(cfg.recordCount, seed + 1);

  /// The next operation: its kind, target key, and (for updates) the field.
  ({YcsbOp op, int key, int field}) next() {
    final op =
        _rng.nextDouble() < workload.readProportion ? YcsbOp.read : YcsbOp.update;
    final key = _dist.next();
    final field = _rng.nextInt(cfg.fieldCount);
    return (op: op, key: key, field: field);
  }
}

abstract class _KeyDist {
  int next();
}

class _Uniform implements _KeyDist {
  final int n;
  final Random _rng;
  _Uniform(this.n, int seed) : _rng = Random(seed);
  @override
  int next() => _rng.nextInt(n);
}

/// Standard YCSB Zipfian generator (Gray et al.), constant 0.99. Hot keys
/// cluster at the low end; both drivers see the identical stream.
class _Zipfian implements _KeyDist {
  final int n;
  final Random _rng;
  final double theta = 0.99;
  late final double _zetan;
  late final double _alpha;
  late final double _eta;

  _Zipfian(this.n, int seed) : _rng = Random(seed) {
    final zeta2 = _zeta(2);
    _zetan = _zeta(n);
    _alpha = 1.0 / (1.0 - theta);
    _eta = (1 - pow(2.0 / n, 1 - theta)) / (1 - zeta2 / _zetan);
  }

  double _zeta(int count) {
    var sum = 0.0;
    for (var i = 0; i < count; i++) {
      sum += 1.0 / pow(i + 1, theta);
    }
    return sum;
  }

  @override
  int next() {
    final u = _rng.nextDouble();
    final uz = u * _zetan;
    if (uz < 1.0) return 0;
    if (uz < 1.0 + pow(0.5, theta)) return 1;
    return (n * pow(_eta * u - _eta + 1, _alpha)).toInt() % n;
  }
}
