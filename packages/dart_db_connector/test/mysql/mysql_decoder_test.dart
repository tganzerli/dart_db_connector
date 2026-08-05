/// Unit + integration tests for the MySQL decoder.
library;

import 'dart:convert' show utf8;
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/decoder/mysql_decoder.dart';
import 'package:dart_db_connector/src/decoder/mysql_field_types.dart';
import 'package:dart_db_connector/src/decoder/mysql_result_row.dart';
import 'package:dart_db_connector/src/decoder/mysql_type.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('decodeByFieldType (unit — no DB)', () {
    test('integers', () {
      expect(decodeByFieldType(_b('42'), MysqlFieldType.long), 42);
      expect(decodeByFieldType(_b('-7'), MysqlFieldType.tiny), -7);
      expect(decodeByFieldType(_b('9000000000'), MysqlFieldType.longLong),
          9000000000);
    });

    test('floating point and decimal', () {
      expect(decodeByFieldType(_b('3.14'), MysqlFieldType.double_), 3.14);
      expect(decodeByFieldType(_b('1.50'), MysqlFieldType.newDecimal), 1.5);
    });

    test('strings', () {
      expect(decodeByFieldType(_b('hello'), MysqlFieldType.varString), 'hello');
      expect(decodeByFieldType(_b('açaí'), MysqlFieldType.string), 'açaí');
    });

    test('json', () {
      expect(decodeByFieldType(_b('{"a":1}'), MysqlFieldType.json), {'a': 1});
    });

    test('datetime parses to DateTime', () {
      final v =
          decodeByFieldType(_b('2026-07-24 13:45:00'), MysqlFieldType.datetime);
      expect(v, isA<DateTime>());
      expect((v as DateTime).year, 2026);
      expect(v.minute, 45);
    });

    test('blob family returns raw bytes', () {
      final v = decodeByFieldType(_b('xy'), MysqlFieldType.blob);
      expect(v, isA<Uint8List>());
      expect(v, [0x78, 0x79]);
    });

    test('type tag mapping', () {
      expect(mysqlTypeFromCode(MysqlFieldType.long), MysqlType.integer);
      expect(mysqlTypeFromCode(MysqlFieldType.varString), MysqlType.text);
      expect(mysqlTypeFromCode(999), MysqlType.unknown);
    });
  });

  // ── Integration: decode a real multi-type result set ──
  MysqlBinding? binding;
  try {
    binding = MysqlBinding(loadNativeMysql());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }

  if (binding == null) {
    test('skipped integration (native library not built)', () {
      markTestSkipped('libnative_mysql not available');
    });
    return;
  }

  final b = binding;

  test('MysqlResultSet decodes a real multi-type SELECT', () async {
    final host = '127.0.0.1'.toNativeUtf8();
    final user = 'root'.toNativeUtf8();
    final pass = '123'.toNativeUtf8();
    final db = 'teste'.toNativeUtf8();
    final pool = b.poolCreate(host, user, pass, db, 3306, 1, 1, 5000);
    malloc.free(host);
    malloc.free(user);
    malloc.free(pass);
    malloc.free(db);
    if (pool == ffi.nullptr) {
      markTestSkipped('MySQL not reachable');
      return;
    }

    try {
      final conn = b.poolAcquire(pool, 5000);
      final rp = ReceivePort();
      final sql = "SELECT CAST(42 AS SIGNED) AS n, 3.5 AS d, 'hi' AS s, "
              "DATE('2026-07-24') AS day, NULL AS nothing"
          .toNativeUtf8();
      b.poolSubmitQuery(conn, sql, rp.sendPort.nativePort, 0);
      malloc.free(sql);
      expect(await rp.first as int, 1);
      rp.close();

      final res = b.pollResult(conn);
      final rs = MysqlResultSet.fromResult(b, res);
      expect(rs.rowCount, 1);
      expect(rs.colCount, 5);
      expect(rs.columnNames, ['n', 'd', 's', 'day', 'nothing']);

      final row = rs.row(0);
      expect(row.getInt('n'), 42);
      expect(row.getDouble('d'), 3.5);
      expect(row.getString('s'), 'hi');
      expect(row.getDateTime('day'), isA<DateTime>());
      expect(row['nothing'], isNull, reason: 'SQL NULL decodes to null');

      rs.release(); // frees the result (also detaches finalizer)
      b.poolRelease(pool, conn);
    } finally {
      b.poolDestroy(pool);
    }
  });
}
