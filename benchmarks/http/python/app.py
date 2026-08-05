"""Phase 3 HTTP server — Python (FastAPI + uvicorn) + asyncpg."""

from __future__ import annotations

import asyncio
import os
import random
from contextlib import asynccontextmanager
from html import escape as html_escape

import asyncpg
from fastapi import FastAPI, Query
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

WORLD_ROWS = 10_000
POOL_SIZE = int(os.environ.get("POOL_SIZE", "64"))

pool: asyncpg.Pool | None = None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(
        host=os.environ.get("POSTGRES_HOST", "postgres"),
        port=int(os.environ.get("POSTGRES_PORT", "5432")),
        database=os.environ.get("POSTGRES_DB", "teste"),
        user=os.environ.get("POSTGRES_USER", "postgres"),
        password=os.environ.get("POSTGRES_PASSWORD", "123"),
        min_size=POOL_SIZE,
        max_size=POOL_SIZE,
    )
    print(f"[python] pool ready (size={POOL_SIZE})", flush=True)
    yield
    if pool is not None:
        await pool.close()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/plaintext", response_class=PlainTextResponse)
async def plaintext() -> str:
    return "Hello, World!"


@app.get("/json")
async def json_hello() -> dict:
    return {"message": "Hello, World!"}


@app.get("/db")
async def db_handler() -> dict:
    assert pool is not None
    row = await _select_world(random.randint(1, WORLD_ROWS))
    return row


@app.get("/queries")
async def queries_handler(count: str | None = Query(default=None)) -> list[dict]:
    n = _clamp_count(count)
    tasks = [
        _select_world(random.randint(1, WORLD_ROWS)) for _ in range(n)
    ]
    return await asyncio.gather(*tasks)


@app.get("/updates")
async def updates_handler(count: str | None = Query(default=None)) -> list[dict]:
    n = _clamp_count(count)

    async def _one() -> dict:
        id_ = random.randint(1, WORLD_ROWS)
        new_rand = random.randint(1, WORLD_ROWS)
        await _update_world(id_, new_rand)
        return {"id": id_, "randomNumber": new_rand}

    return await asyncio.gather(*[_one() for _ in range(n)])


@app.get("/fortunes", response_class=HTMLResponse)
async def fortunes_handler() -> str:
    assert pool is not None
    async with pool.acquire() as conn:
        rows = await conn.fetch("SELECT id, message FROM fortune")
    fortunes = [{"id": r["id"], "message": r["message"]} for r in rows]
    fortunes.append({"id": 0, "message": "Additional fortune added at request time."})
    fortunes.sort(key=lambda f: f["message"])
    parts = [
        '<!DOCTYPE html><html><head><title>Fortunes</title></head><body>',
        '<table><tr><th>id</th><th>message</th></tr>',
    ]
    for f in fortunes:
        parts.append(f'<tr><td>{f["id"]}</td><td>{html_escape(f["message"], quote=True)}</td></tr>')
    parts.append('</table></body></html>')
    return "".join(parts)


async def _select_world(id_: int) -> dict:
    assert pool is not None
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, randomnumber FROM world WHERE id = $1", id_
        )
    return {"id": row["id"], "randomNumber": row["randomnumber"]}


async def _update_world(id_: int, new_rand: int) -> None:
    assert pool is not None
    async with pool.acquire() as conn:
        async with conn.transaction():
            await conn.fetchrow(
                "SELECT id, randomnumber FROM world WHERE id = $1", id_
            )
            await conn.execute(
                "UPDATE world SET randomnumber = $1 WHERE id = $2", new_rand, id_
            )


def _clamp_count(raw: str | None) -> int:
    try:
        v = int(raw) if raw is not None else 1
    except ValueError:
        v = 1
    if v < 1:
        return 1
    if v > 500:
        return 500
    return v
