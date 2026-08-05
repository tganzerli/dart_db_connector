-- TechEmpower benchmark schema (FrameworkBenchmarks-compatible).
--
-- Two tables:
--   * world(id int PK, randomnumber int) — 10 000 rows, random 1..10000.
--   * fortune(id int PK, message varchar(2048)) — 12 canonical rows from
--     the TechEmpower spec (https://github.com/TechEmpower/FrameworkBenchmarks
--     /tree/master/toolset/databases/postgres).
--
-- Seed is deterministic via setseed(0.42) — same data across runs makes
-- bench reps comparable.
--
-- Identifiers in lowercase per TechEmpower convention (Postgres folds
-- unquoted identifiers to lowercase anyway).
--
-- The `pg_stat_statements` extension is required for the Phase 3 bench
-- to instrument the Extended Protocol gap (see
-- [[cross-cutting/parameter-binding-gap-analysis]] §5). The Postgres
-- container loads it via `shared_preload_libraries`; here we just
-- CREATE EXTENSION so the catalog has it ready.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

DROP TABLE IF EXISTS world CASCADE;
DROP TABLE IF EXISTS fortune CASCADE;

CREATE TABLE world (
  id            int4 PRIMARY KEY,
  randomnumber  int4 NOT NULL
);

CREATE TABLE fortune (
  id       int4 PRIMARY KEY,
  message  varchar(2048) NOT NULL
);

-- World: 10 000 rows, randomnumber ∈ [1, 10000].
-- setseed makes the random() sequence reproducible across runs.
SELECT setseed(0.42);
INSERT INTO world (id, randomnumber)
SELECT i, (random() * 9999 + 1)::int4
FROM generate_series(1, 10000) AS i;

-- Fortune: 12 canonical messages from the TechEmpower toolset.
INSERT INTO fortune (id, message) VALUES
  (1,  'fortune: No such file or directory'),
  (2,  'A computer scientist is someone who fixes things that aren''t broken.'),
  (3,  'After enough decimal places, nobody gives a damn.'),
  (4,  'A bad random number generator: 1, 1, 1, 1, 1, 4.33e+67, 1, 1, 1'),
  (5,  'A computer program does what you tell it to do, not what you want it to do.'),
  (6,  'Emacs is a nice operating system, but I prefer UNIX. — Tom Christaensen'),
  (7,  'Any program that runs right is obsolete.'),
  (8,  'A list is only as strong as its weakest link. — Donald Knuth'),
  (9,  'Feature: A bug with seniority.'),
  (10, 'Computers make very fast, very accurate mistakes.'),
  (11, '<script>alert("This should not be displayed in a browser alert box.");</script>'),
  (12, 'フレームワークのベンチマーク');

-- Sanity counters (visible in the seed log).
SELECT 'world' AS table_name, count(*) AS rows FROM world
UNION ALL
SELECT 'fortune', count(*) FROM fortune;

-- Index on world(id) is the PK already; no extra index — TechEmpower
-- doesn't require any.
