/// Unit tests for [decodeByOidBinary] + round-trip with [Param.encode].
///
/// Does NOT require a running Postgres — exercises the binary decoder
/// against synthetic wire-format bytes (the same shape libpq emits when
/// `PQsendQueryParams(..., resultFormat=1)` is used). End-to-end against
/// a live server is covered by L.6 integration tests.
library;

import 'dart:typed_data';

import 'package:dart_db_connector/src/decoder/_decoder.dart';
import 'package:dart_db_connector/src/decoder/postgres_oids.dart';
import 'package:dart_db_connector/src/postgres/param.dart';
import 'package:test/test.dart';

Uint8List _enc(Param p) {
  final b = p.encode();
  expect(b, isNotNull);
  return b!;
}

void main() {
  group('decodeByOidBinary — primitives', () {
    test('bool 0x01 → true / 0x00 → false', () {
      expect(decodeByOidBinary(Uint8List.fromList([0x01]), PostgresOid.boolean),
          true);
      expect(decodeByOidBinary(Uint8List.fromList([0x00]), PostgresOid.boolean),
          false);
    });

    test('int2 / int4 / int8 BE round-trip from encoder', () {
      expect(decodeByOidBinary(_enc(Param.int2(-1)), PostgresOid.int2), -1);
      expect(decodeByOidBinary(_enc(Param.int2(0x7FFF)), PostgresOid.int2),
          0x7FFF);
      expect(decodeByOidBinary(_enc(Param.int4(42)), PostgresOid.int4), 42);
      expect(decodeByOidBinary(_enc(Param.int4(-0x80000000)), PostgresOid.int4),
          -0x80000000);
      expect(decodeByOidBinary(_enc(Param.int8(1 << 33)), PostgresOid.int8),
          1 << 33);
    });

    test('float4 / float8 IEEE 754 BE round-trip', () {
      final f4 = decodeByOidBinary(_enc(Param.float4(1.5)), PostgresOid.float4)
          as double;
      expect(f4, closeTo(1.5, 1e-6));
      final f8 =
          decodeByOidBinary(_enc(Param.float8(2.71828)), PostgresOid.float8)
              as double;
      expect(f8, 2.71828);
    });
  });

  group('decodeByOidBinary — text family', () {
    test('text / varchar / bpchar decode as UTF-8', () {
      for (final oid in [
        PostgresOid.text,
        PostgresOid.varchar,
        PostgresOid.bpchar
      ]) {
        // 'café' in UTF-8
        final bytes = Uint8List.fromList([0x63, 0x61, 0x66, 0xC3, 0xA9]);
        expect(decodeByOidBinary(bytes, oid), 'café');
      }
    });

    test('json decodes via jsonDecode', () {
      final bytes = Uint8List.fromList('{"k":1}'.codeUnits);
      final v = decodeByOidBinary(bytes, PostgresOid.json) as Map;
      expect(v['k'], 1);
    });

    test('jsonb skips 1-byte version prefix', () {
      // Encoder: 0x01 + UTF-8 JSON
      final encoded = _enc(Param.jsonb('{"x":42}'));
      final v = decodeByOidBinary(encoded, PostgresOid.jsonb) as Map;
      expect(v['x'], 42);
    });
  });

  group('decodeByOidBinary — bytea', () {
    test('returns raw bytes unchanged', () {
      final raw = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      expect(decodeByOidBinary(raw, PostgresOid.bytea), raw);
    });
  });

  group('decodeByOidBinary — timestamp / timestamptz', () {
    test('pg epoch (2000-01-01) round-trips to DateTime UTC', () {
      final encoded = _enc(Param.timestamp(DateTime.utc(2000, 1, 1)));
      final v = decodeByOidBinary(encoded, PostgresOid.timestamp) as DateTime;
      expect(v.isUtc, isTrue);
      expect(v, DateTime.utc(2000, 1, 1));
    });

    test('1 second past epoch (1_000_000 µs) decodes correctly', () {
      final encoded =
          _enc(Param.timestamptz(DateTime.utc(2000, 1, 1, 0, 0, 1)));
      final v = decodeByOidBinary(encoded, PostgresOid.timestamptz) as DateTime;
      expect(v, DateTime.utc(2000, 1, 1, 0, 0, 1));
    });

    test('pre-epoch (negative µs) decodes correctly', () {
      final encoded =
          _enc(Param.timestamptz(DateTime.utc(1999, 12, 31, 23, 59, 59)));
      final v = decodeByOidBinary(encoded, PostgresOid.timestamptz) as DateTime;
      expect(v, DateTime.utc(1999, 12, 31, 23, 59, 59));
    });

    test('round-trip preserves modern instant', () {
      final original = DateTime.utc(2026, 5, 23, 14, 30, 45, 123, 456);
      final encoded = _enc(Param.timestamptz(original));
      final decoded =
          decodeByOidBinary(encoded, PostgresOid.timestamptz) as DateTime;
      expect(decoded.microsecondsSinceEpoch, original.microsecondsSinceEpoch);
    });
  });

  group('decodeByOidBinary — postponed / unknown', () {
    test('numeric returns raw bytes (binary decode postponed)', () {
      // Synthetic binary blob; decoder is documented to return raw.
      final raw =
          Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
      expect(decodeByOidBinary(raw, PostgresOid.numeric), raw);
    });

    test('unknown OID returns raw bytes (zero-copy)', () {
      final raw = Uint8List.fromList([1, 2, 3]);
      expect(decodeByOidBinary(raw, 999999), raw);
    });
  });

  group('encode → decodeByOidBinary roundtrip (smoke for 12 types)', () {
    test('all values survive encode + decode unchanged', () {
      final cases = <(Param, int, Object)>[
        (Param.bool(true), PostgresOid.boolean, true),
        (Param.int2(-7), PostgresOid.int2, -7),
        (Param.int4(123456), PostgresOid.int4, 123456),
        (Param.int8(1 << 40), PostgresOid.int8, 1 << 40),
        (Param.float4(3.5), PostgresOid.float4, 3.5),
        (Param.float8(1.41421356), PostgresOid.float8, 1.41421356),
        (Param.text('hello'), PostgresOid.text, 'hello'),
        (Param.varchar('v'), PostgresOid.varchar, 'v'),
        (Param.bpchar('c'), PostgresOid.bpchar, 'c'),
        (
          Param.bytea(Uint8List.fromList([1, 2, 3])),
          PostgresOid.bytea,
          Uint8List.fromList([1, 2, 3])
        ),
        (
          Param.timestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
          PostgresOid.timestamp,
          DateTime.utc(2026, 1, 2, 3, 4, 5)
        ),
        (
          Param.timestamptz(DateTime.utc(2026, 1, 2, 3, 4, 5)),
          PostgresOid.timestamptz,
          DateTime.utc(2026, 1, 2, 3, 4, 5)
        ),
      ];
      for (final (p, oid, expected) in cases) {
        final encoded = _enc(p);
        final decoded = decodeByOidBinary(encoded, oid);
        expect(decoded, expected,
            reason: 'roundtrip failed for ${p.runtimeType}');
      }
    });

    test('json / jsonb survive encode + decode', () {
      final j = decodeByOidBinary(
          _enc(Param.json('{"a":1,"b":[2,3]}')), PostgresOid.json) as Map;
      expect(j['a'], 1);
      expect(j['b'], [2, 3]);
      final jb =
          decodeByOidBinary(_enc(Param.jsonb('{"x":true}')), PostgresOid.jsonb)
              as Map;
      expect(jb['x'], true);
    });
  });
}
