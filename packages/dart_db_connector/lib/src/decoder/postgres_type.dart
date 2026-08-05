/// Mapping from Postgres OID to a Dart-friendly type tag.
///
/// Decoders ([_decoder.dart]) dispatch on these values. Custom/unknown
/// OIDs map to [PostgresType.unknown]; the decoder returns the raw
/// `Uint8List` so consumers can handle exotic types themselves.
library;

import 'postgres_oids.dart';

/// Dart-friendly tag for the most common PostgreSQL data types.
///
/// Use [ResultSet.typeOf] to inspect a column's type at runtime. Maps
/// from raw OIDs (see [PostgresOid]) via [postgresTypeFromOid]; types
/// outside this enum (custom enums, extensions, arrays) decode to
/// [PostgresType.unknown] and the raw bytes can be read via
/// `row[col]` as a `Uint8List`.
///
/// Example:
/// ```dart
/// if (rs.typeOf('amount') == PostgresType.numeric) {
///   final value = row.getDouble('amount');
/// }
/// ```
enum PostgresType {
  boolean,
  smallInt,
  integer,
  bigInt,
  real,
  double_,
  numeric,
  text,
  json,
  jsonb,
  bytea,
  timestamp,
  timestamptz,
  unknown,
}

/// Maps a Postgres type OID to a [PostgresType].
PostgresType postgresTypeFromOid(int oid) => switch (oid) {
      PostgresOid.boolean => PostgresType.boolean,
      PostgresOid.int2 => PostgresType.smallInt,
      PostgresOid.int4 => PostgresType.integer,
      PostgresOid.int8 => PostgresType.bigInt,
      PostgresOid.float4 => PostgresType.real,
      PostgresOid.float8 => PostgresType.double_,
      PostgresOid.numeric => PostgresType.numeric,
      PostgresOid.text ||
      PostgresOid.varchar ||
      PostgresOid.bpchar =>
        PostgresType.text,
      PostgresOid.json => PostgresType.json,
      PostgresOid.jsonb => PostgresType.jsonb,
      PostgresOid.bytea => PostgresType.bytea,
      PostgresOid.timestamp => PostgresType.timestamp,
      PostgresOid.timestamptz => PostgresType.timestamptz,
      _ => PostgresType.unknown,
    };
