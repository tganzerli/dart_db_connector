/// Unit tests for the BSON encoder/decoder. No native library
/// needed — pure Dart round-trip + a known-bytes anchor.
library;

import 'dart:typed_data';

import 'package:dart_db_connector/src/decoder/bson_reader.dart';
import 'package:dart_db_connector/src/decoder/bson_value.dart';
import 'package:dart_db_connector/src/decoder/bson_writer.dart';
import 'package:test/test.dart';

void main() {
  test('known-bytes anchor: {"hello":"world"} matches the BSON spec example',
      () {
    // The canonical example from bsonspec.org.
    final bytes = BsonWriter.encodeDocument({'hello': 'world'});
    final expected = Uint8List.fromList([
      0x16, 0x00, 0x00, 0x00, // int32 total length = 22
      0x02, // type: string
      0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00, // "hello\0"
      0x06, 0x00, 0x00, 0x00, // string length = 6
      0x77, 0x6f, 0x72, 0x6c, 0x64, 0x00, // "world\0"
      0x00, // document terminator
    ]);
    expect(bytes, equals(expected));
  });

  test('round-trip: scalars of every supported type', () {
    final oid =
        ObjectId(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]));
    final when = DateTime.utc(2026, 7, 27, 12, 0, 0);
    final doc = <String, Object?>{
      'str': 'héllo',
      'i32': 42,
      'i64': 9000000000, // > int32 range
      'dbl': 3.14159,
      'yes': true,
      'no': false,
      'nothing': null,
      'oid': oid,
      'ts': when,
      'bin': Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
    };

    final bytes = BsonWriter.encodeDocument(doc);
    final back = BsonReader(bytes).readDocument();

    expect(back.getString('str'), 'héllo');
    expect(back.getInt('i32'), 42);
    expect(back.getInt('i64'), 9000000000);
    expect(back.getDouble('dbl'), closeTo(3.14159, 1e-9));
    expect(back.getBool('yes'), isTrue);
    expect(back.getBool('no'), isFalse);
    expect(back.containsKey('nothing'), isTrue);
    expect(back['nothing'], isNull);
    expect(back.getObjectId('oid'), oid);
    expect(back.getDateTime('ts'), when);
    expect(back['bin'], equals(Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])));
  });

  test('round-trip: nested document and array', () {
    final doc = <String, Object?>{
      '_id': 7,
      'profile': {'name': 'Ada', 'age': 36},
      'tags': ['a', 'b', 'c'],
      'scores': [10, 20, 30],
    };
    final back = BsonReader(BsonWriter.encodeDocument(doc)).readDocument();

    expect(back.getInt('_id'), 7);
    final profile = back.getDocument('profile')!;
    expect(profile.getString('name'), 'Ada');
    expect(profile.getInt('age'), 36);
    expect(back.getList('tags'), equals(['a', 'b', 'c']));
    expect(back.getList('scores'), equals([10, 20, 30]));
  });

  test('YCSB-shaped doc: _id + 10 string fields survives round-trip', () {
    final doc = <String, Object?>{'_id': 123};
    for (var f = 0; f < 10; f++) {
      doc['f$f'] = 'x' * 100;
    }
    final back = BsonReader(BsonWriter.encodeDocument(doc)).readDocument();
    expect(back.getInt('_id'), 123);
    for (var f = 0; f < 10; f++) {
      expect(back.getString('f$f'), 'x' * 100);
    }
  });
}
