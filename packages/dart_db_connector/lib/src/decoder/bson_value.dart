/// BSON value model for the MongoDB driver.
///
/// A decoded MongoDB document is surfaced as a [BsonDocument] — a thin
/// typed wrapper over `Map<String, Object?>` whose values are plain Dart
/// types (String, int, double, bool, DateTime, [ObjectId], [BsonDocument]
/// for sub-documents, List for arrays, Uint8List for binary, null).
///
/// This is the MongoDB analogue of `MysqlResultRow` — the decode target of
/// the driver — but shaped for documents rather than rows/columns. It has
/// no relational counterpart, which is itself a cross-driver data point: the
/// row-oriented decode interface did not generalize to a document store.
library;

import 'dart:typed_data';

/// A 12-byte MongoDB ObjectId.
class ObjectId {
  /// The raw 12 bytes.
  final Uint8List bytes;

  const ObjectId(this.bytes);

  /// The 24-character lowercase hex representation.
  String toHexString() =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() => 'ObjectId(${toHexString()})';

  @override
  bool operator ==(Object other) {
    if (other is! ObjectId || other.bytes.length != bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);
}

/// A decoded BSON document with typed accessors. Values are copied out of
/// the native buffer during decoding, so a [BsonDocument] outlives the
/// underlying native result (safe to keep after `clearResult`).
class BsonDocument {
  final Map<String, Object?> _map;

  const BsonDocument(this._map);

  /// Raw value for [key] (null if absent or a BSON null).
  Object? operator [](String key) => _map[key];

  bool containsKey(String key) => _map.containsKey(key);

  Iterable<String> get keys => _map.keys;

  /// The backing map. Mutating it is the caller's responsibility.
  Map<String, Object?> toMap() => _map;

  String? getString(String key) => _map[key] as String?;

  /// Integer value; accepts a BSON double and truncates it, for convenience.
  int? getInt(String key) {
    final v = _map[key];
    if (v is int) return v;
    if (v is double) return v.toInt();
    return null;
  }

  /// Double value; accepts a BSON int and widens it.
  double? getDouble(String key) {
    final v = _map[key];
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return null;
  }

  bool? getBool(String key) => _map[key] as bool?;

  ObjectId? getObjectId(String key) => _map[key] as ObjectId?;

  DateTime? getDateTime(String key) => _map[key] as DateTime?;

  List<Object?>? getList(String key) => _map[key] as List<Object?>?;

  BsonDocument? getDocument(String key) => _map[key] as BsonDocument?;

  @override
  String toString() => 'BsonDocument($_map)';
}
