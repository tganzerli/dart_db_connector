/// Decoders from raw MySQL text-protocol bytes to Dart values.
///
/// Internal — consumed by [MysqlResultRow]. MySQL's text protocol
/// (`mysql_store_result`) returns every value as ASCII text, exactly like
/// libpq text-mode, so this mirrors `decodeByOid` in `_decoder.dart`.
///
/// v1 limitations (documented for honesty):
///   - `TEXT` columns report as blob-family type codes and are returned as
///     raw `Uint8List` (the field type alone cannot distinguish TEXT from
///     binary BLOB without the charset number, not exposed by the ABI).
///     `VARCHAR`/`CHAR` (var_string/string codes) decode to `String`.
///   - `DECIMAL` decodes to `double` (loses exactness for very large
///     scales); select `CAST(col AS CHAR)` when exact decimals are needed.
library;

import 'dart:convert' show utf8, jsonDecode;
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'mysql_field_types.dart';
import 'mysql_type.dart';

/// Decodes [bytes] (MySQL text protocol) into a Dart value according to
/// the `enum_field_types` [code].
Object decodeByFieldType(Uint8List bytes, int code) {
  return switch (code) {
    MysqlFieldType.tiny ||
    MysqlFieldType.short ||
    MysqlFieldType.int24 ||
    MysqlFieldType.long ||
    MysqlFieldType.longLong ||
    MysqlFieldType.year =>
      int.parse(_asciiString(bytes)),
    MysqlFieldType.float ||
    MysqlFieldType.double_ ||
    MysqlFieldType.decimal ||
    MysqlFieldType.newDecimal =>
      double.parse(_asciiString(bytes)),
    MysqlFieldType.varchar ||
    MysqlFieldType.varString ||
    MysqlFieldType.string ||
    MysqlFieldType.enum_ ||
    MysqlFieldType.set =>
      utf8.decode(bytes),
    MysqlFieldType.json => jsonDecode(utf8.decode(bytes)) as Object,
    MysqlFieldType.date ||
    MysqlFieldType.datetime ||
    MysqlFieldType.timestamp =>
      _parseMysqlDateTime(_asciiString(bytes)),
    MysqlFieldType.time => _asciiString(bytes), // may exceed 24h — keep String
    MysqlFieldType.tinyBlob ||
    MysqlFieldType.mediumBlob ||
    MysqlFieldType.longBlob ||
    MysqlFieldType.blob ||
    MysqlFieldType.bit ||
    MysqlFieldType.geometry =>
      Uint8List.fromList(bytes),
    _ => bytes, // unknown code → raw bytes
  };
}

/// Fast path for ASCII-only payloads (numbers, dates in text mode).
String _asciiString(Uint8List bytes) => String.fromCharCodes(bytes);

/// Parses MySQL text-mode date/datetime/timestamp.
///   - `DATE`:      `2026-07-24`
///   - `DATETIME`:  `2026-07-24 13:45:00[.ffffff]`
/// MySQL returns no timezone; the resulting [DateTime] is local-naive.
DateTime _parseMysqlDateTime(String s) {
  final iso = s.replaceFirst(' ', 'T');
  return DateTime.parse(iso);
}

/// Decoded type tag for diagnostics / [MysqlResultSet.typeOf].
MysqlType decodedTypeForCode(int code) => mysqlTypeFromCode(code);

// ─────────────────────────────────────────────────────────────────────
// Codec-plan decoders (mirror of `_decoder.dart`'s `textDecoderForOid`).
//
// `mysqlTextDecoderForCode` resolves the `enum_field_types` switch ONCE
// per result shape (the plan caches the returned closure), so the per-cell
// hot path no longer branches on the type code. Non-int codes delegate to
// the canonical [decodeByFieldType] via `asTypedList`, keeping a single
// source of truth for decode semantics.
// ─────────────────────────────────────────────────────────────────────

/// Per-column decoder over a native pointer + length. The signature names
/// no MySQL type — same shape as the Postgres [CellDecoder].
typedef MysqlCellDecoder = Object? Function(
    ffi.Pointer<ffi.Uint8> ptr, int len);

/// Resolves the [MysqlCellDecoder] for a text-protocol column of the given
/// `enum_field_types` [code]. Called once per result shape by the codec plan.
///
/// The direct int-from-pointer parser (A4) is applied only to the integer
/// codes that are **always** within Dart's signed 64-bit range
/// (`tiny`/`short`/`int24`/`long`/`year`). `longLong` is deliberately left
/// on the canonical String path: `BIGINT UNSIGNED` can exceed 2^63-1 and the
/// ABI's `fieldType` does not expose the UNSIGNED flag, so the pointer parser
/// (which wraps on overflow) could diverge from `int.parse`. Delegating keeps
/// semantics byte-identical to the pre-plan path.
MysqlCellDecoder mysqlTextDecoderForCode(int code) => switch (code) {
      MysqlFieldType.tiny ||
      MysqlFieldType.short ||
      MysqlFieldType.int24 ||
      MysqlFieldType.long ||
      MysqlFieldType.year =>
        _decodeIntTextPtr,
      // BIGINT: fast path only when the magnitude cannot overflow int64
      // (≤18 digits always fits); wider values (e.g. BIGINT UNSIGNED) fall
      // back to int.parse, so semantics match the pre-plan path exactly.
      MysqlFieldType.longLong => _decodeBigIntTextPtr,
      MysqlFieldType.float ||
      MysqlFieldType.double_ ||
      MysqlFieldType.decimal ||
      MysqlFieldType.newDecimal =>
        _decodeDoublePtr,
      MysqlFieldType.varchar ||
      MysqlFieldType.varString ||
      MysqlFieldType.string ||
      MysqlFieldType.enum_ ||
      MysqlFieldType.set =>
        _decodeUtf8Ptr,
      // Cold/rare codes (longLong, json, date/time, blob/bit/geometry,
      // unknown) delegate to the canonical decoder — resolved once per plan
      // (A2), same semantics. longLong stays here on purpose (see below).
      _ => (ptr, len) => decodeByFieldType(ptr.asTypedList(len), code),
    };

/// Text-mode `VARCHAR`/`CHAR`/`ENUM`/`SET` → `String`. Resolved once per
/// plan so the per-cell path skips the type switch.
Object _decodeUtf8Ptr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    utf8.decode(ptr.asTypedList(len));

/// Text-mode `FLOAT`/`DOUBLE`/`DECIMAL` → `double` (same `double.parse` over
/// ASCII the canonical path uses; only the type switch is removed).
Object _decodeDoublePtr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    double.parse(_asciiString(ptr.asTypedList(len)));

/// A4: parses a text-mode integer straight from the native pointer — no
/// `asTypedList` wrapper, no intermediate `String`. Reads bytes with
/// `ptr[i]` (a memory load, not an FFI call). On any byte outside `[-+0-9]`
/// it falls back to the String path, so semantics can only match
/// [decodeByFieldType], never diverge. Applied only to codes bounded by
/// int64 (see [mysqlTextDecoderForCode]), so wraparound cannot occur.
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
    int.parse(_asciiString(ptr.asTypedList(len)));

/// A4 for `BIGINT`. A magnitude of ≤18 decimal digits always fits in a
/// signed int64 (`10^18 - 1 < 2^63 - 1`), so the direct pointer parser is
/// safe; 19+ digits (only reachable via `BIGINT UNSIGNED`, whose flag the
/// ABI hides) fall back to [int.parse] — identical to the pre-plan path.
Object _decodeBigIntTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) {
  final signLen = (len > 0 && (ptr[0] == 0x2D || ptr[0] == 0x2B)) ? 1 : 0;
  if (len - signLen > 18) return _intFallback(ptr, len);
  return _decodeIntTextPtr(ptr, len);
}
