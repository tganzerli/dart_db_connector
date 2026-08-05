/// Integration tests for the MongoDB driver. Exercises the full
/// stack: native pool → binding → BSON codec → collection → repository,
/// against a live MongoDB (a local MongoDB). Skips if the native lib is not
/// built or the server is unreachable.
library;

import 'dart:ffi' as ffi;

import 'package:dart_db_connector/src/bindings/mongo_binding.dart';
import 'package:dart_db_connector/src/mongo/mongo_bulk_result.dart';
import 'package:dart_db_connector/src/mongo/mongo_repository.dart';
import 'package:dart_db_connector/src/native/mongo_native_pool.dart';
import 'package:dart_db_connector/src/native_lib_loader.dart';
import 'package:dart_db_connector/src/pool/mongo_connection_pool.dart';
import 'package:test/test.dart';

const _config = MongoPoolConfig(
  uri: 'mongodb://root:123@127.0.0.1:27017/?authSource=admin',
  maxSize: 2,
  acquireTimeout: Duration(seconds: 3),
);
const _db = 'teste';

void main() {
  MongoBinding? binding;
  try {
    binding = MongoBinding(loadNativeMongo());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }

  if (binding == null) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_mongo not available');
    });
    return;
  }

  final b = binding;
  late MongoConnectionPool pool;
  var reachable = true;

  setUp(() async {
    pool = MongoConnectionPool.withBinding(b, _config);
    try {
      await pool.start();
    } on MongoNativePoolStartupException {
      reachable = false;
      return;
    }
    // Clean the working collection.
    try {
      await pool.withConnection(
          (c) => c.collection(_db, 'people').command({'drop': 'people'}));
    } on MongoOperationException {
      // "ns not found" when the collection does not exist yet — ignore.
    }
  });

  tearDown(() async {
    await pool.close();
  });

  test('insertOne + findOne round-trip decodes every field', () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      await people.insertOne({
        '_id': 1,
        'name': 'Ada',
        'age': 36,
        'score': 9.5,
        'active': true,
        'tags': ['math', 'engines'],
      });
      final doc = await people.findOne({'_id': 1});
      expect(doc, isNotNull);
      expect(doc!.getString('name'), 'Ada');
      expect(doc.getInt('age'), 36);
      expect(doc.getDouble('score'), 9.5);
      expect(doc.getBool('active'), isTrue);
      expect(doc.getList('tags'), equals(['math', 'engines']));
    });
  });

  test('find many + count', () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      for (var i = 0; i < 5; i++) {
        await people.insertOne({'_id': i, 'grp': i.isEven ? 'a' : 'b'});
      }
      expect(await people.count(), 5);
      expect(await people.count({'grp': 'a'}), 3);
      final all = await people.find(const {});
      expect(all, hasLength(5));
    });
  });

  test('updateOne then deleteOne', () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      await people.insertOne({'_id': 7, 'v': 1});
      await people.updateOne({
        '_id': 7
      }, {
        r'$set': {'v': 2}
      });
      expect((await people.findOne({'_id': 7}))!.getInt('v'), 2);
      await people.deleteOne({'_id': 7});
      expect(await people.findOne({'_id': 7}), isNull);
    });
  });

  test('error propagation: duplicate _id throws with real message + code',
      () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      await people.insertOne({'_id': 42, 'x': 1});
      try {
        await people.insertOne({'_id': 42, 'x': 2});
        fail('expected a duplicate-key error');
      } on MongoOperationException catch (e) {
        expect(e.message, contains('E11000'));
        expect(e.code, isNot(0));
      }
    });
  });

  test('insertMany inserts N documents in one bulk op', () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      final res = await people.insertMany([
        {'_id': 1, 'name': 'a'},
        {'_id': 2, 'name': 'b'},
        {'_id': 3, 'name': 'c'},
      ]);
      expect(res.insertedCount, 3);
      expect(await people.count(), 3);
    });
  });

  test('insertMany empty list is a no-op (insertedCount 0)', () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      final res = await people.insertMany(const []);
      expect(res.insertedCount, 0);
      expect(await people.count(), 0);
    });
  });

  test('insertMany ordered stops at the first duplicate _id', () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      await people.insertOne({'_id': 2}); // pre-seed the conflict
      try {
        await people.insertMany([
          {'_id': 1},
          {'_id': 2}, // duplicate at index 1
          {'_id': 3},
        ]);
        fail('expected a bulk write error');
      } on MongoBulkWriteException catch (e) {
        expect(e.insertedCount, 1); // only _id:1 before the ordered stop
        expect(e.writeErrors, hasLength(1));
        expect(e.writeErrors.single.index, 1);
        expect(e.writeErrors.single.code, 11000);
        expect(e.message, contains('E11000'));
      }
      // _id:3 must NOT have been inserted (ordered stops at index 1).
      expect(await people.count(), 2); // pre-seeded _id:2 + _id:1
    });
  });

  test('insertMany unordered continues past duplicates, reports all', () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final people = c.collection(_db, 'people');
      await people.insertOne({'_id': 2});
      await people.insertOne({'_id': 4});
      try {
        await people.insertMany([
          {'_id': 1},
          {'_id': 2}, // dup at index 1
          {'_id': 3},
          {'_id': 4}, // dup at index 3
          {'_id': 5},
        ], ordered: false);
        fail('expected a bulk write error');
      } on MongoBulkWriteException catch (e) {
        expect(e.insertedCount, 3); // 1, 3, 5 succeeded
        expect(e.writeErrors, hasLength(2));
        expect(e.writeErrors.map((w) => w.index).toSet(), {1, 3});
        expect(e.writeErrors.every((w) => w.code == 11000), isTrue);
      }
      expect(await people.count(), 5); // 2,4 pre-seeded + 1,3,5
    });
  });

  test('MongoRepository<T,K> reuses the agnostic Repository contract',
      () async {
    if (!reachable) {
      markTestSkipped('MongoDB not reachable');
      return;
    }
    await pool.withConnection((c) async {
      final repo = MongoRepository<_Person, int>(
        collection: c.collection(_db, 'people'),
        toDocument: (p) => {'_id': p.id, 'name': p.name},
        fromDocument: (d) => _Person(d.getInt('_id')!, d.getString('name')!),
        idOf: (p) => p.id,
      );
      await repo.insert(_Person(1, 'Grace'));
      await repo.insert(_Person(2, 'Katherine'));
      expect((await repo.findById(1))!.name, 'Grace');
      expect(await repo.findAll(), hasLength(2));
      await repo.update(_Person(1, 'Grace Hopper'));
      expect((await repo.findById(1))!.name, 'Grace Hopper');
      await repo.delete(2);
      expect(await repo.findById(2), isNull);
    });
  });
}

class _Person {
  final int id;
  final String name;
  _Person(this.id, this.name);
}
