-- TechEmpower schema for MySQL (mirrors the PostgreSQL fixture).
-- Deterministic (fixed seed) so repetitions stay comparable.
--   world(id PK, randomnumber)  — 10 000 linhas, randomnumber ∈ [1,10000]
--   fortune(id PK, message)     — 12 linhas canônicas TechEmpower
DROP TABLE IF EXISTS world;
DROP TABLE IF EXISTS fortune;

CREATE TABLE world (
  id           INT PRIMARY KEY,
  randomnumber INT NOT NULL
);
CREATE TABLE fortune (
  id      INT PRIMARY KEY,
  message VARCHAR(2048) NOT NULL
);

-- World: 10 000 linhas via CTE recursiva (MySQL 8). RAND(42) = seed fixo.
-- cte_max_recursion_depth default = 1000; a recursão vai a 10 000, então eleva.
SET SESSION cte_max_recursion_depth = 20000;
INSERT INTO world (id, randomnumber)
WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 10000
)
SELECT n, FLOOR(RAND(42 + n) * 9999 + 1) FROM seq;

INSERT INTO fortune (id, message) VALUES
  (1,'fortune: No such file or directory'),
  (2,'A computer scientist is someone who fixes things that aren''t broken.'),
  (3,'After enough decimal places, nobody gives a damn.'),
  (4,'A bad random number generator: 1, 1, 1, 1, 1, 4.33e+67, 1, 1, 1'),
  (5,'A computer program does what you tell it to do, not what you want it to do.'),
  (6,'Emacs is a nice operating system, but I prefer UNIX. — Tom Christiansen'),
  (7,'Any program that runs right is obsolete.'),
  (8,'A list is only as strong as its weakest link. — Donald Knuth'),
  (9,'Feature: A bug with seniority.'),
  (10,'Computers make very fast, very accurate mistakes.'),
  (11,'<script>alert("This should not be displayed in a browser alert box.");</script>'),
  (12,'フレームワークのベンチマーク');
