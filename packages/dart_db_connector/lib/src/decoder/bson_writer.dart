/// BSON encoder for the MongoDB driver.
///
/// Encodes a `Map<String, Object?>` into a BSON document buffer, ready to
/// hand to the native submit primitives (`mongo_pool_submit_*`) as
/// `(Pointer<Uint8>, length)`. The inverse of `bson_reader.dart`.
///
/// Supported Dart value types → BSON:
///   String→utf8, int→int32/int64, double→double, bool→bool, null→null,
///   [ObjectId]→objectId, DateTime→UTC datetime, Map/[BsonDocument]→document,
///   List→array, Uint8List→binary (subtype 0).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'bson_value.dart';

/// Encodes BSON documents. Stateless; use [encodeDocument].
class BsonWriter {
  static const _int32Min = -2147483648;
  static const _int32Max = 2147483647;

  /// Encodes [doc] into a complete BSON document buffer.
  static Uint8List encodeDocument(Map<String, Object?> doc) {
    final body = BytesBuilder(copy: false);
    doc.forEach((key, value) => _writeElement(body, key, value));
    final bodyBytes = body.toBytes();
    final total = 4 + bodyBytes.length + 1; // length prefix + body + NUL
    final out = Uint8List(total);
    ByteData.sublistView(out).setInt32(0, total, Endian.little);
    out.setRange(4, 4 + bodyBytes.length, bodyBytes);
    out[total - 1] = 0;
    return out;
  }

  static void _writeElement(BytesBuilder b, String key, Object? value) {
    if (value == null) {
      _writeTypeKey(b, 0x0A, key);
      return;
    }
    if (value is String) {
      _writeTypeKey(b, 0x02, key);
      final bytes = utf8.encode(value);
      _writeInt32(b, bytes.length + 1);
      b.add(bytes);
      b.addByte(0);
    } else if (value is bool) {
      _writeTypeKey(b, 0x08, key);
      b.addByte(value ? 1 : 0);
    } else if (value is int) {
      if (value >= _int32Min && value <= _int32Max) {
        _writeTypeKey(b, 0x10, key);
        _writeInt32(b, value);
      } else {
        _writeTypeKey(b, 0x12, key);
        _writeInt64(b, value);
      }
    } else if (value is double) {
      _writeTypeKey(b, 0x01, key);
      final bd = ByteData(8)..setFloat64(0, value, Endian.little);
      b.add(bd.buffer.asUint8List());
    } else if (value is ObjectId) {
      _writeTypeKey(b, 0x07, key);
      b.add(value.bytes);
    } else if (value is DateTime) {
      _writeTypeKey(b, 0x09, key);
      _writeInt64(b, value.toUtc().millisecondsSinceEpoch);
    } else if (value is BsonDocument) {
      _writeTypeKey(b, 0x03, key);
      b.add(encodeDocument(value.toMap()));
    } else if (value is Map<String, Object?>) {
      _writeTypeKey(b, 0x03, key);
      b.add(encodeDocument(value));
    } else if (value is List) {
      _writeTypeKey(b, 0x04, key);
      final asMap = <String, Object?>{};
      for (var i = 0; i < value.length; i++) {
        asMap['$i'] = value[i];
      }
      b.add(encodeDocument(asMap));
    } else if (value is Uint8List) {
      _writeTypeKey(b, 0x05, key);
      _writeInt32(b, value.length);
      b.addByte(0); // subtype: generic
      b.add(value);
    } else {
      throw ArgumentError(
          'Unsupported BSON value type for key "$key": ${value.runtimeType}');
    }
  }

  static void _writeTypeKey(BytesBuilder b, int type, String key) {
    b.addByte(type);
    b.add(utf8.encode(key));
    b.addByte(0); // cstring NUL
  }

  static void _writeInt32(BytesBuilder b, int v) {
    final bd = ByteData(4)..setInt32(0, v, Endian.little);
    b.add(bd.buffer.asUint8List());
  }

  static void _writeInt64(BytesBuilder b, int v) {
    final bd = ByteData(8)..setInt64(0, v, Endian.little);
    b.add(bd.buffer.asUint8List());
  }
}
