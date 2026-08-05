/// Domain-pure repository interface.
///
/// A [Repository] knows nothing about SQL, FFI, or Postgres. It exposes a
/// minimal CRUD surface in terms of a domain entity [T] and its primary
/// key [K]. Concrete persistence implementations (see `postgres_repository.dart`)
/// translate these calls into SQL via a [QueryExecutor].
library;

/// Domain-pure CRUD contract over an entity [T] keyed by [K].
///
/// Knows nothing about SQL, FFI, or PostgreSQL. Concrete implementations
/// (see [PostgresRepository]) translate the calls into SQL through a
/// [QueryExecutor] obtained from an active [UnitOfWork]. Use this
/// interface to swap implementations in tests (in-memory fakes) without
/// touching domain code.
///
/// Example:
/// ```dart
/// class UserRepository extends PostgresRepository<User, int>
///     implements Repository<User, int> { /* SQL overrides */ }
/// ```
abstract interface class Repository<T, K> {
  /// Returns the entity with primary key [id], or `null` if not found.
  Future<T?> findById(K id);

  /// Returns all entities. No pagination, no ordering guarantees beyond
  /// what the concrete implementation enforces in its SQL.
  Future<List<T>> findAll();

  /// Persists [entity]. Behaviour on duplicate key is delegated to the
  /// concrete implementation (typically a SQL error surfaced as
  /// `QueryFailedException`).
  Future<void> insert(T entity);

  /// Updates the persisted state of [entity] matching its primary key.
  Future<void> update(T entity);

  /// Deletes the entity with primary key [id].
  Future<void> delete(K id);
}
