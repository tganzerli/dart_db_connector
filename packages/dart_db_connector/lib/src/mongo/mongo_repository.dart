/// MongoDB-backed [Repository] implementation.
///
/// This is the reuse half of the cross-driver extensibility finding: the
/// DB-agnostic [Repository] interface (`domain/repository.dart`) is REUSED
/// unchanged — `MongoRepository<T, K> implements Repository<T, K>` — mapping
/// CRUD onto document operations of a [MongoCollection]. It needs no SQL and
/// no `QueryExecutor`/`UnitOfWork` (those leak the relational `ResultSet`/
/// `Param` types and simply do not apply to a document store; see the
/// architecture overview §divergence).
///
/// A concrete repository supplies a codec ([toDocument] / [fromDocument])
/// and the id accessor ([idOf]); the primary key maps to the `_id` field by
/// default (configurable via [idField]).
library;

import '../decoder/bson_value.dart';
import '../domain/repository.dart';
import 'mongo_collection.dart';

/// Generic document repository over a [MongoCollection]. Reuses the agnostic
/// [Repository] contract.
class MongoRepository<T, K> implements Repository<T, K> {
  final MongoCollection collection;

  /// Serializes an entity to a BSON-encodable map.
  final Map<String, Object?> Function(T entity) toDocument;

  /// Deserializes a decoded document into an entity.
  final T Function(BsonDocument doc) fromDocument;

  /// Extracts the primary-key value from an entity (for update/insert).
  final Object? Function(T entity) idOf;

  /// The document field holding the primary key (default `_id`).
  final String idField;

  MongoRepository({
    required this.collection,
    required this.toDocument,
    required this.fromDocument,
    required this.idOf,
    this.idField = '_id',
  });

  @override
  Future<T?> findById(K id) async {
    final doc = await collection.findOne({idField: id});
    return doc == null ? null : fromDocument(doc);
  }

  @override
  Future<List<T>> findAll() async {
    final docs = await collection.find(const {});
    return docs.map(fromDocument).toList();
  }

  @override
  Future<void> insert(T entity) async {
    await collection.insertOne(toDocument(entity));
  }

  @override
  Future<void> update(T entity) async {
    await collection.updateOne(
      {idField: idOf(entity)},
      {r'$set': toDocument(entity)},
    );
  }

  @override
  Future<void> delete(K id) async {
    await collection.deleteOne({idField: id});
  }
}
