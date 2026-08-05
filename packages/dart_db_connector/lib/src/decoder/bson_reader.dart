/// Zero-copy BSON decoder for the MongoDB driver.
///
/// Parses a BSON document straight out of a [Uint8List] view over the
/// native result buffer (`asTypedList` over the pointer returned by
/// `native_mongo_result_data`) — no intermediate copy of the whole buffer,
/// and one pass instead of one FFI call per field. Scalar values are read
/// directly; strings / ObjectIds / binary are copied into Dart objects as
/// they are decoded, so the resulting [BsonDocument] is independent of the
/// native buffer (safe after `clearResult`).
///
/// Mirrors the zero-copy philosophy of `mysql_result_row.dart` (`asTypedList`
/// over a native pointer), adapted to BSON's self-contained, length-prefixed
/// document layout — which fits the model even better than the MySQL
/// one-row cache.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'bson_value.dart';

/// BSON element type bytes (subset supported by the v1 driver).
class _BsonType {
  static const double_ = 0x01;
  static const string = 0x02;
  static const document = 0x03;
  static const array = 0x04;
  static const binary = 0x05;
  static const objectId = 0x07;
  static const bool_ = 0x08;
  static const dateTime = 0x09;
  static const null_ = 0x0A;
  static const int32 = 0x10;
  static const timestamp = 0x11;
  static const int64 = 0x12;
}

/// Decodes BSON documents from a byte buffer. One [BsonReader] parses one
/// buffer; create a new one per result document.
class BsonReader {
  final Uint8List _bytes;
  final ByteData _bd;
  int _pos = 0;

  BsonReader(this._bytes) : _bd = ByteData.sublistView(_bytes);

  /// Parses the document starting at the current position.
  BsonDocument readDocument() => BsonDocument(_readDocumentMap());

  Map<String, Object?> _readDocumentMap() {
    final start = _pos;
    final len = _readInt32();
    final end = start + len;
    final map = <String, Object?>{};
    while (_pos < end - 1) {
      final type = _bytes[_pos++];
      final key = _readCString();
      map[key] = _readValue(type);
    }
    _pos = end; // step past the trailing NUL
    return map;
  }

  List<Object?> _readArray() {
    final start = _pos;
    final len = _readInt32();
    final end = start + len;
    final list = <Object?>[];
    while (_pos < end - 1) {
      final type = _bytes[_pos++];
      _readCString(); // array index key ("0","1",…) — positional, ignored
      list.add(_readValue(type));
    }
    _pos = end;
    return list;
  }

  Object? _readValue(int type) {
    switch (type) {
      case _BsonType.double_:
        final v = _bd.getFloat64(_pos, Endian.little);
        _pos += 8;
        return v;
      case _BsonType.string:
        return _readString();
      case _BsonType.document:
        return BsonDocument(_readDocumentMap());
      case _BsonType.array:
        return _readArray();
      case _BsonType.binary:
        return _readBinary();
      case _BsonType.objectId:
        final b =
            Uint8List.fromList(Uint8List.sublistView(_bytes, _pos, _pos + 12));
        _pos += 12;
        return ObjectId(b);
      case _BsonType.bool_:
        return _bytes[_pos++] != 0;
      case _BsonType.dateTime:
        final ms = _bd.getInt64(_pos, Endian.little);
        _pos += 8;
        return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      case _BsonType.null_:
        return null;
      case _BsonType.int32:
        return _readInt32();
      case _BsonType.timestamp:
        final v = _bd.getInt64(_pos, Endian.little); // (inc<<0 | time<<32)
        _pos += 8;
        return v;
      case _BsonType.int64:
        final v = _bd.getInt64(_pos, Endian.little);
        _pos += 8;
        return v;
      default:
        throw FormatException(
            'Unsupported BSON type 0x${type.toRadixString(16)} at $_pos');
    }
  }

  int _readInt32() {
    final v = _bd.getInt32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  String _readString() {
    final len = _readInt32(); // includes trailing NUL
    final s = utf8.decode(Uint8List.sublistView(_bytes, _pos, _pos + len - 1));
    _pos += len;
    return s;
  }

  String _readCString() {
    final start = _pos;
    while (_bytes[_pos] != 0) {
      _pos++;
    }
    final s = utf8.decode(Uint8List.sublistView(_bytes, start, _pos));
    _pos++; // step past the NUL
    return s;
  }

  Uint8List _readBinary() {
    final len = _readInt32();
    _pos++; // subtype byte (ignored in v1)
    final b =
        Uint8List.fromList(Uint8List.sublistView(_bytes, _pos, _pos + len));
    _pos += len;
    return b;
  }
}
