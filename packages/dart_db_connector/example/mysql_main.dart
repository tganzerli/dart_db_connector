/// First-contact example for the MySQL driver of `dart_db_connector`
///. Mirrors `main.dart` (PostgreSQL): opens a pool, runs a query
/// and a small repository CRUD inside transactions, and closes cleanly.
///
/// Run (with MySQL up at localhost:3306, database=teste):
///   cd dart && dart run example/mysql_main.dart
///   (bring the DB up first: docker compose -f ../docker/mysql/docker-compose.yml \
///    --env-file ../docker/mysql/.env up -d)
library;

import 'package:dart_db_connector/dart_db_connector.dart';

// ── A tiny domain entity + repository (Tier 1 string SQL). ──

class Product {
  final int id;
  final String name;
  final double price;
  const Product(this.id, this.name, this.price);
  @override
  String toString() => 'Product($id, $name, \$$price)';
}

class ProductRepository extends MysqlRepository<Product, int> {
  ProductRepository(MysqlQueryExecutor exec) : super(exec, _fromRow);

  static Product _fromRow(MysqlResultRow r) =>
      Product(r.getInt('id')!, r.getString('name')!, r.getDouble('price')!);

  @override
  String get tableName => 'product';
  @override
  String get idColumn => 'id';
  @override
  String selectAllSql() => 'SELECT id, name, price FROM product ORDER BY id';
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
  // NOTE: libmysqlclient treats host `localhost` as a Unix-socket
  // connection (`/tmp/mysql.sock`), NOT TCP — unlike libpq. Use the
  // loopback IP `127.0.0.1` to force a TCP connection to the container.
  final pool = MysqlConnectionPool(
    const MysqlPoolConfig(
      host: '127.0.0.1',
      user: 'root',
      password: '123',
      database: 'teste',
      maxSize: 4,
    ),
  );
  await pool.start();

  try {
    // 1) A raw query inside a transaction.
    final version = await withMysqlTransaction<String>(pool, (exec) async {
      final rs = await exec.execute('SELECT VERSION() AS v');
      try {
        return rs.row(0).getString('v')!;
      } finally {
        rs.release();
      }
    });
    print('Connected to MySQL $version');

    // 2) Schema + repository CRUD, all committed atomically.
    final products =
        await withMysqlTransaction<List<Product>>(pool, (exec) async {
      await exec.execute('DROP TABLE IF EXISTS product');
      await exec.execute(
        'CREATE TABLE product (id INT PRIMARY KEY, name VARCHAR(64), '
        'price DECIMAL(10,2))',
      );
      final repo = ProductRepository(exec);
      await repo.insert(const Product(1, 'Widget', 9.90));
      await repo.insert(const Product(2, 'Gadget', 19.50));
      await repo.update(const Product(1, 'Widget Pro', 12.00));
      return repo.findAll();
    });

    print('Products after CRUD:');
    for (final p in products) {
      print('  $p');
    }
  } finally {
    await pool.close();
  }
}
