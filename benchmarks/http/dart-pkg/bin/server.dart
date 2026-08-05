/// Phase 3 HTTP server — Dart (Shelf) + postgres 3.5.11 (pub.dev).
///
/// Pure-Dart wire protocol implementation. Counterpart of
/// `bench/http/dart-native/server.dart`, with the same six endpoints
/// and the same Shelf scaffolding. The differences are only in the
/// driver layer:
///
///   * Uses `Pool.withEndpoints` from `package:postgres` instead of
///     `PostgresConnectionPool` from `dart_db_connector`.
///   * Uses Extended-Protocol parameter binding (`$1`) — the
///     idiomatic API for this driver. dart_db_connector v1 doesn't
///     expose ergonomic prepared statements yet, so the native
///     server concatenates SQL. The asymmetry is intentional and
///     documented in the bench page: it measures the cost of the
///     missing v1 feature against the canonical alternative.
///
/// Listens on 0.0.0.0:8080. Pool size from POOL_SIZE env (default 64).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

late final Pool _pool;
final Random _rng = Random();

const int _worldRows = 10000;

Future<void> main(List<String> args) async {
  final poolSize = int.parse(Platform.environment['POOL_SIZE'] ?? '64');
  final host = Platform.environment['POSTGRES_HOST'] ?? 'postgres';
  final port =
      int.parse(Platform.environment['POSTGRES_PORT'] ?? '5432');
  final db = Platform.environment['POSTGRES_DB'] ?? 'teste';
  final user = Platform.environment['POSTGRES_USER'] ?? 'postgres';
  final password =
      Platform.environment['POSTGRES_PASSWORD'] ?? '123';

  _pool = Pool.withEndpoints(
    [
      Endpoint(
        host: host,
        port: port,
        database: db,
        username: user,
        password: password,
      ),
    ],
    settings: PoolSettings(
      maxConnectionCount: poolSize,
      sslMode: SslMode.disable,
    ),
  );
  print('[dart-pkg] pool ready (maxConnections=$poolSize)  '
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
  print('[dart-pkg] listening on http://${server.address.host}:${server.port}');
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
  final result = await _pool.execute('SELECT id, message FROM fortune');
  final fortunes = [
    for (final row in result)
      {
        'id': row[0]! as int,
        'message': row[1]! as String,
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
      ..write(_escapeHtml((f['message']! as String)))
      ..write('</td></tr>');
  }
  html.write('</table></body></html>');
  return Response.ok(html.toString(),
      headers: {'content-type': 'text/html; charset=utf-8'});
}

Future<Map<String, int>> _selectWorld(int id) async {
  final result = await _pool.execute(
    r'SELECT id, randomnumber FROM world WHERE id = $1',
    parameters: [id],
  );
  final row = result.first;
  return {
    'id': row[0]! as int,
    'randomNumber': row[1]! as int,
  };
}

Future<Map<String, int>> _updateWorld(int id, int newRand) async {
  await _pool.runTx((s) async {
    await s.execute(
      r'SELECT id, randomnumber FROM world WHERE id = $1',
      parameters: [id],
    );
    await s.execute(
      r'UPDATE world SET randomnumber = $1 WHERE id = $2',
      parameters: [newRand, id],
    );
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
