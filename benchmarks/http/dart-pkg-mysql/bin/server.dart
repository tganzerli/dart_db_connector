/// HTTP server — Dart (Shelf) + `mysql_client` 0.0.27 (pub.dev).
///
/// Pure-Dart MySQL wire protocol implementation (the "baseline" driver).
/// Counterpart of `bench/http/dart-native-mysql/bin/server.dart`, with the
/// same six endpoints and the same Shelf scaffolding. The only difference is
/// the driver layer: this server uses `MySQLConnectionPool` from
/// `package:mysql_client` instead of `MysqlConnectionPool` from
/// `dart_db_connector`.
///
/// SQL uses inline (interpolated) values with no bound params, which drives
/// `mysql_client` over the MySQL text protocol (COM_QUERY) — the same protocol
/// tier as the developed driver's simple-query path. This keeps the comparison
/// apples-to-apples on the wire and isolates driver architecture. Matches how
/// `benchmarks/scripts/tpcc/transactions_mysql_pkg.dart` builds SQL.
///
/// Listens on 0.0.0.0:8080. Pool size from POOL_SIZE env (default 8).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mysql_client/mysql_client.dart';
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

late final MySQLConnectionPool _pool;
final Random _rng = Random();
const int _worldRows = 10000;

Future<void> main(List<String> args) async {
  final poolSize = int.parse(Platform.environment['POOL_SIZE'] ?? '8');
  final host = Platform.environment['MYSQL_HOST'] ?? 'mysql';
  final port = int.parse(Platform.environment['MYSQL_PORT'] ?? '3306');
  final db = Platform.environment['MYSQL_DB'] ?? 'teste';
  final user = Platform.environment['MYSQL_USER'] ?? 'bench';
  final password = Platform.environment['MYSQL_PASSWORD'] ?? '123';

  _pool = MySQLConnectionPool(
    host: host,
    port: port,
    userName: user,
    password: password,
    databaseName: db,
    maxConnections: poolSize,
    secure: false,
  );
  print('[dart-pkg-mysql] pool ready (maxConnections=$poolSize) '
      'host=$host port=$port db=$db');

  final router = Router()
    ..get('/plaintext', _plaintext)
    ..get('/json', _json)
    ..get('/db', _db)
    ..get('/queries', _queries)
    ..get('/updates', _updates)
    ..get('/fortunes', _fortunes);

  final server = await shelf_io.serve(
    router.call,
    InternetAddress.anyIPv4,
    8080,
    shared: false,
  );
  server.autoCompress = false;
  print('[dart-pkg-mysql] listening on '
      'http://${server.address.host}:${server.port}');
}

Response _plaintext(Request _) => Response.ok(
      'Hello, World!',
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );

Response _json(Request _) => Response.ok(
      jsonEncode({'message': 'Hello, World!'}),
      headers: {'content-type': 'application/json'},
    );

Future<Response> _db(Request _) async {
  final id = _rng.nextInt(_worldRows) + 1;
  final row = await _selectWorld(id);
  return Response.ok(jsonEncode(row),
      headers: {'content-type': 'application/json'});
}

Future<Response> _queries(Request req) async {
  final count = _clampCount(req.url.queryParameters['count']);
  final ids = List.generate(count, (_) => _rng.nextInt(_worldRows) + 1);
  final rows = await Future.wait(ids.map(_selectWorld));
  return Response.ok(jsonEncode(rows),
      headers: {'content-type': 'application/json'});
}

Future<Response> _updates(Request req) async {
  final count = _clampCount(req.url.queryParameters['count']);
  final updates = await Future.wait(List.generate(count, (_) async {
    final id = _rng.nextInt(_worldRows) + 1;
    final newRand = _rng.nextInt(_worldRows) + 1;
    return _updateWorld(id, newRand);
  }));
  return Response.ok(jsonEncode(updates),
      headers: {'content-type': 'application/json'});
}

Future<Response> _fortunes(Request _) async {
  final rs = await _pool.execute('SELECT id, message FROM fortune');
  final fortunes = <Map<String, Object>>[
    for (final row in rs.rows)
      {
        'id': int.parse(row.colByName('id')!),
        'message': row.colByName('message')!,
      }
  ];
  fortunes.add({
    'id': 0,
    'message': 'Additional fortune added at request time.',
  });
  fortunes.sort((a, b) =>
      (a['message']! as String).compareTo(b['message']! as String));

  final html = StringBuffer(
      '<!DOCTYPE html><html><head><title>Fortunes</title></head><body>'
      '<table><tr><th>id</th><th>message</th></tr>');
  for (final f in fortunes) {
    html
      ..write('<tr><td>')
      ..write(f['id'])
      ..write('</td><td>')
      ..write(_escapeHtml(f['message']! as String))
      ..write('</td></tr>');
  }
  html.write('</table></body></html>');
  return Response.ok(html.toString(),
      headers: {'content-type': 'text/html; charset=utf-8'});
}

Future<Map<String, int>> _selectWorld(int id) async {
  final rs = await _pool.execute(
      'SELECT id, randomnumber FROM world WHERE id = $id');
  final row = rs.rows.first;
  return {
    'id': int.parse(row.colByName('id')!),
    'randomNumber': int.parse(row.colByName('randomnumber')!),
  };
}

Future<Map<String, int>> _updateWorld(int id, int newRand) async {
  await _pool.transactional((conn) async {
    await conn.execute('SELECT id, randomnumber FROM world WHERE id = $id');
    await conn.execute('UPDATE world SET randomnumber = $newRand WHERE id = $id');
  });
  return {'id': id, 'randomNumber': newRand};
}

int _clampCount(String? raw) {
  final v = int.tryParse(raw ?? '1') ?? 1;
  if (v < 1) return 1;
  if (v > 500) return 500;
  return v;
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
