/// Raw-server benchmark HTTP server — Dart **raw `dart:io HttpServer`** (no Shelf) +
/// dart_db_connector (FFI over libpq).
///
/// Sibling of `bench/http/dart-native` (Shelf). Same six TechEmpower-style
/// endpoints, same DB logic byte-for-byte (pool, `withPostgresConnection`
/// fast-path for reads, `withTransaction` for updates, `Param.int4`,
/// `binaryResult: true`). The ONLY difference is the transport layer:
/// `HttpServer.bind` + manual `switch` dispatch replace `shelf_io.serve` +
/// `Router`. This isolates the **framework cost** the Phase-3 doc attributed
/// to Shelf (Shelf `/plaintext` ≈ 15% of axum — see
/// the holistic HTTP benchmark), keeping the
/// driver, pool and query execution constant.
///
///   - GET /plaintext               text body
///   - GET /json                    {"message": "Hello, World!"}
///   - GET /db                      one random World row as JSON
///   - GET /queries?count=N         N random rows in parallel, JSON array
///   - GET /updates?count=N         N updates+selects in parallel, JSON array
///   - GET /fortunes                fortune table + extra row, HTML escape
///
/// Listens on 0.0.0.0:8080. Pool size from POOL_SIZE (default 64). Postgres
/// params from POSTGRES_HOST/PORT/DB/USER/PASSWORD.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_db_connector/dart_db_connector.dart';

late final PostgresConnectionPool _pool;
final Random _rng = Random();

const int _worldRows = 10000;

Future<void> main(List<String> args) async {
  final poolSize = int.parse(Platform.environment['POOL_SIZE'] ?? '64');
  final host = Platform.environment['POSTGRES_HOST'] ?? 'postgres';
  final port = Platform.environment['POSTGRES_PORT'] ?? '5432';
  final db = Platform.environment['POSTGRES_DB'] ?? 'teste';
  final user = Platform.environment['POSTGRES_USER'] ?? 'postgres';
  final password = Platform.environment['POSTGRES_PASSWORD'] ?? '123';

  final connInfo =
      'host=$host port=$port dbname=$db user=$user password=$password';
  _pool = PostgresConnectionPool(
    PoolConfig(connInfo: connInfo, minSize: poolSize, maxSize: poolSize),
  );
  await _pool.start();
  print('[dart-native-raw] pool ready (size=$poolSize)  connInfo=$connInfo');

  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  server.autoCompress = false;
  // Fire-and-forget dispatch: the accept loop never blocks on a handler, so
  // requests are served concurrently (matches Shelf's per-request Future).
  server.listen(_dispatch);
  print('[dart-native-raw] listening on http://${server.address.host}:${server.port}');
}

void _dispatch(HttpRequest req) {
  // Never let a handler error escape onto the accept loop.
  unawaited(_handle(req).catchError((Object e, StackTrace _) async {
    try {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.headers.contentType = ContentType.text;
      req.response.write('error: $e');
      await req.response.close();
    } catch (_) {/* response already committed */}
  }));
}

Future<void> _handle(HttpRequest req) async {
  final res = req.response;
  switch (req.uri.path) {
    case '/plaintext':
      _plaintext(res);
      break;
    case '/json':
      _json(res);
      break;
    case '/db':
      await _db(res);
      break;
    case '/queries':
      await _queries(req, res);
      break;
    case '/updates':
      await _updates(req, res);
      break;
    case '/fortunes':
      await _fortunes(res);
      break;
    default:
      res.statusCode = HttpStatus.notFound;
      res.write('not found');
  }
  await res.close();
}

void _plaintext(HttpResponse res) {
  res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
  res.write('Hello, World!');
}

void _json(HttpResponse res) {
  res.headers.contentType = ContentType('application', 'json');
  res.write(jsonEncode({'message': 'Hello, World!'}));
}

Future<void> _db(HttpResponse res) async {
  final id = _rng.nextInt(_worldRows) + 1;
  final row = await _selectWorld(id);
  res.headers.contentType = ContentType('application', 'json');
  res.write(jsonEncode(row));
}

Future<void> _queries(HttpRequest req, HttpResponse res) async {
  final count = _clampCount(req.uri.queryParameters['count']);
  final ids = List.generate(count, (_) => _rng.nextInt(_worldRows) + 1);
  final rows = await Future.wait(ids.map(_selectWorld));
  res.headers.contentType = ContentType('application', 'json');
  res.write(jsonEncode(rows));
}

Future<void> _updates(HttpRequest req, HttpResponse res) async {
  final count = _clampCount(req.uri.queryParameters['count']);
  final updates = await Future.wait(List.generate(count, (_) async {
    final id = _rng.nextInt(_worldRows) + 1;
    final newRand = _rng.nextInt(_worldRows) + 1;
    return _updateWorld(id, newRand);
  }));
  res.headers.contentType = ContentType('application', 'json');
  res.write(jsonEncode(updates));
}

Future<void> _fortunes(HttpResponse res) async {
  final fortunes = await withPostgresConnection<List<Map<String, Object>>>(_pool,
      (exec) async {
    // binaryResult: true exercises the binary wire format path (int4 +
    // varchar both supported;.
    final rs = await exec.execute(
      'SELECT id, message FROM fortune',
      binaryResult: true,
    );
    try {
      return [
        for (var i = 0; i < rs.rowCount; i++)
          {
            'id': rs.row(i).getInt('id')!,
            'message': rs.row(i).getString('message')!,
          },
      ];
    } finally {
      rs.release();
    }
  });
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
  res.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
  res.write(html.toString());
}

Future<Map<String, int>> _selectWorld(int id) async {
  return withPostgresConnection<Map<String, int>>(_pool, (exec) async {
    final rs = await exec.execute(
      'SELECT id, randomnumber FROM world WHERE id = \$1',
      params: [Param.int4(id)],
      binaryResult: true,
    );
    try {
      final row = rs.row(0);
      return {
        'id': row.getInt('id')!,
        'randomNumber': row.getInt('randomnumber')!,
      };
    } finally {
      rs.release();
    }
  });
}

Future<Map<String, int>> _updateWorld(int id, int newRand) async {
  return withTransaction<Map<String, int>>(_pool, (exec) async {
    final rs = await exec.execute(
      'SELECT id, randomnumber FROM world WHERE id = \$1',
      params: [Param.int4(id)],
      binaryResult: true,
    );
    rs.release();
    final upd = await exec.execute(
      'UPDATE world SET randomnumber = \$1 WHERE id = \$2',
      params: [Param.int4(newRand), Param.int4(id)],
    );
    upd.release();
    return {'id': id, 'randomNumber': newRand};
  });
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
