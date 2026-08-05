#!/usr/bin/env bash
# FUNCTIONAL smoke test, NOT a benchmark. Verifies that an HTTP server builds,
# starts, connects to its database and answers CORRECTLY on every endpoint.
# Low-capacity hardware is fine: it measures correctness, not performance, and
# produces no benchmark numbers.
#
# Uso: cd <repo-root> && bash bench/http/smoke-1b.sh <stack>
#   stacks mysql:  dart-native-mysql, dart-pkg-mysql, go-mysql
#   stacks mongo:  dart-native-mongo, dart-pkg-mongo, go-mongo
# A família (mysql|mongo) é derivada do nome do stack.
# Escreve resultado em: bench/http/smoke-1b-results.md  (commitável).
set -uo pipefail
STACK="${1:-dart-native-mysql}"
case "$STACK" in
  *mongo*) FAMILY=mongo ;;
  *mysql*) FAMILY=mysql ;;
  *) echo "stack desconhecido: $STACK (esperado *-mysql ou *-mongo)"; exit 2 ;;
esac
NET=ddc-smoke-smoke-net
IMG="ddc-smoke-${STACK}"
RESULTS="bench/http/smoke-1b-results.md"
PASS=0; FAIL=0
say(){ echo "[smoke:$STACK] $*"; }
result(){ echo "$1" >> "$RESULTS"; }

cd "$(git rev-parse --show-toplevel)" || exit 2
: > "$RESULTS"
result "# HTTP MySQL/MongoDB benchmark smoke — $STACK ($FAMILY) — $(date -u +%FT%TZ)"
result ""
result "> FUNCTIONAL check (build + endpoint correctness), not a benchmark. Host: \$(uname -m)."
result ""

cleanup(){ docker rm -f ddc-smoke-db ddc-smoke-server >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null 2>&1 || true

# 1) Build
say "build da imagem ..."
if docker build -f "bench/http/${STACK}/Dockerfile" -t "$IMG" . > /tmp/${STACK}_build.log 2>&1; then
  result "- [x] **build**: OK"; PASS=$((PASS+1))
else
  result "- [ ] **build**: FALHOU (últimas linhas abaixo)"; FAIL=$((FAIL+1))
  result '```'; tail -25 /tmp/${STACK}_build.log >> "$RESULTS"; result '```'
  say "build falhou — abortando"; exit 1
fi

# 2) DB fresh + 3) seed  (por família)
if [ "$FAMILY" = mysql ]; then
  say "subindo mysql ..."
  docker run -d --name ddc-smoke-db --network "$NET" \
    -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=teste -e MYSQL_USER=bench -e MYSQL_PASSWORD=123 \
    mysql:8.4 --mysql-native-password=ON --authentication-policy=mysql_native_password >/dev/null 2>&1
  for i in $(seq 1 60); do
    docker exec ddc-smoke-db mysqladmin ping -uroot -proot --silent >/dev/null 2>&1 && break
    sleep 2
  done
  say "seed schema_mysql.sql ..."
  if docker exec -i ddc-smoke-db sh -c 'mysql -ubench -p123 teste' < bench/http/schema_mysql.sql >/tmp/seed.log 2>&1; then
    result "- [x] **seed**: OK (world 10k + fortune)"; PASS=$((PASS+1))
  else
    result "- [ ] **seed**: FALHOU"; FAIL=$((FAIL+1)); result '```'; tail -15 /tmp/seed.log >> "$RESULTS"; result '```'
  fi
  SRV_ENV="-e MYSQL_HOST=ddc-smoke-db -e MYSQL_USER=bench -e MYSQL_PASSWORD=123 -e MYSQL_DB=teste -e POOL_SIZE=8"
else
  say "subindo mongo ..."
  docker run -d --name ddc-smoke-db --network "$NET" mongo:7 >/dev/null 2>&1
  for i in $(seq 1 60); do
    docker exec ddc-smoke-db mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break
    sleep 2
  done
  say "seed seed_mongo.js ..."
  if docker exec -i ddc-smoke-db mongosh --quiet "mongodb://127.0.0.1:27017/teste" < bench/http/seed_mongo.js >/tmp/seed.log 2>&1; then
    result "- [x] **seed**: OK (world 10k + fortune)"; PASS=$((PASS+1))
  else
    result "- [ ] **seed**: FALHOU"; FAIL=$((FAIL+1)); result '```'; tail -15 /tmp/seed.log >> "$RESULTS"; result '```'
  fi
  SRV_ENV="-e MONGO_URI=mongodb://ddc-smoke-db:27017 -e POOL_SIZE=8"
fi

# 4) sobe o servidor
say "subindo $STACK ..."
docker run -d --name ddc-smoke-server --network "$NET" $SRV_ENV -p 18080:8080 "$IMG" >/dev/null 2>&1
ready=0
for i in $(seq 1 45); do
  docker run --rm --network "$NET" curlimages/curl:latest -sf --max-time 1 http://ddc-smoke-server:8080/plaintext >/dev/null 2>&1 && { ready=1; break; }
  sleep 1
done
if [ "$ready" = 1 ]; then result "- [x] **server up + /plaintext 200**: OK"; PASS=$((PASS+1))
else
  result "- [ ] **server up**: FAILED (no response on /plaintext)"; FAIL=$((FAIL+1))
  result '```'; docker logs ddc-smoke-server 2>&1 | tail -25 >> "$RESULTS"; result '```'
  say "server did not come up; aborting endpoint checks"; exit 1
fi

# 5) endpoints DB-backed — checa 200 + corpo plausível
check(){ # nome, path, grep-pattern
  local name="$1" path="$2" pat="$3"
  local body; body=$(docker run --rm --network "$NET" curlimages/curl:latest -s --max-time 5 "http://ddc-smoke-server:8080${path}" 2>/dev/null)
  if echo "$body" | grep -qE "$pat"; then
    result "- [x] **$name** (\`$path\`): OK — \`$(echo "$body" | head -c 80)\`"; PASS=$((PASS+1))
  else
    result "- [ ] **$name** (\`$path\`): FALHOU — corpo: \`$(echo "$body" | head -c 120)\`"; FAIL=$((FAIL+1))
  fi
}
check "db" "/db" '"randomNumber"'
check "queries" "/queries?count=5" '"randomNumber".*"randomNumber"'
check "updates" "/updates?count=5" '"randomNumber"'
check "fortunes" "/fortunes" '<table>.*fortune'

result ""
result "## Resumo: ${PASS} PASS / ${FAIL} FAIL"
say "==> ${PASS} PASS / ${FAIL} FAIL (detalhe em $RESULTS)"
[ "$FAIL" -eq 0 ]
