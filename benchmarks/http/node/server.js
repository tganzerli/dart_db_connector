// Phase 3 HTTP server — Node.js (fastify) + postgres.js.

import Fastify from 'fastify';
import postgres from 'postgres';

const WORLD_ROWS = 10000;
const POOL_SIZE = Number(process.env.POOL_SIZE ?? 64);

const sql = postgres({
  host: process.env.POSTGRES_HOST ?? 'postgres',
  port: Number(process.env.POSTGRES_PORT ?? 5432),
  database: process.env.POSTGRES_DB ?? 'teste',
  username: process.env.POSTGRES_USER ?? 'postgres',
  password: process.env.POSTGRES_PASSWORD ?? '123',
  max: POOL_SIZE,
  ssl: false,
  // Match other stacks: keep connections warm; no idle timeout.
  idle_timeout: 0,
});

console.log(`[node] pool ready (max=${POOL_SIZE})`);

const app = Fastify({ logger: false, disableRequestLogging: true });

app.get('/plaintext', async (_req, reply) => {
  reply.header('content-type', 'text/plain; charset=utf-8').send('Hello, World!');
});

app.get('/json', async () => ({ message: 'Hello, World!' }));

app.get('/db', async () => {
  const id = randInt(WORLD_ROWS) + 1;
  const [row] = await sql`SELECT id, randomnumber FROM world WHERE id = ${id}`;
  return { id: row.id, randomNumber: row.randomnumber };
});

app.get('/queries', async (req) => {
  const count = clampCount(req.query.count);
  const rows = await Promise.all(
    Array.from({ length: count }, async () => {
      const id = randInt(WORLD_ROWS) + 1;
      const [row] = await sql`SELECT id, randomnumber FROM world WHERE id = ${id}`;
      return { id: row.id, randomNumber: row.randomnumber };
    }),
  );
  return rows;
});

app.get('/updates', async (req) => {
  const count = clampCount(req.query.count);
  const rows = await Promise.all(
    Array.from({ length: count }, async () => {
      const id = randInt(WORLD_ROWS) + 1;
      const newRand = randInt(WORLD_ROWS) + 1;
      await sql.begin(async (tx) => {
        await tx`SELECT id, randomnumber FROM world WHERE id = ${id}`;
        await tx`UPDATE world SET randomnumber = ${newRand} WHERE id = ${id}`;
      });
      return { id, randomNumber: newRand };
    }),
  );
  return rows;
});

app.get('/fortunes', async (_req, reply) => {
  const rows = await sql`SELECT id, message FROM fortune`;
  const fortunes = rows.map((r) => ({ id: r.id, message: r.message }));
  fortunes.push({ id: 0, message: 'Additional fortune added at request time.' });
  fortunes.sort((a, b) => a.message.localeCompare(b.message));
  let html = '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>';
  for (const f of fortunes) {
    html += `<tr><td>${f.id}</td><td>${htmlEscape(f.message)}</td></tr>`;
  }
  html += '</table></body></html>';
  reply.header('content-type', 'text/html; charset=utf-8').send(html);
});

function randInt(max) {
  return Math.floor(Math.random() * max);
}

function clampCount(raw) {
  const v = Number(raw);
  if (!Number.isFinite(v) || v < 1) return 1;
  if (v > 500) return 500;
  return v | 0;
}

function htmlEscape(s) {
  return String(s)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

try {
  await app.listen({ host: '0.0.0.0', port: 8080 });
  console.log('[node] listening on http://0.0.0.0:8080');
} catch (err) {
  console.error(err);
  process.exit(1);
}
