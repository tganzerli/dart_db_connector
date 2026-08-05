/// MySQL `enum_field_types` codes — the MySQL analogue of Postgres OIDs.
///
/// Values mirror `mysql/field_types.h` from the MySQL client. The decoder
/// ([mysql_decoder.dart]) dispatches on these; unknown codes decode to raw
/// bytes. This is the MySQL counterpart of `postgres_oids.dart`.
library;

/// Raw `enum_field_types` codes used by the MySQL text protocol
/// (`native_mysql_field_type`).
abstract final class MysqlFieldType {
  static const int decimal = 0;
  static const int tiny = 1; // TINYINT
  static const int short = 2; // SMALLINT
  static const int long = 3; // INT
  static const int float = 4;
  static const int double_ = 5;
  static const int null_ = 6;
  static const int timestamp = 7;
  static const int longLong = 8; // BIGINT
  static const int int24 = 9; // MEDIUMINT
  static const int date = 10;
  static const int time = 11;
  static const int datetime = 12;
  static const int year = 13;
  static const int varchar = 15;
  static const int bit = 16;
  static const int json = 245;
  static const int newDecimal = 246;
  static const int enum_ = 247;
  static const int set = 248;
  static const int tinyBlob = 249;
  static const int mediumBlob = 250;
  static const int longBlob = 251;
  static const int blob = 252;
  static const int varString = 253; // VARCHAR at the protocol level
  static const int string = 254; // CHAR / ENUM / SET storage
  static const int geometry = 255;
}
