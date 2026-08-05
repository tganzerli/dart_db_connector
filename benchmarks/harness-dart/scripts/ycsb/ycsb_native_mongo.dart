/// YCSB driver for the DEVELOPED MongoDB driver (FFI over libmongoc,
/// ). Each worker holds one pooled connection for the run phase.
library;

import 'package:dart_db_connector/dart_db_connector.dart';

import 'mongo_conn_info.dart';
import 'ycsb_driver.dart';
import 'ycsb_workload.dart';

class NativeMongoYcsbDriver implements YcsbDriver {
  final int poolSize;
  late final MongoConnectionPool _pool;
  final _held = <MongoPooledConnection>[];

  NativeMongoYcsbDriver({this.poolSize = 4});

  @override
  Future<void> setup(int conns) async {
    _pool = MongoConnectionPool(MongoPoolConfig(
      uri: mongoUri(),
      minSize: conns,
      maxSize: conns,
    ));
    await _pool.start();
  }

  @override
  Future<void> load(YcsbConfig cfg) async {
    final conn = await _pool.acquire();
    try {
      final coll = conn.collection(mongoDb(), mongoColl);
      // Fresh dataset.
      try {
        await coll.command({'drop': mongoColl});
      } on MongoOperationException {
        // ns not found — fine.
      }
      final fields = ycsbFields(cfg);
      for (var i = 0; i < cfg.recordCount; i++) {
        await coll.insertOne({'_id': i, ...fields});
      }
    } finally {
      await conn.release();
    }
  }

  @override
  Future<void> resetEmpty() async {
    final conn = await _pool.acquire();
    try {
      final coll = conn.collection(mongoDb(), mongoColl);
      try {
        await coll.command({'drop': mongoColl});
      } on MongoOperationException {
        // ns not found — fine.
      }
    } finally {
      await conn.release();
    }
  }

  @override
  Future<YcsbWorker> worker() async {
    final conn = await _pool.acquire();
    _held.add(conn);
    return _NativeMongoWorker(conn.collection(mongoDb(), mongoColl));
  }

  @override
  Future<void> close() async {
    for (final c in _held) {
      await c.release();
    }
    await _pool.close();
  }
}

class _NativeMongoWorker implements YcsbWorker {
  final MongoCollection _coll;
  _NativeMongoWorker(this._coll);

  @override
  Future<void> read(int key) async {
    await _coll.findOne({'_id': key});
  }

  @override
  Future<void> update(int key, Map<String, Object?> field) async {
    await _coll.updateOne({'_id': key}, {r'$set': field});
  }

  @override
  Future<void> insertOne(Map<String, Object?> doc) async {
    await _coll.insertOne(doc);
  }

  @override
  Future<void> insertMany(List<Map<String, Object?>> docs) async {
    await _coll.insertMany(docs);
  }
}
