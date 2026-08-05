/// Result and error types for the MongoDB bulk write path (F1-Mongo, ABI
/// MINOR 1.1). A successful [MongoCollection.insertMany] returns a
/// [BulkWriteResult]; a partial or total failure throws a
/// [MongoBulkWriteException] carrying the real per-index write errors from
/// libmongoc (`writeErrors[]`) plus how many documents were inserted.
library;

/// Outcome of a successful bulk insert.
class BulkWriteResult {
  /// Number of documents the server acknowledged as inserted.
  final int insertedCount;

  const BulkWriteResult({required this.insertedCount});

  @override
  String toString() => 'BulkWriteResult(insertedCount: $insertedCount)';
}

/// One per-index failure reported by the server in a bulk insert reply
/// (`writeErrors[]`). [index] is the position of the offending document in
/// the batch as submitted; [code] and [message] are the real libmongoc
/// values (e.g. code 11000, "E11000 duplicate key error").
class BulkWriteError {
  final int index;
  final int code;
  final String message;

  const BulkWriteError(this.index, this.code, this.message);

  @override
  String toString() => 'BulkWriteError(index: $index, code: $code, $message)';
}

/// Thrown when a bulk insert fails wholly or partially. Carries the real
/// libmongoc [message]/[code], the [insertedCount] that still succeeded
/// (relevant for unordered inserts, where the batch continues past errors),
/// and the per-index [writeErrors].
class MongoBulkWriteException implements Exception {
  final String message;
  final int code;
  final int insertedCount;
  final List<BulkWriteError> writeErrors;

  MongoBulkWriteException(
    this.message, {
    required this.code,
    required this.insertedCount,
    required this.writeErrors,
  });

  @override
  String toString() {
    final head = 'MongoBulkWriteException($code): $message '
        '(insertedCount: $insertedCount, ${writeErrors.length} write error(s))';
    if (writeErrors.isEmpty) return head;
    final sample = writeErrors.take(3).join('; ');
    final more = writeErrors.length > 3 ? ' …' : '';
    return '$head [$sample$more]';
  }
}
