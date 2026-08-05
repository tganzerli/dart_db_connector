/// Integration test for the MySQL domain layer:
/// MysqlUnitOfWork transactions + MysqlRepository CRUD against a real DB.
library;

import 'dart:ffi' as ffi;

import 'package:dart_db_connector/src/bindings/mysql_binding.dart';
import 'package:dart_db_connector/src/decoder/mysql_result_row.dart';
import 'package:dart_db_connector/src/mysql/mysql_query_executor.dart';
import 'package:dart_db_connector/src/mysql/mysql_repository.dart';
import 'package:dart_db_connector/src/mysql/with_mysql_transaction.dart';
import 'package:dart_db_connector/src/native/mysql_native_pool.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:dart_db_connector/src/pool/mysql_connection_pool.dart';
import 'package:test/test.dart';

class Product {
  final int id;
  final String name;
  final double price;
  const Product(this.id, this.name, this.price);
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

void main() {
  MysqlBinding? binding;
  try {
    binding = MysqlBinding(loadNativeMysql());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }

  if (binding == null) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_mysql not available');
    });
    return;
  }

  final b = binding;
  const config = MysqlPoolConfig(
    host: '127.0.0.1',
    user: 'root',
    password: '123',
    database: 'teste',
    maxSize: 4,
    acquireTimeout: Duration(seconds: 2),
  );

  late MysqlConnectionPool pool;
  var reachable = true;

  setUp(() async {
    pool = MysqlConnectionPool.withBinding(b, config);
    try {
      await pool.start();
    } on MysqlNativePoolStartupException {
      reachable = false;
      return;
    }
    // Fresh schema each test.
    await withMysqlTransaction(pool, (exec) async {
      await exec.execute('DROP TABLE IF EXISTS product');
      await exec.execute(
        'CREATE TABLE product (id INT PRIMARY KEY, name VARCHAR(64), '
        'price DECIMAL(10,2))',
      );
    });
  });

  tearDown(() async {
    if (reachable) await pool.close();
  });

  test('repository CRUD inside a committed transaction', () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }

    final all = await withMysqlTransaction(pool, (exec) async {
      final repo = ProductRepository(exec);
      await repo.insert(const Product(1, 'Widget', 9.90));
      await repo.insert(const Product(2, 'Gadget', 19.50));
      await repo.update(const Product(1, 'Widget Pro', 12.00));
      await repo.delete(2);
      return repo.findAll();
    });

    expect(all, hasLength(1));
    expect(all.single.id, 1);
    expect(all.single.name, 'Widget Pro');
    expect(all.single.price, 12.00);

    // findById in a separate transaction sees the committed state.
    final found = await withMysqlTransaction(pool, (exec) async {
      return ProductRepository(exec).findById(1);
    });
    expect(found, isNotNull);
    expect(found!.name, 'Widget Pro');
  });

  test('rollback on exception leaves no committed rows', () async {
    if (!reachable) {
      markTestSkipped('MySQL not reachable');
      return;
    }

    await expectLater(
      withMysqlTransaction(pool, (exec) async {
        await ProductRepository(exec).insert(const Product(3, 'Doomed', 1.0));
        throw StateError('boom'); // forces rollback
      }),
      throwsA(isA<StateError>()),
    );

    final survivors = await withMysqlTransaction(
        pool, (exec) async => ProductRepository(exec).findAll());
    expect(survivors, isEmpty, reason: 'insert was rolled back');
  });
}
