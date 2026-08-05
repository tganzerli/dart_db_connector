/// First-contact example for the MongoDB driver of `dart_db_connector`
///. Mirrors `mysql_main.dart` but for the document model: opens a
/// pool, runs collection CRUD + a small typed repository, and closes
/// cleanly. No SQL, no UnitOfWork — the operations are typed.
///
/// Run (with MongoDB up at localhost:27017):
///   cd dart && dart run example/mongo_main.dart
///   (bring the DB up first:
///    docker compose -f ../docker/mongo/docker-compose.yml up -d)
library;

import 'package:dart_db_connector/dart_db_connector.dart';

// ── A tiny domain entity + document repository. ──

class Product {
  final int id;
  final String name;
  final double price;
  const Product(this.id, this.name, this.price);

  Map<String, Object?> toDocument() =>
      {'_id': id, 'name': name, 'price': price};

  static Product fromDocument(BsonDocument d) => Product(
        d.getInt('_id')!,
        d.getString('name')!,
        d.getDouble('price')!,
      );

  @override
  String toString() => 'Product($id, $name, \$$price)';
}

Future<void> main() async {
  final pool = MongoConnectionPool(const MongoPoolConfig(
    uri: 'mongodb://root:123@127.0.0.1:27017/?authSource=admin',
    maxSize: 4,
  ));
  await pool.start();

  try {
    await pool.withConnection((conn) async {
      final catalog = conn.collection('teste', 'catalog');

      // Start clean.
      await catalog.command({'drop': 'catalog'}).catchError(
          (_) => const BsonDocument({})); // ignore "ns not found"

      // ── Direct collection operations (Map in, BsonDocument out). ──
      await catalog.insertOne({'_id': 1, 'name': 'Keyboard', 'price': 79.9});
      await catalog.insertOne({'_id': 2, 'name': 'Mouse', 'price': 29.5});
      await catalog.updateOne({
        '_id': 2
      }, {
        r'$set': {'price': 24.9}
      });

      final one = await catalog.findOne({'_id': 1});
      print('findOne(1): ${one?.toMap()}');
      print('count: ${await catalog.count()}');

      // ── Typed repository reusing the agnostic Repository<T,K>. ──
      final repo = MongoRepository<Product, int>(
        collection: catalog,
        toDocument: (p) => p.toDocument(),
        fromDocument: Product.fromDocument,
        idOf: (p) => p.id,
      );
      await repo.insert(const Product(3, 'Monitor', 199.0));
      print('repo.findById(3): ${await repo.findById(3)}');
      print('repo.findAll(): ${await repo.findAll()}');

      // ── Error handling: a duplicate _id surfaces the real message. ──
      try {
        await catalog.insertOne({'_id': 1, 'name': 'dup'});
      } on MongoOperationException catch (e) {
        print('caught expected error [${e.code}]: '
            '${e.message.split(',').first}');
      }
    });
  } finally {
    await pool.close();
  }
}
