/// Ergonomic API for reading SQLite result rows decoded as Dart values.
///
/// Mirror of `mysql_result_row.dart`, but over a MATERIALISED result: the
/// worker copied every cell into an owned buffer, so reads are zero-copy
/// views (`asTypedList`) over that buffer and random-access is safe. SQLite
/// is dynamically typed, so the type is PER-CELL (`cellType(row, col)`), not
/// per-column.
///
/// Cell encoding (from `native_sqlite`): INTEGER/FLOAT are 8 bytes
/// host-endian; TEXT is UTF-8; BLOB is raw bytes; NULL is a null pointer.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bindings/sqlite_binding.dart';

/// SQLite `sqlite3_column_type` codes.
class SqliteCellType {
  static const int integer = 1;
  static const int float = 2;
  static const int text = 3;
  static const int blob = 4;
  static const int nullType = 5;
}

class _SqliteResultHandle {
  final SqliteBinding binding;
  final ffi.Pointer<ffi.Void> result;
  const _SqliteResultHandle(this.binding, this.result);
}

/// Snapshot of a SQLite result exposing decoded rows and column metadata.
class SqliteResultSet {
  final SqliteBinding? _binding;
  final ffi.Pointer<ffi.Void>? _result;

  final int rowCount;
  final int colCount;
  final List<String> columnNames;

  /// `sqlite3_changes` count for the last DML (INSERT/UPDATE/DELETE).
  final int affectedRows;

  late final Map<String, int> _nameToIndex;
  bool _released = false;

  static final Finalizer<_SqliteResultHandle> _finalizer =
      Finalizer<_SqliteResultHandle>((h) => h.binding.clearResult(h.result));

  SqliteResultSet._(
    this._binding,
    this._result,
    this.rowCount,
    this.colCount,
    this.columnNames,
    this.affectedRows,
  ) {
    _nameToIndex = {
      for (var i = 0; i < columnNames.length; i++) columnNames[i]: i
    };
    final b = _binding;
    final r = _result;
    if (b != null && r != null) {
      _finalizer.attach(this, _SqliteResultHandle(b, r), detach: this);
    }
  }

  factory SqliteResultSet.empty() =>
      SqliteResultSet._(null, null, 0, 0, const [], 0);

  factory SqliteResultSet.fromResult(
      SqliteBinding binding, ffi.Pointer<ffi.Void> result) {
    final cols = binding.colCount(result);
    final names = <String>[
      for (var c = 0; c < cols; c++) binding.colName(result, c).toDartString()
    ];
    return SqliteResultSet._(
      binding,
      result,
      binding.rowCount(result),
      cols,
      names,
      binding.affectedRows(result),
    );
  }

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

  SqliteResultRow row(int i) {
    RangeError.checkValueInInterval(i, 0, rowCount - 1, 'i');
    return SqliteResultRow._(this, i);
  }

  Iterable<SqliteResultRow> get rows sync* {
    for (var i = 0; i < rowCount; i++) {
      yield row(i);
    }
  }

  int _resolve(Object col) {
    if (col is int) {
      RangeError.checkValueInInterval(col, 0, colCount - 1, 'col');
      return col;
    }
    if (col is String) {
      final idx = _nameToIndex[col];
      if (idx == null) {
        throw ArgumentError('Unknown column: "$col". Known: $columnNames');
      }
      return idx;
    }
    throw ArgumentError('col must be int or String, got ${col.runtimeType}');
  }
}

/// A single row of a [SqliteResultSet]. Decodes lazily by per-cell type.
class SqliteResultRow {
  final SqliteResultSet _set;
  final int _index;

  SqliteResultRow._(this._set, this._index);

  int get index => _index;

  /// Decoded value for column [key] (by `int` index or `String` name).
  /// `null` when the cell is SQL NULL.
  Object? operator [](Object key) {
    final col = _set._resolve(key);
    final binding = _set._binding!;
    final result = _set._result!;
    final type = binding.cellType(result, _index, col);
    if (type == SqliteCellType.nullType) return null;
    final ptr = binding.rawValue(result, _index, col);
    if (ptr == ffi.nullptr) return null;
    final length = binding.rawLength(result, _index, col);
    final bytes = ptr.asTypedList(length);
    switch (type) {
      case SqliteCellType.integer:
        return ByteData.sublistView(bytes).getInt64(0, Endian.host);
      case SqliteCellType.float:
        return ByteData.sublistView(bytes).getFloat64(0, Endian.host);
      case SqliteCellType.text:
        return utf8.decode(bytes);
      case SqliteCellType.blob:
      default:
        return Uint8List.fromList(bytes); // copy: safe past release
    }
  }

  int? getInt(Object key) => this[key] as int?;
  double? getDouble(Object key) => this[key] as double?;
  String? getString(Object key) => this[key] as String?;
  Object? getBytes(Object key) => this[key];

  Map<String, Object?> toMap() =>
      {for (var c = 0; c < _set.colCount; c++) _set.columnNames[c]: this[c]};

  @override
  String toString() => toMap().toString();
}
