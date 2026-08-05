/// MongoDB connection info for the YCSB bench, configurable via env vars.
/// Inside Docker set MONGO_HOST=mongo.
library;

import 'dart:io';

String mongoUri() {
  final host = Platform.environment['MONGO_HOST'] ?? '127.0.0.1';
  final port = Platform.environment['MONGO_PORT'] ?? '27017';
  final user = Platform.environment['MONGO_USER'] ?? 'root';
  final pass = Platform.environment['MONGO_PASSWORD'] ?? '123';
  return 'mongodb://$user:$pass@$host:$port/?authSource=admin';
}

String mongoDb() => Platform.environment['MONGO_DATABASE'] ?? 'ycsb';
const mongoColl = 'usertable';
