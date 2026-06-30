# Dockerfile & Compose Template Library

Copy-pasteable, production-grade templates. All use `# syntax=docker/dockerfile:1` (latest stable frontend), multi-stage builds, BuildKit cache mounts, non-root users, and exec-form entrypoints. Pin base images by digest in real pipelines.

---

## Go — static binary into distroless (smallest)

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
```

## Node.js — slim, non-root, healthcheck

```dockerfile
# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev

FROM node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.js"]
```

### TypeScript variant (build step)
```dockerfile
# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package*.json tsconfig.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY src ./src
RUN npm run build               # → dist/

FROM node:22-bookworm-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev

FROM node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist         ./dist
USER node
CMD ["node", "dist/server.js"]
```

## Python — slim, non-root, prefix-installed deps

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.12-slim AS build
ENV PIP_NO_CACHE_DIR=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 10001 appuser
COPY --from=build /install /usr/local
WORKDIR /app
COPY . .
USER appuser
EXPOSE 8000
ENTRYPOINT ["python", "-m", "myapp"]
```

### Python with uv (fast, lockfile-based)
```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.12-slim AS build
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev
COPY . .

FROM python:3.12-slim
RUN useradd --uid 10001 appuser
COPY --from=build /app /app
WORKDIR /app
ENV PATH="/app/.venv/bin:$PATH"
USER appuser
ENTRYPOINT ["python", "-m", "myapp"]
```

## Java — JLink/Spring Boot layered jar

```dockerfile
# syntax=docker/dockerfile:1
FROM eclipse-temurin:21-jdk AS build
WORKDIR /app
COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN --mount=type=cache,target=/root/.m2 ./mvnw -q dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -q -DskipTests package
RUN java -Djarmode=layertools -jar target/*.jar extract --destination /layers

FROM eclipse-temurin:21-jre AS runtime
WORKDIR /app
RUN useradd --uid 10001 spring
COPY --from=build /layers/dependencies/         ./
COPY --from=build /layers/spring-boot-loader/   ./
COPY --from=build /layers/snapshot-dependencies/ ./
COPY --from=build /layers/application/          ./
USER spring
EXPOSE 8080
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
```
The four `COPY` of layers (deps before app) means a code change only rebuilds the small application layer, not the dependency layer.

## Static site / SPA → nginx

```dockerfile
# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build               # → /app/dist

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
# nginx image already has a sane entrypoint; runs as root master + non-root workers
```

---

## Wrapper entrypoint with `exec` (clean signals)

When you genuinely need a startup script, end it with `exec` so your app *replaces* the shell and becomes PID 1:
```sh
#!/bin/sh
set -e
# ... setup: wait for db, run migrations, template config ...
exec "$@"          # replaces shell with CMD; PID 1 is now the app
```
```dockerfile
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "server.js"]
```

---

## Compose for local dev (`compose.yaml`)

```yaml
services:
  api:
    build:
      context: .
      target: runtime
      args:
        NODE_ENV: development
    ports: ["3000:3000"]
    environment:
      DATABASE_URL: postgres://app:app@db:5432/app
      REDIS_URL: redis://cache:6379
    depends_on:
      db:    { condition: service_healthy }
      cache: { condition: service_started }
    develop:
      watch:
        - { action: sync,    path: ./src,          target: /app/src }
        - { action: rebuild, path: ./package.json }
    restart: unless-stopped

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: app
    volumes: ["pgdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 5s
      timeout: 3s
      retries: 5

  cache:
    image: redis:7-alpine
    command: ["redis-server", "--save", "", "--appendonly", "no"]

volumes:
  pgdata:
```

Run:
```bash
docker compose up --build --watch     # hot reload via develop.watch
docker compose logs -f api
docker compose exec db psql -U app
docker compose down -v                # stop + remove named volumes
```

### Override pattern
`compose.yaml` (shared) + `compose.override.yaml` (auto-merged locally) for dev-only ports/mounts; in CI use `docker compose -f compose.yaml -f compose.ci.yaml`.

---

## `.dockerignore` baselines

**Node:**
```gitignore
.git
node_modules
npm-debug.log
dist
coverage
.env*
Dockerfile*
docker-compose*.yml
compose*.yaml
.dockerignore
**/.DS_Store
```
**Python:**
```gitignore
.git
__pycache__
*.pyc
.venv
.pytest_cache
.mypy_cache
dist
build
*.egg-info
.env*
```
**Go:**
```gitignore
.git
bin
*.test
*.out
vendor          # unless you commit vendored deps intentionally
.env*
```
