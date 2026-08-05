# benchmarks/http/node — fastify + postgres.js.
#
# Adjustments from https://hub.docker.com/_/node:
#   * `npm ci` (deterministic install from package-lock.json) instead
#     of `npm install` — official Node Docker guidance.
#   * NODE_ENV=production so fastify/postgres.js take the production
#     code paths (cached error stacks, faster JSON serialization).
#   * Cache `node_modules` layer by copying package*.json first.

FROM node:22-bookworm-slim

ENV NODE_ENV=production
WORKDIR /app

COPY benchmarks/http/node/package.json benchmarks/http/node/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

COPY benchmarks/http/node/server.js ./

EXPOSE 8080
CMD ["node", "--max-old-space-size=2048", "server.js"]
