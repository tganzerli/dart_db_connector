/// Decoders from raw libpq bytes to Dart values.
///
/// Internal — consumed by [ResultRow]. Provides two parallel families:
///   - [decodeByOid] for **text** wire format (libpq `PQsendQuery` default).
///   - [decodeByOidBinary] for **binary** wire format (added in ABI MINOR 1,
///     2026-05-23, via `PQsendQueryParams(..., resultFormat=1)`).
///
/// Both paths normalise to the same Dart value types (bool / int /
/// double / String / DateTime / Map|List / Uint8List), so consumers
/// of [ResultRow] don't observe a difference.
library;

import 'dart:convert' show utf8, jsonDecode;
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'postgres_oids.dart';
import 'postgres_type.dart';

/// Decoder for a single cell, reading straight from the zero-copy pointer
/// (`ptr` + `len`) returned by the native ABI. The pointer is guaranteed
/// non-null by the caller (SQL NULL is handled before the decoder runs).
///
/// The signature is deliberately driver-agnostic — it names no Postgres
/// type — so the same shape backs the MySQL mirror and is the candidate
/// for the v2 SQL-agnostic seam (see `decode_plan.dart`). Resolved once
/// per result shape by the codec plan, replacing the per-cell `switch`.
typedef CellDecoder = Object? Function(ffi.Pointer<ffi.Uint8> ptr, int len);

/// Postgres binary timestamp epoch (2000-01-01T00:00:00Z) expressed as
/// microseconds since the Unix epoch. Mirrors the encoder side in
/// `dart/lib/src/postgres/param.dart` so encode/decode round-trip.
const int _postgresEpochUnixMicros = 946684800 * 1000000;

/// Decodes [bytes] (text-format from libpq) into a Dart value according
/// to [oid].
///
/// Returns:
///   - `bool` for OID `boolean`
///   - `int` for OIDs int2/int4/int8
///   - `double` for OIDs float4/float8
///   - `String` for OIDs text/varchar/bpchar
///   - `dynamic` (Map/List/etc) for json/jsonb (via [jsonDecode])
///   - `Uint8List` for bytea (decoded from `\x<hex>` text format) and
///     for unknown OIDs (returned as-is)
///   - `DateTime` for timestamp/timestamptz
Object decodeByOid(Uint8List bytes, int oid) {
  return switch (oid) {
    PostgresOid.boolean => bytes.isNotEmpty && bytes[0] == 0x74, // 't'
    PostgresOid.int2 ||
    PostgresOid.int4 ||
    PostgresOid.int8 =>
      int.parse(_asciiString(bytes)),
    PostgresOid.float4 ||
    PostgresOid.float8 ||
    PostgresOid.numeric =>
      double.parse(_asciiString(bytes)),
    PostgresOid.text ||
    PostgresOid.varchar ||
    PostgresOid.bpchar =>
      utf8.decode(bytes),
    PostgresOid.json ||
    PostgresOid.jsonb =>
      jsonDecode(utf8.decode(bytes)) as Object,
    PostgresOid.bytea => _decodeByteaHex(bytes),
    PostgresOid.timestamp ||
    PostgresOid.timestamptz =>
      _parsePostgresTimestamp(_asciiString(bytes)),
    _ => bytes, // unknown OID → return raw bytes
  };
}

/// Fast path for ASCII-only payloads (numbers, booleans, timestamps in
/// text mode). Avoids the full UTF-8 decoder.
String _asciiString(Uint8List bytes) => String.fromCharCodes(bytes);

// ─────────────────────────────────────────────────────────────────────
// Codec plan — per-column decoder resolution (A2) + direct-from-pointer
// numeric parsing (A4). See `decode_plan.dart`.
//
// `textDecoderForOid` / `binaryDecoderForOid` resolve the OID → decoder
// switch ONCE per result shape (the plan caches the returned closures),
// so the per-cell hot path no longer branches on the OID. Cold OIDs
// (json/bytea/timestamp/unknown) delegate to the existing
// [decodeByOid]/[decodeByOidBinary] families via `asTypedList`, keeping a
// single source of truth for decode semantics.
// ─────────────────────────────────────────────────────────────────────

/// Resolves the [CellDecoder] for a **text**-format column of type [oid].
/// Called once per result shape by the codec plan.
CellDecoder textDecoderForOid(int oid) => switch (oid) {
      PostgresOid.int2 ||
      PostgresOid.int4 ||
      PostgresOid.int8 =>
        _decodeIntTextPtr,
      PostgresOid.boolean => _decodeBoolTextPtr,
      PostgresOid.float4 ||
      PostgresOid.float8 ||
      PostgresOid.numeric =>
        _decodeDoubleTextPtr,
      PostgresOid.text ||
      PostgresOid.varchar ||
      PostgresOid.bpchar =>
        _decodeUtf8Ptr,
      // Cold OIDs (json/jsonb/bytea/timestamp/unknown): delegate to the
      // canonical text family — same semantics, resolved once per plan.
      _ => (ptr, len) => decodeByOid(ptr.asTypedList(len), oid),
    };

/// Resolves the [CellDecoder] for a **binary**-format column of type
/// [oid]. Binary is not the A4 hot path (TPC-C runs text mode because of
/// `numeric`), so every binary decoder delegates to the canonical
/// [decodeByOidBinary] — the win here is A2 (switch resolved once), not a
/// specialised parser.
CellDecoder binaryDecoderForOid(int oid) =>
    (ptr, len) => decodeByOidBinary(ptr.asTypedList(len), oid);

/// A4: parses a text-mode integer (`int2`/`int4`/`int8`) straight from
/// the native pointer — no `asTypedList` wrapper, no intermediate
/// `String`. Reads bytes with `ptr[i]` (a memory load, not an FFI call).
///
/// On any byte outside `[-0-9]` (should never happen for these OIDs in
/// text mode) it falls back to the String path, so semantics can only
/// match [decodeByOid], never diverge.
///
/// int64 edge cases are correct by two's-complement wraparound: for
/// `int8` min (`-9223372036854775808`) the positive accumulation wraps to
/// int64 min and the final negation is a no-op on int64 min, yielding the
/// right value. Postgres never emits an int8 outside `[-2^63, 2^63-1]`.
Object _decodeIntTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) {
  if (len == 0) return _intFallback(ptr, len);
  var i = 0;
  var neg = false;
  final first = ptr[0];
  if (first == 0x2D /* '-' */) {
    neg = true;
    i = 1;
  } else if (first == 0x2B /* '+' */) {
    i = 1;
  }
  if (i == len) return _intFallback(ptr, len); // lone sign
  var v = 0;
  for (; i < len; i++) {
    final d = ptr[i] - 0x30;
    if (d < 0 || d > 9) return _intFallback(ptr, len);
    v = v * 10 + d;
  }
  return neg ? -v : v;
}

Object _intFallback(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    int.parse(String.fromCharCodes(ptr.asTypedList(len)));

/// A4: parses a text-mode boolean (`'t'`/`'f'`) from the pointer. Mirrors
/// the `bytes[0] == 0x74` check in [decodeByOid].
Object _decodeBoolTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    len > 0 && ptr[0] == 0x74; // 't'

/// Text-mode float/numeric: keeps the `double.parse` path (v1). A manual
/// float parser has a high edge-case risk and TPC-C is int-dominated;
/// left as a future extension if the microbench points at it.
Object _decodeDoubleTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    double.parse(String.fromCharCodes(ptr.asTypedList(len)));

/// Text-mode UTF-8 string (text/varchar/bpchar). The zero-copy view is
/// the cheapest way to feed the UTF-8 decoder, which must allocate the
/// resulting `String` regardless.
Object _decodeUtf8Ptr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    utf8.decode(ptr.asTypedList(len));

/// Postgres text-mode `bytea` uses the `\x<hex>` prefix (since 9.0).
Uint8List _decodeByteaHex(Uint8List bytes) {
  if (bytes.length < 2 ||
      bytes[0] != 0x5C /* \ */ ||
      bytes[1] != 0x78 /* x */) {
    // Older escape format (\nnn octal) — not supported here; return as-is.
    return bytes;
  }
  final hex = bytes.sublist(2);
  if (hex.length.isOdd) {
    throw FormatException('bytea hex has odd length');
  }
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = (_hexNibble(hex[2 * i]) << 4) | _hexNibble(hex[2 * i + 1]);
  }
  return result;
}

int _hexNibble(int charCode) {
  if (charCode >= 0x30 && charCode <= 0x39) return charCode - 0x30;
  if (charCode >= 0x61 && charCode <= 0x66) return charCode - 0x61 + 10;
  if (charCode >= 0x41 && charCode <= 0x46) return charCode - 0x41 + 10;
  throw FormatException('invalid hex char: $charCode');
}

/// Parses Postgres text-mode timestamp format.
///
/// Expected formats:
///   - `timestamp`:    `2026-05-17 13:45:00[.fffffff]`
///   - `timestamptz`:  `2026-05-17 13:45:00[.fff]+00`
///
/// Converts to ISO-8601-ish (replace space with `T`) then `DateTime.parse`.
DateTime _parsePostgresTimestamp(String s) {
  final iso = s.replaceFirst(' ', 'T');
  return DateTime.parse(iso);
}

/// Decoded type information (for diagnostic / [ResultRow.typeOf]).
PostgresType decodedTypeForOid(int oid) => postgresTypeFromOid(oid);

/// Decodes [bytes] (binary-format from libpq, `resultFormat = 1`) into a
/// Dart value according to [oid]. Mirror of [decodeByOid] for the
/// Extended Query Protocol with `resultFormat = 1`.
///
/// Returns the same Dart value types as [decodeByOid] (bool / int /
/// double / String / DateTime / Map|List / Uint8List), so [ResultRow]
/// can mix-and-match without exposing the wire format to consumers.
///
/// Special cases:
///   - `numeric` (OID 1700): Postgres binary `numeric` uses variable-width
///     digit groups + scale + sign — non-trivial to decode and rarely
///     useful with a Dart `double`. We return raw [Uint8List] for now;
///     callers needing decimal precision should `SELECT col::text` or
///     wait for a follow-up MINOR.
///   - Unknown OIDs: returned as raw [Uint8List] (zero-copy view).
Object decodeByOidBinary(Uint8List bytes, int oid) {
  return switch (oid) {
    PostgresOid.boolean => bytes.isNotEmpty && bytes[0] == 0x01,
    PostgresOid.int2 => ByteData.sublistView(bytes).getInt16(0, Endian.big),
    PostgresOid.int4 => ByteData.sublistView(bytes).getInt32(0, Endian.big),
    PostgresOid.int8 => ByteData.sublistView(bytes).getInt64(0, Endian.big),
    PostgresOid.float4 => ByteData.sublistView(bytes).getFloat32(0, Endian.big),
    PostgresOid.float8 => ByteData.sublistView(bytes).getFloat64(0, Endian.big),
    PostgresOid.text ||
    PostgresOid.varchar ||
    PostgresOid.bpchar =>
      utf8.decode(bytes),
    PostgresOid.json => jsonDecode(utf8.decode(bytes)) as Object,
    PostgresOid.jsonb =>
      // 1-byte version prefix (always 0x01 today) followed by UTF-8 JSON.
      jsonDecode(utf8.decode(bytes.sublist(1))) as Object,
    // Owned copy — the zero-copy view becomes a dangling pointer the
    // moment `ResultSet.release()` runs, and callers cannot tell from
    // the API that holding the Uint8List past release is unsafe.
    // Matches the text-path semantics where `_decodeByteaHex` returns
    // a fresh Uint8List.
    PostgresOid.bytea => Uint8List.fromList(bytes),
    PostgresOid.timestamp ||
    PostgresOid.timestamptz =>
      _binaryToDateTime(bytes),
    PostgresOid.numeric => bytes, // not decoded — see docstring
    _ => bytes, // unknown OID → raw bytes
  };
}

/// Binary timestamp / timestamptz: int64 BE µs since Postgres epoch.
DateTime _binaryToDateTime(Uint8List bytes) {
  final pgMicros = ByteData.sublistView(bytes).getInt64(0, Endian.big);
  return DateTime.fromMicrosecondsSinceEpoch(
    pgMicros + _postgresEpochUnixMicros,
    isUtc: true,
  );
}
