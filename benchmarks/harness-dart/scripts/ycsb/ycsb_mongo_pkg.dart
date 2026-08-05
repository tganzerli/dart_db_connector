/// YCSB driver for the pure-Dart `mongo_dart` package (pub.dev baseline).
/// Opens one `Db` per worker so each run-phase loop has its own connection,
/// matching the developed driver's N-connection topology.
library;

import 'package:mongo_dart/mongo_dart.dart' as m;

import 'mongo_conn_info.dart';
import 'ycsb_driver.dart';
import 'ycsb_workload.dart';

class MongoPkgYcsbDriver implements YcsbDriver {
  final int poolSize;
  final _dbs = <m.Db>[];

  MongoPkgYcsbDriver({this.poolSize = 4});

  String get _uri {
    // mongo_dart targets the db in the URI path; authenticate via authSource.
    final base = mongoUri(); // mongodb://user:pass@host:port/?authSource=admin
    return base.replaceFirst('/?authSource=admin', '/${mongoDb()}?authSource=admin');
  }

  @override
  Future<void> setup(int conns) async {
    for (var i = 0; i < conns; i++) {
      final db = await m.Db.create(_uri);
      await db.open();
      _dbs.add(db);
    }
  }

  @override
  Future<void> load(YcsbConfig cfg) async {
    final target = _dbs.first.collection(mongoColl);
    try {
      await target.drop();
    } catch (_) {
      // collection may not exist yet — fine.
    }
    final fields = ycsbFields(cfg);
    for (var i = 0; i < cfg.recordCount; i++) {
      await target.insertOne({'_id': i, ...fields});
    }
  }

  @override
  Future<void> resetEmpty() async {
    final target = _dbs.first.collection(mongoColl);
    try {
      await target.drop();
    } catch (_) {
      // collection may not exist yet — fine.
    }
  }

  @override
  Future<YcsbWorker> worker() async {
    final db = _dbs.removeAt(0);
    _dbs.add(db); // round-robin (each returned once for N workers)
    return _MongoPkgWorker(db.collection(mongoColl));
  }

  @override
  Future<void> close() async {
    for (final db in _dbs) {
      await db.close();
    }
  }
}

class _MongoPkgWorker implements YcsbWorker {
  final m.DbCollection _coll;
  _MongoPkgWorker(this._coll);

  @override
  Future<void> read(int key) async {
    await _coll.findOne(m.where.eq('_id', key));
  }

  @override
  Future<void> update(int key, Map<String, Object?> field) async {
    final entry = field.entries.first;
    await _coll.updateOne(
        m.where.eq('_id', key), m.modify.set(entry.key, entry.value));
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
