/// HTTP MySQL/MongoDB benchmark HTTP server — Dart (Shelf) + dart_db_connector MySQL (FFI over
/// libmysqlclient). DB-backed TechEmpower-style endpoints against MySQL.
///
/// Endpoints medidos no HTTP MySQL/MongoDB benchmark: /db, /queries?count=N, /updates?count=N,
/// /fortunes. (/plaintext and /json exist for completeness but touch no database:
/// já cobertos pelas stacks PG.)
///
/// **Benchmarking principle:** each
/// servidor usa o *melhor mecanismo idiomático do seu driver*, mantendo a
/// test run (endpoints + wrk load) constant. This is not a comparison of
/// identical code: it reflects what a real project would write when adopting each
/// driver.
///
/// Melhor mecanismo por endpoint (driver desenvolvido):
///   * /db, /fortunes: `withMysqlConnection` (NON-transactional read,
///     1 round-trip; o fast-path adicionado na Etapa 2).
///   * /queries       — `withMysqlConnection` + `executeMultiRead`
///     (N reads in one round-trip, no transaction).
///   * /updates       — read-modify-write real: `withMysqlTransaction`
///     (BEGIN-piggyback) com `executeMultiRead` p/ os SELECTs + `executeBatch`
///     p/ os UPDATEs (fan-out batelado dentro da transação).
/// SQL uses the simple protocol (interpolated, no bound params); the values are
/// program-synthesized (ids/randoms internos), nunca entrada externa.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

late final MysqlConnectionPool _pool;
final Random _rng = Random();
const int _worldRows = 10000;

Future<void> main(List<String> args) async {
  final poolSize = int.parse(Platform.environment['POOL_SIZE'] ?? '64');
  final host = Platform.environment['MYSQL_HOST'] ?? 'mysql';
  final port = int.parse(Platform.environment['MYSQL_PORT'] ?? '3306');
  final db = Platform.environment['MYSQL_DB'] ?? 'teste';
  final user = Platform.environment['MYSQL_USER'] ?? 'bench';
  final password = Platform.environment['MYSQL_PASSWORD'] ?? '123';

  _pool = MysqlConnectionPool(
    MysqlPoolConfig(
      host: host,
      port: port,
      user: user,
      password: password,
      database: db,
      minSize: poolSize,
      maxSize: poolSize,
    ),
  );
  await _pool.start();
  print('[dart-native-mysql] pool ready (size=$poolSize) host=$host db=$db');

  final router = Router()
    ..get('/plaintext', _plaintext)
    ..get('/json', _json)
    ..get('/db', _db)
    ..get('/queries', _queries)
    ..get('/updates', _updates)
    ..get('/fortunes', _fortunes);

  final server =
      await shelf_io.serve(router.call, InternetAddress.anyIPv4, 8080, shared: false);
  server.autoCompress = false;
  print('[dart-native-mysql] listening on :${server.port}');
}

Response _plaintext(Request _) => Response.ok('Hello, World!',
    headers: {'content-type': 'text/plain; charset=utf-8'});

Response _json(Request _) => Response.ok(jsonEncode({'message': 'Hello, World!'}),
    headers: {'content-type': 'application/json'});

Future<Response> _db(Request _) async {
  final id = _rng.nextInt(_worldRows) + 1;
  final row = await withMysqlConnection<Map<String, int>>(_pool, (exec) async {
    final rs = await exec.execute(
        'SELECT id, randomnumber FROM world WHERE id = $id');
    try {
      final r = rs.row(0);
      return {'id': r.getInt('id')!, 'randomNumber': r.getInt('randomnumber')!};
    } finally {
      rs.release();
    }
  });
  return Response.ok(jsonEncode(row), headers: {'content-type': 'application/json'});
}

Future<Response> _queries(Request req) async {
  final count = _clampCount(req.url.queryParameters['count']);
  final ids = List.generate(count, (_) => _rng.nextInt(_worldRows) + 1);
  // Best mechanism: N reads in a single round-trip via executeMultiRead,
  // non-transactionally.
  final rows = await withMysqlConnection<List<Map<String, int>>>(_pool, (exec) async {
    final selects = [
      for (final id in ids)
        'SELECT id, randomnumber FROM world WHERE id = $id'
    ];
    final results = await exec.executeMultiRead(selects);
    try {
      return [
        for (final rs in results)
          {
            'id': rs.row(0).getInt('id')!,
            'randomNumber': rs.row(0).getInt('randomnumber')!,
          }
      ];
    } finally {
      for (final rs in results) {
        rs.release();
      }
    }
  });
  return Response.ok(jsonEncode(rows), headers: {'content-type': 'application/json'});
}

Future<Response> _updates(Request req) async {
  final count = _clampCount(req.url.queryParameters['count']);
  // Sort the target ids ascending so every concurrent transaction acquires
  // InnoDB row locks in the same order — turns potential deadlock cycles into
  // plain waits (standard TechEmpower /updates practice). Without this, 64
  // concurrent 20-row updates in random order deadlock (error 1213).
  final ids = (List.generate(count, (_) => _rng.nextInt(_worldRows) + 1)
        ..sort());
  final newRands = List.generate(count, (_) => _rng.nextInt(_worldRows) + 1);
  // Read-modify-write: batch the N reads and the N writes each into one
  // round-trip inside the transaction.
  final updates =
      await withMysqlTransaction<List<Map<String, int>>>(_pool, (exec) async {
    final selects = [
      for (final id in ids)
        'SELECT id, randomnumber FROM world WHERE id = $id'
    ];
    final read = await exec.executeMultiRead(selects);
    for (final rs in read) {
      rs.release(); // TechEmpower reads then overwrites with a new random
    }
    final writes = [
      for (var i = 0; i < count; i++)
        'UPDATE world SET randomnumber = ${newRands[i]} WHERE id = ${ids[i]}'
    ];
    await exec.executeBatch(writes);
    return [
      for (var i = 0; i < count; i++)
        {'id': ids[i], 'randomNumber': newRands[i]}
    ];
  });
  return Response.ok(jsonEncode(updates),
      headers: {'content-type': 'application/json'});
}

Future<Response> _fortunes(Request _) async {
  final fortunes =
      await withMysqlConnection<List<Map<String, Object>>>(_pool, (exec) async {
    final rs = await exec.execute('SELECT id, message FROM fortune');
    try {
      return <Map<String, Object>>[
        for (var i = 0; i < rs.rowCount; i++)
          {
            'id': rs.row(i).getInt('id')!,
            'message': rs.row(i).getString('message')!,
          }
      ];
    } finally {
      rs.release();
    }
  });
  fortunes.add({'id': 0, 'message': 'Additional fortune added at request time.'});
  fortunes.sort((a, b) => (a['message']! as String).compareTo(b['message']! as String));

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
  return Response.ok(html.toString(), headers: {'content-type': 'text/html; charset=utf-8'});
}

int _clampCount(String? raw) {
  final v = int.tryParse(raw ?? '1') ?? 1;
  return v < 1 ? 1 : (v > 500 ? 500 : v);
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
