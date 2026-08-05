/// Phase 3 HTTP server — Dart (Shelf) + mongo_dart 0.10.9 (pub.dev baseline).
///
/// Pure-Dart MongoDB wire protocol implementation. Counterpart of
/// `bench/http/dart-native-mongo/bin/server.dart`, with the same six
/// endpoints and the same Shelf scaffolding. The only difference is the
/// driver layer: this server uses the canonical `mongo_dart` package
/// instead of the developed connector over libmongoc.
///
/// mongo_dart owns a single `Db` that multiplexes internally, so unlike
/// the developed driver there is no explicit N-connection pool here.
/// POOL_SIZE is read for env-contract symmetry but does not drive
/// behavior (the package manages its own connection).
///
/// Listens on 0.0.0.0:8080.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mongo_dart/mongo_dart.dart' as m;
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

late final m.Db _db;
final Random _rng = Random();

const int _worldRows = 10000;
const String _dbName = 'teste';

Future<void> main(List<String> args) async {
  // Read for env-contract symmetry with the developed driver; mongo_dart
  // manages its own connection, so this value does not drive behavior.
  final poolSize = int.parse(Platform.environment['POOL_SIZE'] ?? '8');
  final rawUri = Platform.environment['MONGO_URI'] ?? 'mongodb://mongo:27017';
  final uri = _withDbName(rawUri, _dbName);

  _db = await m.Db.create(uri);
  await _db.open();
  print('[dart-pkg-mongo] db ready (poolSize=$poolSize, unused) uri=$uri');

  final router = Router()
    ..get('/plaintext', _plaintext)
    ..get('/json', _json)
    ..get('/db', _dbEndpoint)
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
  print('[dart-pkg-mongo] listening on :${server.port}');
}

Response _plaintext(Request _) => Response.ok(
      'Hello, World!',
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );

Response _json(Request _) => Response.ok(
      jsonEncode({'message': 'Hello, World!'}),
      headers: {'content-type': 'application/json'},
    );

Future<Response> _dbEndpoint(Request _) async {
  final row = await _selectWorld(_rng.nextInt(_worldRows) + 1);
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
  final coll = _db.collection('fortune');
  final docs = await coll.find().toList();
  final fortunes = <Map<String, Object>>[
    for (final d in docs)
      {'id': d['_id'] as int, 'message': d['message'] as String},
  ];
  fortunes.add({'id': 0, 'message': 'Additional fortune added at request time.'});
  fortunes.sort(
      (a, b) => (a['message']! as String).compareTo(b['message']! as String));

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
  final coll = _db.collection('world');
  final doc = await coll.findOne(m.where.eq('_id', id));
  return {'id': doc!['_id'] as int, 'randomNumber': doc['randomnumber'] as int};
}

Future<Map<String, int>> _updateWorld(int id, int newRand) async {
  final coll = _db.collection('world');
  await coll.findOne(m.where.eq('_id', id));
  await coll.updateOne(m.where.eq('_id', id), m.modify.set('randomnumber', newRand));
  return {'id': id, 'randomNumber': newRand};
}

int _clampCount(String? raw) {
  final v = int.tryParse(raw ?? '1') ?? 1;
  if (v < 1) return 1;
  if (v > 500) return 500;
  return v;
}

/// Ensures the MongoDB URI carries the target db name in its path, since
/// mongo_dart selects the database from the URI. Appends [db] when the
/// authority has no path segment; preserves any existing query string and
/// leaves URIs that already name a database untouched.
String _withDbName(String uri, String db) {
  final qIndex = uri.indexOf('?');
  final base = qIndex >= 0 ? uri.substring(0, qIndex) : uri;
  final query = qIndex >= 0 ? uri.substring(qIndex) : '';

  final schemeEnd = base.indexOf('://');
  final afterScheme = schemeEnd >= 0 ? base.substring(schemeEnd + 3) : base;
  final slash = afterScheme.indexOf('/');
  if (slash >= 0) {
    final path = afterScheme.substring(slash + 1);
    if (path.isNotEmpty) return uri; // already names a database
    return '$base$db$query'; // trailing slash, no db name
  }
  return '$base/$db$query';
}

String _escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
