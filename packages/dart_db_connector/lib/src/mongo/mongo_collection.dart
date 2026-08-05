/// MongoDB collection operations — the document-model counterpart of the
/// relational `QueryExecutor`.
///
/// Takes plain Dart maps / [BsonDocument]s, encodes them to BSON via
/// [BsonWriter], dispatches through a pooled [MongoConn], and decodes the
/// BSON reply(ies). This is where the abstraction visibly DIVERGES from the
/// relational drivers: there is no `execute(sql)` — the operation IS the
/// method (insertOne/find/updateOne/deleteOne/aggregate/count). That
/// divergence is a cross-driver data point (see the architecture overview).
///
/// SECURITY: filters/documents are built from Dart values and encoded as
/// BSON — there is no string interpolation and thus no query-injection
/// surface analogous to SQL. This is a structural advantage of the document
/// wire protocol.
library;

import 'dart:typed_data';

import '../decoder/bson_value.dart';
import '../decoder/bson_writer.dart';
import '../native/mongo_native_pool.dart';
import 'mongo_bulk_result.dart';

/// Handle to a `db.coll` bound to one pooled [MongoConn].
class MongoCollection {
  final MongoConn _conn;
  final String db;
  final String coll;

  MongoCollection(this._conn, this.db, this.coll);

  /// Inserts [document]. Returns the write reply (e.g. `insertedCount`).
  Future<BsonDocument> insertOne(Map<String, Object?> document) {
    return _conn.insertOne(db, coll, BsonWriter.encodeDocument(document));
  }

  /// Inserts [documents] in one bulk operation (F1-Mongo). Returns a
  /// [BulkWriteResult] on success; throws [MongoBulkWriteException] on a
  /// partial or total failure, carrying the per-index write errors and the
  /// real libmongoc message. With [ordered] (default `true`) the server stops
  /// at the first error; `ordered: false` continues and reports every error.
  /// An empty list is a no-op returning `insertedCount: 0`.
  Future<BulkWriteResult> insertMany(List<Map<String, Object?>> documents,
      {bool ordered = true}) {
    return _conn.insertMany(
      db,
      coll,
      [for (final d in documents) BsonWriter.encodeDocument(d)],
      ordered: ordered,
    );
  }

  /// Finds documents matching [filter] (default: all). [limit], [sort] and
  /// [projection] map to the corresponding find options.
  Future<List<BsonDocument>> find(
    Map<String, Object?> filter, {
    int? limit,
    Map<String, Object?>? sort,
    Map<String, Object?>? projection,
  }) {
    Uint8List? optsBson;
    if (limit != null || sort != null || projection != null) {
      final opts = <String, Object?>{};
      if (limit != null) opts['limit'] = limit;
      if (sort != null) opts['sort'] = sort;
      if (projection != null) opts['projection'] = projection;
      optsBson = BsonWriter.encodeDocument(opts);
    }
    return _conn.find(db, coll, BsonWriter.encodeDocument(filter),
        opts: optsBson);
  }

  /// Finds the first document matching [filter], or null.
  Future<BsonDocument?> findOne(Map<String, Object?> filter,
      {Map<String, Object?>? sort}) async {
    final docs = await find(filter, limit: 1, sort: sort);
    return docs.isEmpty ? null : docs.first;
  }

  /// Updates one document matching [filter] with [update] (which must use
  /// operators, e.g. `{r'$set': {...}}`). Returns the reply.
  Future<BsonDocument> updateOne(
      Map<String, Object?> filter, Map<String, Object?> update) {
    return _conn.updateOne(db, coll, BsonWriter.encodeDocument(filter),
        BsonWriter.encodeDocument(update));
  }

  /// Deletes one document matching [filter]. Returns the reply.
  Future<BsonDocument> deleteOne(Map<String, Object?> filter) {
    return _conn.deleteOne(db, coll, BsonWriter.encodeDocument(filter));
  }

  /// Counts documents matching [filter] via the `count` command.
  Future<int> count([Map<String, Object?> filter = const {}]) async {
    final reply = await _conn.command(
        db,
        BsonWriter.encodeDocument({
          'count': coll,
          'query': filter,
        }));
    return reply.getInt('n') ?? 0;
  }

  /// Runs an aggregation [pipeline], returning the first cursor batch.
  /// (v1 does not iterate a server cursor beyond the first batch.)
  Future<List<BsonDocument>> aggregate(
      List<Map<String, Object?>> pipeline) async {
    final reply = await _conn.command(
        db,
        BsonWriter.encodeDocument({
          'aggregate': coll,
          'pipeline': pipeline,
          'cursor': <String, Object?>{},
        }));
    final cursor = reply.getDocument('cursor');
    final batch = cursor?.getList('firstBatch') ?? const [];
    return batch.whereType<BsonDocument>().toList();
  }

  /// Runs an arbitrary database [command] against this collection's db.
  Future<BsonDocument> command(Map<String, Object?> command) {
    return _conn.command(db, BsonWriter.encodeDocument(command));
  }
}
