/// Worker-isolate function for the `driver_us` attribution harness.
///
/// Each spawned isolate runs [attributionWorkerMain] with an
/// [AttrWorkerStart]: it opens its own [PostgresConnectionPool] of
/// `conns` connections, runs `concurrency` concurrent query loops (each
/// holding one leased connection) against a fixed SQL shape, and ships
/// the per-query phase triples (submit/wait/decode µs) back to the
/// orchestrator. No `Pointer<Void>` crosses the isolate boundary — only
/// plain ints/strings (mirrors `tpcc/multi_worker.dart`).
///
/// The phases come from the opt-in `QueryPhaseSink` on
/// `PostgresQueryExecutor` — this harness is the only wiring of it.
// ignore_for_file: invalid_use_of_internal_member, experimental_member_use
library;

import 'dart:isolate';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/postgres/postgres_query_executor.dart';
import 'package:dart_db_connector/src/postgres/query_phase_diagnostics.dart';

import 'tpcc/conn_info.dart';

class AttrWorkerStart {
  final int workerId;

  /// SQL shape executed on every iteration (program-synthesized).
  final String sql;

  /// Pool size for this worker.
  final int conns;

  /// Concurrent query loops within this worker (≤ conns).
  final int concurrency;

  /// Warmup queries per loop, discarded before measurement.
  final int warmupPerLoop;

  /// Measured queries per loop.
  final int measuredPerLoop;

  final SendPort replyPort;

  const AttrWorkerStart({
    required this.workerId,
    required this.sql,
    required this.conns,
    required this.concurrency,
    required this.warmupPerLoop,
    required this.measuredPerLoop,
    required this.replyPort,
  });
}

class AttrWorkerResult {
  /// Flattened phase triples: [submit0, wait0, decode0, submit1, ...].
  final List<int> phases;

  /// Wall-clock of the measured window (all loops in parallel), µs.
  final int wallTimeUs;

  final int rowCount;
  final int colCount;

  const AttrWorkerResult({
    required this.phases,
    required this.wallTimeUs,
    required this.rowCount,
    required this.colCount,
  });
}

/// Top-level entry (required by `Isolate.spawn`).
Future<void> attributionWorkerMain(AttrWorkerStart start) async {
  final pool = PostgresConnectionPool(
    PoolConfig(
      connInfo: connInfo(),
      minSize: start.conns,
      maxSize: start.conns,
    ),
  );
  await pool.start();

  var lastRows = 0, lastCols = 0;

  Future<List<int>> runLoop() async {
    final buf = <int>[];
    final leased = await pool.acquire();
    try {
      final exec = PostgresQueryExecutor(
        pool.binding,
        leased.raw,
        phaseSink: (QueryPhases p) {
          buf
            ..add(p.submitUs)
            ..add(p.waitUs)
            ..add(p.decodeUs);
          lastRows = p.rowCount;
          lastCols = p.colCount;
        },
      );
      final total = start.warmupPerLoop + start.measuredPerLoop;
      for (var i = 0; i < total; i++) {
        if (i == start.warmupPerLoop) buf.clear(); // drop warmup triples
        (await exec.execute(start.sql)).release();
      }
    } finally {
      await leased.release();
    }
    return buf;
  }

  final wall = Stopwatch()..start();
  final loops = await Future.wait(
      [for (var i = 0; i < start.concurrency; i++) runLoop()]);
  wall.stop();

  await pool.close();

  final merged = <int>[];
  for (final l in loops) {
    merged.addAll(l);
  }

  start.replyPort.send(AttrWorkerResult(
    phases: merged,
    wallTimeUs: wall.elapsedMicroseconds,
    rowCount: lastRows,
    colCount: lastCols,
  ));
}
