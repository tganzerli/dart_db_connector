/// HTTP MySQL/MongoDB benchmark HTTP server — Dart (Shelf) + dart_db_connector MongoDB (FFI over
/// libmongoc). DB-backed endpoints adaptados à semântica de documento.
///
/// Endpoints medidos: /db (findOne por _id), /queries (N findOne), /updates
/// (N updateOne), /fortunes (find all). Mirrors dart-native/bin/server.dart,
/// trocando SQL por operações tipadas de coleção (MongoCollection).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_db_connector/dart_db_connector.dart';
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

late final MongoConnectionPool _pool;
final Random _rng = Random();
const int _worldRows = 10000;
const String _db = 'teste';

Future<void> main(List<String> args) async {
  final poolSize = int.parse(Platform.environment['POOL_SIZE'] ?? '64');
  final uri = Platform.environment['MONGO_URI'] ?? 'mongodb://mongo:27017';

  _pool = MongoConnectionPool(
    MongoPoolConfig(uri: uri, minSize: poolSize, maxSize: poolSize),
  );
  await _pool.start();
  print('[dart-native-mongo] pool ready (size=$poolSize) uri=$uri');

  final router = Router()
    ..get('/plaintext', _plaintext)
    ..get('/json', _json)
    ..get('/db', _db_)
    ..get('/queries', _queries)
    ..get('/updates', _updates)
    ..get('/fortunes', _fortunes);

  final server =
      await shelf_io.serve(router.call, InternetAddress.anyIPv4, 8080, shared: false);
  server.autoCompress = false;
  print('[dart-native-mongo] listening on :${server.port}');
}

Response _plaintext(Request _) => Response.ok('Hello, World!',
    headers: {'content-type': 'text/plain; charset=utf-8'});

Response _json(Request _) => Response.ok(jsonEncode({'message': 'Hello, World!'}),
    headers: {'content-type': 'application/json'});

Future<Response> _db_(Request _) async {
  final row = await _selectWorld(_rng.nextInt(_worldRows) + 1);
  return Response.ok(jsonEncode(row), headers: {'content-type': 'application/json'});
}

Future<Response> _queries(Request req) async {
  final count = _clampCount(req.url.queryParameters['count']);
  final ids = List.generate(count, (_) => _rng.nextInt(_worldRows) + 1);
  final rows = await Future.wait(ids.map(_selectWorld));
  return Response.ok(jsonEncode(rows), headers: {'content-type': 'application/json'});
}

Future<Response> _updates(Request req) async {
  final count = _clampCount(req.url.queryParameters['count']);
  final updates = await Future.wait(List.generate(count, (_) async {
    final id = _rng.nextInt(_worldRows) + 1;
    final newRand = _rng.nextInt(_worldRows) + 1;
    return _updateWorld(id, newRand);
  }));
  return Response.ok(jsonEncode(updates), headers: {'content-type': 'application/json'});
}

Future<Response> _fortunes(Request _) async {
  final docs = await _pool.withConnection((conn) async {
    return conn.collection(_db, 'fortune').find(const {});
  });
  final fortunes = <Map<String, Object>>[
    for (final d in docs)
      {'id': d.getInt('_id')!, 'message': d.getString('message')!},
  ];
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

Future<Map<String, int>> _selectWorld(int id) async {
  return _pool.withConnection((conn) async {
    final doc = await conn.collection(_db, 'world').findOne({'_id': id});
    return {'id': doc!.getInt('_id')!, 'randomNumber': doc.getInt('randomnumber')!};
  });
}

Future<Map<String, int>> _updateWorld(int id, int newRand) async {
  return _pool.withConnection((conn) async {
    final coll = conn.collection(_db, 'world');
    await coll.findOne({'_id': id});
    await coll.updateOne({'_id': id}, {r'$set': {'randomnumber': newRand}});
    return {'id': id, 'randomNumber': newRand};
  });
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
