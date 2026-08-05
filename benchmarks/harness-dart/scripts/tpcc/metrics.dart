/// Latency + RSS sample collection and CSV serialization.
library;

import 'dart:io';

class TpccSample {
  final int runId;
  final String driver;
  final String txType;
  final int latencyUs;
  final bool success;
  final int? workerId; // null in single-isolate; set in multi-isolate
  final String? topology; // null when not part of a topology sweep
  const TpccSample(
      this.runId, this.driver, this.txType, this.latencyUs, this.success,
      {this.workerId, this.topology});
}

class RssSample {
  final int runId;
  final String driver;
  final int txCount;
  final int rssBytes;
  const RssSample(this.runId, this.driver, this.txCount, this.rssBytes);
}

class MetricsCollector {
  final List<TpccSample> samples = [];
  final List<RssSample> rssSamples = [];

  void recordTx(TpccSample s) => samples.add(s);
  void recordRss(RssSample s) => rssSamples.add(s);

  /// Appends to [path]. If file doesn't exist, writes a header first.
  /// Columns `worker_id` / `topology` are empty when not applicable.
  Future<void> writeSamplesCsv(String path) async {
    final file = File(path);
    final exists = file.existsSync();
    final sink = file.openWrite(mode: FileMode.append);
    if (!exists) {
      sink.writeln(
          'run_id,driver,tx_type,latency_us,success,worker_id,topology');
    }
    for (final s in samples) {
      sink.writeln('${s.runId},${s.driver},${s.txType},${s.latencyUs},'
          '${s.success ? 1 : 0},${s.workerId ?? ''},${s.topology ?? ''}');
    }
    await sink.close();
  }

  Future<void> writeRssCsv(String path) async {
    final file = File(path);
    final exists = file.existsSync();
    final sink = file.openWrite(mode: FileMode.append);
    if (!exists) {
      sink.writeln('run_id,driver,tx_count,rss_bytes');
    }
    for (final s in rssSamples) {
      sink.writeln('${s.runId},${s.driver},${s.txCount},${s.rssBytes}');
    }
    await sink.close();
  }
}

/// Computes p50/p95/p99 over a list of microsecond latencies. Sorts in
/// place. Returns map keyed by percentile name.
Map<String, int> percentiles(List<int> latencies) {
  if (latencies.isEmpty) return const {'p50': 0, 'p95': 0, 'p99': 0};
  latencies.sort();
  int at(double frac) {
    final i = (frac * (latencies.length - 1)).round();
    return latencies[i];
  }

  return {
    'p50': at(0.5),
    'p95': at(0.95),
    'p99': at(0.99),
  };
}
