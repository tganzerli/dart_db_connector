# benchmarks/http/python — FastAPI + uvicorn + asyncpg.
#
# Adjustments from https://hub.docker.com/_/python:
#   * Stay on `python:3.12-slim-bookworm` — asyncpg ships manylinux
#     wheels for arm64+amd64 (no compilation needed); the slim base
#     is enough.
#   * PYTHONDONTWRITEBYTECODE=1 — no .pyc on disk (saves ~5 MB,
#     irrelevant for cache since we don't restart).
#   * PYTHONUNBUFFERED=1 — stdout/stderr line-buffered so docker
#     compose logs streams without artificial lag.
#   * Pip cache via `--no-cache-dir` already in place.

FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY benchmarks/http/python/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY benchmarks/http/python/app.py ./

EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "warning", "--no-access-log"]
