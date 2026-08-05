/// Codec plan for MySQL — cached decode layout keyed by result **shape**.
///
/// The mirror of `decode_plan.dart` (PostgreSQL) over the MySQL binding.
/// The pre-plan read path re-derived everything on every query: per column
/// a `fieldName().toDartString()` (FFI + UTF-8 decode + `String` alloc) +
/// `fieldType()` (FFI), plus a rebuilt name→index map — even when the same
/// result shape repeats. And per cell it branched on the `enum_field_types`
/// code (a `switch`) before decoding.
///
/// A [MysqlDecodePlan] captures, once per shape: the column names, the
/// name→index map, and a vector of per-column [MysqlCellDecoder]s (the type
/// `switch` resolved ahead of time — A2). [MysqlPlanCache] keys plans by a
/// fingerprint of the column type codes (ints only, no string work — A1) and
/// **verifies** a candidate by comparing the raw column-name bytes, so two
/// shapes that share type codes but differ in names never alias.
///
/// **Correctness of keying (why bytes, not just the hash):** two queries can
/// produce identical type codes with different names (`SELECT a, b` vs
/// `SELECT x, y` of the same types). The fingerprint only narrows the search;
/// the byte-exact name check decides the hit, so a wrong plan is structurally
/// impossible. A schema change that alters a column's type changes its code →
/// the fingerprint changes; a rename fails the byte check → a fresh plan is
/// built. No manual invalidation is ever required.
///
/// **Lifetime:** a plan stores only Dart heap (names, closures, cached name
/// bytes). It never retains a `native_mysql_result_t*`, so caching is
/// independent of `MysqlResultSet.release()` / the finalizer.
///
/// **Isolation:** the cache is per-isolate (`static final` in library scope).
/// Dart isolates do not share heap, so no lock is needed.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bindings/mysql_binding.dart';
import 'mysql_decoder.dart';

/// Immutable decode layout for one MySQL result shape. Shared (by
/// reference) across every [MysqlResultSet] of the same shape.
final class MysqlDecodePlan {
  /// Column names, indexed by position. Unmodifiable.
  final List<String> columnNames;

  /// `enum_field_types` codes, indexed by position. Unmodifiable.
  final List<int> columnTypeCodes;

  /// name → column index. Unmodifiable.
  final Map<String, int> nameToIndex;

  /// Per-column decoder, resolved once (A2). Length == column count.
  final List<MysqlCellDecoder> decoders;

  /// Raw UTF-8 bytes of each column name (no NUL), for hit verification.
  final List<Uint8List> _rawNames;

  MysqlDecodePlan._(
    this.columnNames,
    this.columnTypeCodes,
    this.nameToIndex,
    this.decoders,
    this._rawNames,
  );

  /// Empty shape (no rows, no columns) — backs `MysqlResultSet.empty()`.
  static final MysqlDecodePlan empty = MysqlDecodePlan._(
    const [],
    const [],
    const {},
    const [],
    const [],
  );

  /// Builds a plan straight from a freshly returned result handle, without
  /// consulting or mutating any cache. Used by the `usePlanCache: false`
  /// A/B path in the decode microbenchmark.
  static MysqlDecodePlan buildMysql(
      MysqlBinding binding, ffi.Pointer<ffi.Void> result, int cols) {
    final names = List<String>.filled(cols, '', growable: false);
    final codes = List<int>.filled(cols, 0, growable: false);
    final rawNames =
        List<Uint8List>.filled(cols, Uint8List(0), growable: false);
    final decoders =
        List<MysqlCellDecoder>.filled(cols, _nullDecoder, growable: false);
    final nameToIndex = <String, int>{};
    for (var c = 0; c < cols; c++) {
      final namePtr = binding.fieldName(result, c);
      final byteLen = namePtr.length; // strlen (Utf8Pointer extension)
      rawNames[c] =
          Uint8List.fromList(namePtr.cast<ffi.Uint8>().asTypedList(byteLen));
      names[c] = namePtr.toDartString(length: byteLen);
      final code = binding.fieldType(result, c);
      codes[c] = code;
      decoders[c] = mysqlTextDecoderForCode(code);
      nameToIndex[names[c]] = c;
    }
    return MysqlDecodePlan._(
      List.unmodifiable(names),
      List.unmodifiable(codes),
      Map.unmodifiable(nameToIndex),
      List.unmodifiable(decoders),
      rawNames,
    );
  }

  static Object? _nullDecoder(ffi.Pointer<ffi.Uint8> ptr, int len) => null;
}

/// Per-isolate cache of [MysqlDecodePlan]s keyed by type-code fingerprint,
/// with byte-exact name verification and a bounded size. Insertion-order
/// (FIFO) eviction keeps the hit path reorder-free (see `decode_plan.dart`).
final class MysqlPlanCache {
  static const int _maxPlans = 256;

  final Map<int, List<MysqlDecodePlan>> _buckets = {};
  final List<({int hash, MysqlDecodePlan plan})> _order = [];

  /// Returns the cached plan for the shape of [result], building and
  /// inserting one on a miss. [cols] is the already-read column count.
  MysqlDecodePlan planFor(
      MysqlBinding binding, ffi.Pointer<ffi.Void> result, int cols) {
    final h = _fingerprint(binding, result, cols);
    final bucket = _buckets[h];
    if (bucket != null) {
      for (final plan in bucket) {
        if (_namesMatch(plan, binding, result, cols)) return plan; // hit
      }
    }
    final plan = MysqlDecodePlan.buildMysql(binding, result, cols);
    (_buckets[h] ??= <MysqlDecodePlan>[]).add(plan);
    _order.add((hash: h, plan: plan));
    if (_order.length > _maxPlans) _evictOldest();
    return plan;
  }

  /// FNV-1a over `(cols, code₀…code_{n-1})`. Only integer reads.
  int _fingerprint(
      MysqlBinding binding, ffi.Pointer<ffi.Void> result, int cols) {
    var h = 0x811c9dc5;
    h = _mix(h, cols);
    for (var c = 0; c < cols; c++) {
      h = _mix(h, binding.fieldType(result, c));
    }
    return h;
  }

  static int _mix(int h, int value) {
    h ^= value & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
    return h;
  }

  /// Byte-exact comparison of the live column names against a candidate
  /// plan's cached name bytes. No `toDartString`, no allocation.
  bool _namesMatch(MysqlDecodePlan plan, MysqlBinding binding,
      ffi.Pointer<ffi.Void> result, int cols) {
    if (plan.columnNames.length != cols) return false;
    for (var c = 0; c < cols; c++) {
      final raw = binding.fieldName(result, c).cast<ffi.Uint8>();
      final cached = plan._rawNames[c];
      var i = 0;
      for (; i < cached.length; i++) {
        if (raw[i] != cached[i]) return false;
      }
      if (raw[i] != 0) return false; // live name longer than cached
    }
    return true;
  }

  void _evictOldest() {
    final e = _order.removeAt(0);
    final bucket = _buckets[e.hash];
    if (bucket != null) {
      bucket.remove(e.plan);
      if (bucket.isEmpty) _buckets.remove(e.hash);
    }
  }

  /// Test-only: number of plans currently held.
  int get size => _order.length;
}
