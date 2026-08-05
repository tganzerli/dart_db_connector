/// First-contact example for the SQLite driver of `dart_db_connector`
///. Embedded, relational: opens a WAL pool over a file, runs CRUD
/// inside a transaction via a repository, and closes cleanly.
///
/// Run: cd dart && dart run example/sqlite_main.dart
library;

import 'dart:io';

import 'package:dart_db_connector/dart_db_connector.dart';

class Product {
  final int id;
  final String name;
  final double price;
  const Product(this.id, this.name, this.price);
  @override
  String toString() => 'Product($id, $name, \$$price)';
}

class ProductRepository extends SqliteRepository<Product, int> {
  ProductRepository(SqliteQueryExecutor exec)
      : super(
            exec,
            (r) => Product(
                r.getInt('id')!, r.getString('name')!, r.getDouble('price')!));
  @override
  String get tableName => 'product';
  @override
  String get idColumn => 'id';
  @override
  String selectAllSql() => 'SELECT id, name, price FROM product';
  @override
  String selectByIdSql(int id) =>
      'SELECT id, name, price FROM product WHERE id = $id';
  @override
  String insertSql(Product p) =>
      "INSERT INTO product (id, name, price) VALUES (${p.id}, '${p.name}', ${p.price})";
  @override
  String updateSql(Product p) =>
      "UPDATE product SET name = '${p.name}', price = ${p.price} WHERE id = ${p.id}";
  @override
  String deleteSql(int id) => 'DELETE FROM product WHERE id = $id';
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('ddc_sqlite_example_');
  final pool = SqliteConnectionPool(
    SqlitePoolConfig(path: '${dir.path}/catalog.db', maxSize: 4),
  );
  await pool.start();

  try {
    await withSqliteTransaction(pool, (exec) async {
      (await exec.execute(
              'CREATE TABLE product (id INTEGER PRIMARY KEY, name TEXT, price REAL)'))
          .release();
      final repo = ProductRepository(exec);
      await repo.insert(const Product(1, 'Keyboard', 79.9));
      await repo.insert(const Product(2, 'Mouse', 24.9));
      await repo.update(const Product(2, 'Mouse Pro', 39.9));
      print('findById(1): ${await repo.findById(1)}');
      print('findAll(): ${await repo.findAll()}');
    });

    // Error handling: the real sqlite3 message is surfaced.
    try {
      final c = await pool.acquire();
      try {
        await SqliteQueryExecutor(pool.binding, c.raw)
            .execute('SELECT * FROM missing');
      } finally {
        await c.release();
      }
    } catch (e) {
      print('caught expected error: ${e.toString().split(':').last.trim()}');
    }
  } finally {
    await pool.close();
    dir.deleteSync(recursive: true);
  }
}
