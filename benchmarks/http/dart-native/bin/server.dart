/// Phase 3 HTTP server — Dart (Shelf) + dart_db_connector (FFI over libpq).
///
/// Six TechEmpower-style endpoints:
///   - GET /plaintext               text body
///   - GET /json                    {"message": "Hello, World!"}
///   - GET /db                      one random World row as JSON
///   - GET /queries?count=N         N random rows in parallel, JSON array
///   - GET /updates?count=N         N updates+selects in parallel, JSON array
///   - GET /fortunes                fortune table + extra row, HTML escape
///
/// Listens on 0.0.0.0:8080. Connection pool size from POOL_SIZE env
/// (default 64). Postgres connection params from POSTGRES_HOST/PORT/DB/
/// USER/PASSWORD with sensible defaults for the bench compose network.
///
/// Notes:
/// * Reads + updates use the Postgres **Extended Query Protocol** via
///   `Param` bindings (ABI MINOR 1, 2026-05-23). Result rows for the
///   World/Fortune schema (int4 + varchar only) use **binary wire
///   format** (`binaryResult: true`). The text-concat F3 baseline is
///   in `docker/bench/outputs/phase3/bench-4cpu/`.
/// * **Best-mechanism per endpoint** (perf-v2 Etapa A): read-only
///   endpoints (`/db`, `/queries`, `/fortunes`) run through the
///   non-transactional fast-path `withPostgresConnection` — a single
///   autocommit round-trip, no BEGIN/COMMIT. `/updates` keeps
///   `withTransaction` (SELECT+UPDATE is a genuine read-modify-write
///   that belongs in one transaction). This is the idiomatic shape a
///   user would write; it is not required to match the other stacks
///   line-for-line, only to keep the execution constant (same query,
///   same protocol, same binary decode).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

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
  print('[dart-native] pool ready (size=$poolSize)  connInfo=$connInfo');

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
  print('[dart-native] listening on http://${server.address.host}:${server.port}');
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
  final fortunes = await withPostgresConnection<List<Map<String, Object>>>(_pool,
      (exec) async {
    // No params here, but binaryResult: true exercises the binary
    // wire format path (int4 + varchar both supported by the binary
    // decoder; see.
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
  return Response.ok(html.toString(),
      headers: {'content-type': 'text/html; charset=utf-8'});
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
