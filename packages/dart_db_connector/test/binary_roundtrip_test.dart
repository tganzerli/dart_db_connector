/// End-to-end binary wire-format roundtrip — ABI MINOR 1.
///
/// For each canonical [Param] subclass whose binary decoder is
/// implemented, INSERT a value via `params:` then `SELECT` it back
/// with `binaryResult: true` and assert the decoded value equals the
/// original. Validates the **encoder ↔ Postgres ↔ decoder** loop
/// against a real server (Postgres 16 alpine in `docker/postgres/`).
///
/// `numeric` is excluded — binary `numeric` is not decoded yet (see
/// `decodeByOidBinary` docstring); covered in unit tests as raw bytes.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:dart_db_connector/src/bindings/postgres_binding.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

bool _canLoadNative() {
  try {
    loadNativeDb();
    return true;
  } on StateError {
    return false;
  }
}

PostgresBinding _binding() {
  final b = PostgresBinding(loadNativeDb());
  b.initDartApi(ffi.NativeApi.initializeApiDLData);
  return b;
}

Future<PostgresConnectionPool> _freshPool(PostgresBinding b) async {
  final pool = PostgresConnectionPool.withBinding(
    b,
    const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 2),
  );
  await pool.start();
  return pool;
}

/// Inserts [value] into a single-column table of [pgType], reads it back
/// with `binaryResult: true`, and returns the decoded value.
Future<Object?> _roundtrip(
  PostgresConnectionPool pool,
  String pgType,
  Param value,
) async {
  final tbl = 'rt_${pgType.replaceAll(RegExp(r'[^a-z0-9]'), '_')}';

  final setup = PostgresUnitOfWork(pool);
  await setup.begin();
  await setup.executor.execute('DROP TABLE IF EXISTS $tbl');
  await setup.executor.execute('CREATE TABLE $tbl (v $pgType)');
  await setup.executor.execute(
    'INSERT INTO $tbl (v) VALUES (\$1)',
    params: [value],
  );
  await setup.commit();

  final read = PostgresUnitOfWork(pool);
  await read.begin();
  final rs = await read.executor.execute(
    'SELECT v FROM $tbl',
    binaryResult: true,
  );
  try {
    expect(rs.rowCount, 1, reason: 'inserted row not retrievable');
    return rs.row(0)['v'];
  } finally {
    rs.release();
    await read.commit();
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  late PostgresBinding binding;
  late PostgresConnectionPool pool;

  setUpAll(() async {
    binding = _binding();
    try {
      pool = await _freshPool(binding);
    } catch (e) {
      pool = PostgresConnectionPool.withBinding(
        binding,
        const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 2),
      );
      markTestSkipped('Postgres not reachable: $e');
    }
  });

  tearDownAll(() async {
    await pool.close().catchError((_) {});
  });

  group('binary roundtrip', () {
    test('bool', () async {
      expect(await _roundtrip(pool, 'bool', Param.bool(true)), true);
      expect(await _roundtrip(pool, 'bool', Param.bool(false)), false);
    });

    test('int2', () async {
      expect(await _roundtrip(pool, 'int2', Param.int2(-7)), -7);
      expect(await _roundtrip(pool, 'int2', Param.int2(0x7FFF)), 0x7FFF);
    });

    test('int4', () async {
      expect(await _roundtrip(pool, 'int4', Param.int4(123456)), 123456);
      expect(
          await _roundtrip(pool, 'int4', Param.int4(-0x80000000)), -0x80000000);
    });

    test('int8', () async {
      expect(await _roundtrip(pool, 'int8', Param.int8(1 << 40)), 1 << 40);
    });

    test('float4', () async {
      final v = await _roundtrip(pool, 'float4', Param.float4(3.5)) as double;
      expect(v, closeTo(3.5, 1e-6));
    });

    test('float8', () async {
      final v =
          await _roundtrip(pool, 'float8', Param.float8(2.71828)) as double;
      expect(v, 2.71828);
    });

    test('text', () async {
      // Multi-byte UTF-8 to exercise the codec on both ends.
      expect(await _roundtrip(pool, 'text', Param.text('café')), 'café');
    });

    test('varchar', () async {
      expect(await _roundtrip(pool, 'varchar(16)', Param.varchar('hello')),
          'hello');
    });

    test('bpchar (blank-padded char)', () async {
      // bpchar(8) pads the value with spaces to width 8.
      expect(
          await _roundtrip(pool, 'char(8)', Param.bpchar('abc')), 'abc     ');
    });

    test('json', () async {
      final v = await _roundtrip(pool, 'json', Param.json('{"k":1,"a":[2,3]}'))
          as Map;
      expect(v['k'], 1);
      expect(v['a'], [2, 3]);
    });

    test('jsonb', () async {
      final v =
          await _roundtrip(pool, 'jsonb', Param.jsonb('{"x":true}')) as Map;
      expect(v['x'], true);
    });

    test('bytea', () async {
      final raw = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42]);
      final v = await _roundtrip(pool, 'bytea', Param.bytea(raw)) as Uint8List;
      expect(v, raw);
    });

    test('timestamp', () async {
      final ts = DateTime.utc(2026, 5, 23, 14, 30, 45, 123, 456);
      final v =
          await _roundtrip(pool, 'timestamp', Param.timestamp(ts)) as DateTime;
      expect(v.microsecondsSinceEpoch, ts.microsecondsSinceEpoch);
    });

    test('timestamptz', () async {
      final ts = DateTime.utc(2026, 5, 23, 14, 30, 45, 123, 456);
      final v = await _roundtrip(pool, 'timestamptz', Param.timestamptz(ts))
          as DateTime;
      expect(v.microsecondsSinceEpoch, ts.microsecondsSinceEpoch);
    });
  });

  group('SQL NULL roundtrip via Param.nullValue', () {
    test('nullValue(text) inserts SQL NULL and reads back as null', () async {
      final v =
          await _roundtrip(pool, 'text', Param.nullValue(PostgresOid.text));
      expect(v, isNull);
    });

    test('nullValue(int4) inserts SQL NULL and reads back as null', () async {
      final v =
          await _roundtrip(pool, 'int4', Param.nullValue(PostgresOid.int4));
      expect(v, isNull);
    });
  });
}
