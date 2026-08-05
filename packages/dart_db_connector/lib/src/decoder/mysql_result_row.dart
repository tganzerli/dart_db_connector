/// Ergonomic API for reading MySQL result rows decoded as Dart values.
///
/// Mirror of `result_row.dart` (PostgreSQL) over the MySQL binding's
/// zero-copy ABI. The underlying `native_mysql_result_t*` caches one row
/// at a time on the C side, so [MysqlResultRow] reads a row's columns
/// together (the natural access pattern) to stay zero-copy.
///
/// **Lifetime:** [MysqlResultSet] and any [MysqlResultRow]s derived from
/// it are valid only while the underlying result handle is alive. Free it
/// eagerly with [release]; a finalizer is a safety net.
library;

import 'dart:ffi' as ffi;

import '../bindings/mysql_binding.dart';
import 'mysql_decode_plan.dart';
import 'mysql_type.dart';

/// Internal handle passed to the Finalizer to free a result.
class _MysqlResultHandle {
  final MysqlBinding binding;
  final ffi.Pointer<ffi.Void> result;
  const _MysqlResultHandle(this.binding, this.result);
}

/// Snapshot of a MySQL result exposing decoded rows and column metadata.
class MysqlResultSet {
  final MysqlBinding? _binding;
  final ffi.Pointer<ffi.Void>? _result;

  /// Number of rows in the result. 0 for non-SELECT statements.
  final int rowCount;

  /// Number of columns in the result. 0 for non-SELECT statements.
  final int colCount;

  /// Cached decode layout for this result shape: column names,
  /// name→index map, type codes, and per-column decoders. Shared by
  /// reference across every [MysqlResultSet] of the same shape
  /// (see `mysql_decode_plan.dart`).
  final MysqlDecodePlan _plan;

  /// Column names, indexed by column position.
  List<String> get columnNames => _plan.columnNames;

  /// MySQL `enum_field_types` codes, indexed by column position.
  List<int> get columnTypeCodes => _plan.columnTypeCodes;

  /// Affected-row count for the last DML statement (INSERT/UPDATE/DELETE).
  /// 0 for SELECT.
  final int affectedRows;

  /// Per-isolate cache of decode plans, keyed by result shape.
  static final MysqlPlanCache _planCache = MysqlPlanCache();

  bool _released = false;

  static final Finalizer<_MysqlResultHandle> _finalizer =
      Finalizer<_MysqlResultHandle>((h) => h.binding.clearResult(h.result));

  MysqlResultSet._(
    this._binding,
    this._result,
    this.rowCount,
    this.colCount,
    this._plan,
    this.affectedRows,
  ) {
    final b = _binding;
    final r = _result;
    if (b != null && r != null) {
      _finalizer.attach(this, _MysqlResultHandle(b, r), detach: this);
    }
  }

  /// An empty result set (no rows, no columns). Used for statements that
  /// legitimately produce no row set when the caller still expects a
  /// [MysqlResultSet] shape.
  factory MysqlResultSet.empty() =>
      MysqlResultSet._(null, null, 0, 0, MysqlDecodePlan.empty, 0);

  /// Reads metadata (counts, affected rows) from a freshly returned result
  /// handle and resolves its decode plan. Cheap — no row data is touched.
  ///
  /// [usePlanCache] (default `true`) consults the per-isolate
  /// [MysqlPlanCache]; `false` builds a fresh plan without touching the
  /// cache (used by the decode A/B microbenchmark).
  factory MysqlResultSet.fromResult(
      MysqlBinding binding, ffi.Pointer<ffi.Void> result,
      {bool usePlanCache = true}) {
    final cols = binding.colCount(result);
    final plan = usePlanCache
        ? _planCache.planFor(binding, result, cols)
        : MysqlDecodePlan.buildMysql(binding, result, cols);
    return MysqlResultSet._(
      binding,
      result,
      binding.rowCount(result),
      cols,
      plan,
      binding.affectedRows(result),
    );
  }

  /// Frees the underlying result immediately and detaches the finalizer.
  /// Idempotent. After calling, accessing any [MysqlResultRow] from this
  /// set is undefined behaviour.
  void release() {
    if (_released) return;
    _released = true;
    final b = _binding;
    final r = _result;
    if (b != null && r != null) {
      b.clearResult(r);
      _finalizer.detach(this);
    }
  }

  /// Returns the [MysqlResultRow] at index [i].
  MysqlResultRow row(int i) {
    RangeError.checkValueInInterval(i, 0, rowCount - 1, 'i');
    return MysqlResultRow._(this, i);
  }

  /// Lazy iterable over rows in result order.
  Iterable<MysqlResultRow> get rows sync* {
    for (var i = 0; i < rowCount; i++) {
      yield row(i);
    }
  }

  /// Returns the [MysqlType] tag for column [col] (by index or name).
  MysqlType typeOf(Object col) =>
      mysqlTypeFromCode(columnTypeCodes[_resolve(col)]);

  int _resolve(Object col) {
    if (col is int) {
      RangeError.checkValueInInterval(col, 0, colCount - 1, 'col');
      return col;
    }
    if (col is String) {
      final idx = _plan.nameToIndex[col];
      if (idx == null) {
        throw ArgumentError('Unknown column: "$col". Known: $columnNames');
      }
      return idx;
    }
    throw ArgumentError('col must be int or String, got ${col.runtimeType}');
  }
}

/// A single row of a [MysqlResultSet]. Decodes values lazily on access.
///
/// For type codes not mapped in [MysqlType], `row[col]` returns a raw
/// `Uint8List` (zero-copy view over the libmysqlclient row buffer).
class MysqlResultRow {
  final MysqlResultSet _set;
  final int _index;

  MysqlResultRow._(this._set, this._index);

  /// Row index within the parent [MysqlResultSet].
  int get index => _index;

  /// Decoded value for column [key] (by `int` index or `String` name).
  /// Returns `null` when the underlying cell is SQL NULL.
  Object? operator [](Object key) {
    final col = _set._resolve(key);
    final binding = _set._binding!;
    final result = _set._result!;
    final ptr = binding.rawValue(result, _index, col);
    if (ptr == ffi.nullptr) return null;
    final length = binding.rawLength(result, _index, col);
    return _set._plan.decoders[col](ptr, length);
  }

  // ── Typed helpers ──

  int? getInt(Object key) => this[key] as int?;
  double? getDouble(Object key) => this[key] as double?;
  String? getString(Object key) => this[key] as String?;
  DateTime? getDateTime(Object key) => this[key] as DateTime?;
  Object? getJson(Object key) => this[key];

  /// Returns the bytes of the cell as a `Uint8List` (zero-copy view).
  /// Returns `null` on SQL NULL.
  Object? getBytes(Object key) => this[key];

  /// Materialises the row as a `Map<String, Object?>`.
  Map<String, Object?> toMap() =>
      {for (var c = 0; c < _set.colCount; c++) _set.columnNames[c]: this[c]};

  @override
  String toString() => toMap().toString();
}
