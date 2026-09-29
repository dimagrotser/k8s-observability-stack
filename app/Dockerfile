# syntax=docker/dockerfile:1

# ---- deps ---------------------------------------------------------------
# Production dependencies only. Kept in a separate stage so the final image
# never contains npm, the lockfile tooling or the dev dependencies.
FROM node:24.12.0-alpine3.22 AS deps

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---- runtime ------------------------------------------------------------
# Distroless: no shell, no package manager, runs as uid 65532 by default.
# All dependencies are pure JavaScript, so there is nothing to compile here.
FROM gcr.io/distroless/nodejs24-debian12:nonroot AS runtime

WORKDIR /app
ENV NODE_ENV=production

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

EXPOSE 8080

# The distroless entrypoint is already /nodejs/bin/node.
CMD ["src/server.js"]
