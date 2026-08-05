/// Driver abstraction for the YCSB MongoDB benchmark.
///
/// A [YcsbDriver] owns the connection resources and runs the load phase; it
/// hands out one [YcsbWorker] per concurrent run-phase loop, each owning a
/// connection for its lifetime so the measured phase pays no per-op acquire.
library;

import 'ycsb_workload.dart';

abstract interface class YcsbDriver {
  /// Opens connections / pool. `conns` = concurrency of the run phase.
  Future<void> setup(int conns);

  /// Inserts `cfg.recordCount` records (the load phase; unmeasured).
  Future<void> load(YcsbConfig cfg);

  /// Drops the working collection to an empty state, WITHOUT populating it.
  /// Used by the write-heavy (insert) workload, whose measured phase is the
  /// insertion itself (F1-Mongo). Unmeasured.
  Future<void> resetEmpty();

  /// Returns one worker bound to a connection. Called `conns` times.
  Future<YcsbWorker> worker();

  /// Releases everything.
  Future<void> close();
}

abstract interface class YcsbWorker {
  /// Reads the record with key `_id == key` (decodes the document).
  Future<void> read(int key);

  /// Updates one [field] of the record with key `_id == key`.
  Future<void> update(int key, Map<String, Object?> field);

  /// Inserts one document (write-heavy `--batch 1` baseline).
  Future<void> insertOne(Map<String, Object?> doc);

  /// Inserts [docs] in one bulk operation (write-heavy `--batch B`, the F1
  /// lever under test).
  Future<void> insertMany(List<Map<String, Object?>> docs);
}
