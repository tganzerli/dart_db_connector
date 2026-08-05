/// PostgreSQL built-in type OIDs.
///
/// Stable across Postgres versions for built-in types (sourced from
/// `src/include/catalog/pg_type.dat`). Custom types from extensions may
/// have OIDs that fall outside this list — those decode as `unknown`
/// (raw `Uint8List`) by [postgresTypeFromOid].
///
/// Reference: the PostgreSQL frontend/backend protocol documentation
/// §"Tipos de dados".
library;

/// Catalog of stable built-in PostgreSQL type OIDs.
///
/// Each constant is the raw OID value taken from `pg_type.dat`. These
/// values are stable across Postgres versions for built-in types, so
/// consumers can compare directly against [ResultSet.columnOids] to
/// detect column types — useful for handling extension or custom
/// types that fall outside [PostgresType].
///
/// Example:
/// ```dart
/// final isNumeric = rs.columnOids[idx] == PostgresOid.numeric;
/// ```
abstract final class PostgresOid {
  /// `bool` (size 1 in binary; 't'/'f' in text)
  static const int boolean = 16;

  /// `bytea` (binary data; text uses `\x<hex>` prefix)
  static const int bytea = 17;

  /// `int8` / `bigint`
  static const int int8 = 20;

  /// `int2` / `smallint`
  static const int int2 = 21;

  /// `int4` / `integer`
  static const int int4 = 23;

  /// `text` (variable-length, UTF-8)
  static const int text = 25;

  /// `numeric` / `decimal` (arbitrary precision; in text mode comes as
  /// a decimal string like `"123.45"`). Decoded as `double` here for
  /// ergonomics — TPC-C-style money math is < 8 decimal digits and
  /// fits in IEEE 754 without loss. If exact decimal is needed, the
  /// caller can read the raw bytes and use a BigDecimal package.
  static const int numeric = 1700;

  /// `json`
  static const int json = 114;

  /// `float4` / `real`
  static const int float4 = 700;

  /// `float8` / `double precision`
  static const int float8 = 701;

  /// `bpchar` (blank-padded `char(N)`)
  static const int bpchar = 1042;

  /// `varchar`
  static const int varchar = 1043;

  /// `timestamp` (without time zone)
  static const int timestamp = 1114;

  /// `timestamptz` (with time zone)
  static const int timestamptz = 1184;

  /// `jsonb`
  static const int jsonb = 3802;
}
