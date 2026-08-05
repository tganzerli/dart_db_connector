/// Mapping from a MySQL `enum_field_types` code to a Dart-friendly type
/// tag. MySQL counterpart of `postgres_type.dart`.
library;

import 'mysql_field_types.dart';

/// Dart-friendly tag for the most common MySQL data types. Codes outside
/// this enum decode to [MysqlType.unknown] and the raw bytes can be read
/// via `row[col]` as a `Uint8List`.
enum MysqlType {
  tinyInt,
  smallInt,
  mediumInt,
  integer,
  bigInt,
  year,
  float,
  double_,
  decimal,
  text,
  json,
  blob,
  bit,
  date,
  time,
  datetime,
  timestamp,
  unknown,
}

/// Maps a MySQL `enum_field_types` code to a [MysqlType].
MysqlType mysqlTypeFromCode(int code) => switch (code) {
      MysqlFieldType.tiny => MysqlType.tinyInt,
      MysqlFieldType.short => MysqlType.smallInt,
      MysqlFieldType.int24 => MysqlType.mediumInt,
      MysqlFieldType.long => MysqlType.integer,
      MysqlFieldType.longLong => MysqlType.bigInt,
      MysqlFieldType.year => MysqlType.year,
      MysqlFieldType.float => MysqlType.float,
      MysqlFieldType.double_ => MysqlType.double_,
      MysqlFieldType.decimal || MysqlFieldType.newDecimal => MysqlType.decimal,
      MysqlFieldType.varchar ||
      MysqlFieldType.varString ||
      MysqlFieldType.string ||
      MysqlFieldType.enum_ ||
      MysqlFieldType.set =>
        MysqlType.text,
      MysqlFieldType.json => MysqlType.json,
      MysqlFieldType.tinyBlob ||
      MysqlFieldType.mediumBlob ||
      MysqlFieldType.longBlob ||
      MysqlFieldType.blob =>
        MysqlType.blob,
      MysqlFieldType.bit => MysqlType.bit,
      MysqlFieldType.date => MysqlType.date,
      MysqlFieldType.time => MysqlType.time,
      MysqlFieldType.datetime => MysqlType.datetime,
      MysqlFieldType.timestamp => MysqlType.timestamp,
      _ => MysqlType.unknown,
    };
