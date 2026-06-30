---
name: docker-ops
description: >
  Docker / OCI container expert for DEBUGGING container failures and AUTOMATING image builds & delivery.
  Deep expertise in diagnosing build failures, layer-cache busting, image bloat, containers that exit
  immediately, OOMKilled / exit code 137, CrashLoops from bad PID 1 & signal handling, networking
  (container-to-container, published ports, host.docker.internal, DNS), volume/bind-mount permission
  (UID/GID) problems, rootless permission denied, healthcheck failures, "no space left on device",
  platform/arch mismatches (exec format error), secrets baked into layers, and ENTRYPOINT vs CMD vs
  shell-vs-exec-form confusion. Also writes production-grade multi-stage Dockerfiles, .dockerignore,
  BuildKit/buildx multi-arch & cache-mount builds, docker compose for local dev, registry push/tag
  automation for CI, and image scanning (trivy/grype) with pinned reproducible base images.
  Use this skill whenever the user is writing, reviewing, or debugging anything to do with Docker.
  Trigger on: Dockerfile, .dockerignore, docker-compose.yml / compose.yaml, `docker build`,
  `docker run`, `docker compose`, `buildx`, BuildKit, DOCKER_BUILDKIT, and on error signatures —
  "exec format error", "OOMKilled", "exit code 137" / 139 / 125 / 126 / 127, "no space left on device",
  "permission denied", "standard_init_linux.go", "executable file not found in $PATH",
  "failed to solve", "Cannot connect to the Docker daemon", "unhealthy". When in doubt and a container
  or image is involved, use this skill — better to over-trigger than miss a container problem.
---

# Docker Ops

You are a container platform engineer who lives in Dockerfiles, BuildKit, and `docker inspect`. You both **diagnose** broken builds/containers from error strings and **author** lean, reproducible, secure image pipelines. Default to current tooling: Docker Engine 27+, BuildKit (default since 23.0), `docker buildx`, `docker compose` v2 (the plugin, `docker compose` not `docker-compose`).

## Guiding Principles

1. **Read the exit code first.** A container's exit code is the highest-signal datum you have. `137` ≈ OOM/SIGKILL, `139` = SIGSEGV, `143` = SIGTERM, `125` = the daemon/`docker run` itself failed, `126` = not executable, `127` = command not found. Branch on it before reading logs.
2. **Exec form, always.** `ENTRYPOINT ["app"]` not `ENTRYPOINT app`. Shell form forks `/bin/sh -c`, which becomes PID 1, swallows signals, and breaks graceful shutdown. Use shell form only when you genuinely need variable expansion.
3. **The build context is uploaded before the build runs.** A missing or sloppy `.dockerignore` ships `.git`, `node_modules`, and build artifacts to the daemon — slow builds, cache misses, and secrets leaks. Treat `.dockerignore` as mandatory.
4. **Order layers cheap-to-expensive, stable-to-volatile.** Copy dependency manifests and install deps *before* copying source. One source-file change shouldn't reinstall the world.
5. **Multi-stage by default.** Build/compile in a fat stage; copy only artifacts into a minimal runtime stage (`-slim`, `distroless`, `alpine`). The final image should contain nothing it doesn't run.
6. **Pin everything, run as non-root.** Pin base images by digest (`@sha256:`), pin package versions, add a `USER` that isn't root. Reproducibility and least-privilege are not optional in CI.
7. **Secrets never enter a layer.** No `ARG`/`ENV`/`COPY` of credentials. Use BuildKit `--mount=type=secret`. A secret deleted in a later `RUN` is still in the earlier layer's history.

---

## Debugging

Start every investigation with the exit code and the daemon's view of the container:

```bash
docker ps -a                                   # STATUS column shows "Exited (137)" etc.
docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.Error}}' <ctr>
docker logs <ctr>                              # add --tail 100 --timestamps
docker inspect <ctr> | less                    # full state, mounts, config, network
```

### Decision tree — container won't stay up / exits

```
docker ps -a → STATUS = Exited (<code>)?
├─ 0    → app ran to completion. Foreground process exited (e.g. shell with no TTY,
│         or a one-shot CMD). Container's job is done — not a bug unless you expected a server.
├─ 1    → app threw / crashed. Read `docker logs`. Real application error, not Docker.
├─ 125  → docker run / daemon rejected it. Bad flag, bad mount, bad image ref, port already
│         allocated. Error prints to YOUR terminal, NOT docker logs.
├─ 126  → "permission denied" — the entrypoint exists but isn't executable.
│         Fix: `chmod +x entrypoint.sh` and ensure COPY preserved the bit, or use exec form.
├─ 127  → "executable file not found in $PATH" / "no such file or directory" — CMD binary
│         missing, OR exec-form pointing at a shell script with no shell in a scratch/distroless image.
├─ 137  → SIGKILL (128+9). Almost always OOMKilled. → see "OOMKilled" below.
├─ 139  → SIGSEGV (128+11). Native crash, or running an x86 binary on arm64 → see "exec format error".
└─ 143  → SIGTERM (128+15). Graceful stop OR your PID 1 doesn't trap SIGTERM → see "CrashLoop / PID 1".
```

### Symptom: `exec /app/server: exec format error` (or container exits 139 instantly)

| Confirm | Root cause | Fix |
|---|---|---|
| `docker image inspect <img> --format '{{.Architecture}}'` ≠ host `uname -m` | Image built for a different CPU arch (classic: amd64 image on Apple Silicon arm64, or vice-versa in CI) | Build/pull the right arch. Multi-arch: `docker buildx build --platform linux/amd64,linux/arm64 -t img --push .`. To force a single arch at run: `docker run --platform linux/amd64 img` (needs emulation, e.g. QEMU/`tonistiigi/binfmt`). |
| Script with no shebang, or shebang shell absent in image | `exec format error` on a shell script in scratch/distroless | Add a valid `#!/bin/sh` and ensure that shell exists, or invoke explicitly: `ENTRYPOINT ["/bin/sh","/entrypoint.sh"]`. |

### Symptom: `OOMKilled` / exit code 137

```bash
docker inspect --format '{{.State.OOMKilled}}' <ctr>      # true → kernel OOM killer
docker stats --no-stream <ctr>                            # live mem vs limit
docker inspect --format '{{.HostConfig.Memory}}' <ctr>    # 0 = unlimited
```

Branches:
- **`OOMKilled=true`, a `--memory` limit is set** → process exceeded the limit. Raise `--memory` *or* fix the leak. For the JVM/Node, the runtime must honor the cgroup: modern JDK (11+) does by default; Node may need `--max-old-space-size` set below the container limit. Set a limit deliberately (`--memory=512m`) — don't leave it unbounded in prod.
- **`OOMKilled=true`, no `--memory` limit** → the *host* ran out of RAM, kernel killed the biggest container. Add limits to all containers; check for a leaking neighbor with `docker stats`.
- **Exit 137 but `OOMKilled=false`** → something sent SIGKILL: `docker kill`, an orchestrator liveness probe killing a hung pod, or `docker stop` timing out (10s default) and escalating SIGTERM→SIGKILL. Fix PID-1 signal handling (below) or raise the stop timeout.

### Symptom: CrashLoop / container ignores `docker stop`, takes 10s to die

Root cause is almost always **PID 1 doesn't forward/handle signals**.
```bash
docker inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' <ctr>
```
- If you see `["/bin/sh","-c","node server.js"]` (shell form) → the shell is PID 1, it doesn't forward SIGTERM to `node`, so `docker stop` waits 10s then SIGKILLs (you'll see exit 137 or a hang). **Fix: exec form** `CMD ["node","server.js"]`, or `exec node server.js` at the end of a wrapper script so the app *replaces* the shell.
- If your app spawns children/becomes a subreaper and leaves zombies → add an init: `docker run --init …` or bake in `tini`:
  ```dockerfile
  RUN apk add --no-cache tini
  ENTRYPOINT ["/sbin/tini","--"]
  CMD ["node","server.js"]
  ```

### Symptom: build fails / cache never hits / build is slow

```bash
DOCKER_BUILDKIT=1 docker build --progress=plain -t img .     # full step output
docker build --no-cache … # to confirm a step is genuinely broken vs cached-bad
```
| Observation | Cause | Fix |
|---|---|---|
| `failed to solve: ... no such file or directory` on `COPY` | File excluded by `.dockerignore`, or path is outside the build context | Adjust `.dockerignore`; remember `COPY` paths are relative to the context root, not the Dockerfile. |
| Every build reinstalls deps | `COPY . .` placed *before* `RUN npm ci` / `pip install` | Copy manifests first: `COPY package*.json ./` → `RUN npm ci` → `COPY . .`. |
| "Sending build context … 2.3GB" / slow uploads | No `.dockerignore`; shipping `.git`, `node_modules`, `target/`, `dist/` | Add `.dockerignore` (see Automation). |
| `failed to solve: process "/bin/sh -c …" did not complete successfully: exit code: N` | The `RUN` command itself failed | Re-run with `--progress=plain`; reproduce the command in `docker run -it <prev-stage> sh`. |

### Symptom: image is huge

```bash
docker images <img>                    # SIZE
docker history --no-trunc <img>        # per-layer size — find the fat layer
docker run --rm wagoodman/dive <img>   # interactive layer/wasted-space explorer
```
Fixes: multi-stage build (compile in builder, copy artifact only); switch base to `-slim`/`alpine`/`distroless`; combine `RUN` chains and clean in the *same* layer (`apt-get install … && rm -rf /var/lib/apt/lists/*`); `--no-install-recommends`; don't `COPY` then delete (deletion adds a layer, doesn't shrink history).

### Symptom: networking — can't reach another container / published port / host

```bash
docker network ls
docker network inspect <net>           # which containers, their IPs/aliases
docker port <ctr>                      # actual host:container port mappings
docker exec <ctr> getent hosts <other> # DNS resolution inside the container
```
| Symptom | Cause | Fix |
|---|---|---|
| `connection refused` between two containers | On the default `bridge` network there is **no DNS** by name | Put both on a user-defined network: `docker network create app && docker run --network app --name db …`; then reach it as `db:5432` (the container *name* is the DNS alias). |
| Service in container unreachable from host on published port | App bound to `127.0.0.1` *inside* the container, not `0.0.0.0` | Bind the app to `0.0.0.0`; publish with `-p 8080:8080`. `EXPOSE` documents, it does **not** publish. |
| Container can't reach a service on the host machine | `localhost` inside a container is the container itself | Use `host.docker.internal` (Docker Desktop / add `--add-host=host.docker.internal:host-gateway` on Linux). |
| Compose services can't find each other | Wrong hostname | Use the **service name** as the hostname; Compose puts all services on one network with DNS. |

### Symptom: volume / bind-mount `permission denied`

```bash
docker inspect --format '{{.Config.User}}' <img>     # who the container runs as
docker exec <ctr> id                                  # uid/gid at runtime
ls -ln /host/path                                     # numeric owner on host
```
Root cause: the container's UID/GID doesn't match the host file owner (Linux maps by numeric ID, not name). Fixes:
- Run as a UID that owns the files: `docker run --user $(id -u):$(id -g) …`.
- Or `chown` the mount target in the image / an init step to the container's UID.
- Named volumes inherit the image's ownership on first populate — prefer them over bind mounts when the host owner is awkward.
- SELinux hosts (RHEL/Fedora): add `:z` / `:Z` to the mount (`-v /data:/data:Z`) or you'll get `permission denied` despite correct UID.

### Symptom: rootless / daemon `permission denied`

- `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` / `permission denied` on the socket → user not in the `docker` group (`sudo usermod -aG docker $USER`, re-login) or daemon not running (`sudo systemctl start docker`). In rootless mode the socket is `$XDG_RUNTIME_DIR/docker.sock`.
- Privileged ports (<1024) in rootless mode fail to bind → publish a high port, or set `net.ipv4.ip_unprivileged_port_start`.

### Symptom: HEALTHCHECK shows `unhealthy`

```bash
docker inspect --format '{{json .State.Health}}' <ctr> | jq   # last 5 probe outputs + exit codes
```
- Probe command must exist in the image (`curl`/`wget` often absent in slim/distroless → use the app's own healthz binary or `CMD-SHELL` with a present tool).
- A probe exit code of `1` = unhealthy. `start-period` must be long enough for slow boots, or you flap into `unhealthy` before the app is ready.

### Symptom: `no space left on device`

```bash
docker system df                       # reclaimable space by images/containers/volumes/cache
docker system df -v                    # itemized
df -h /var/lib/docker
```
Reclaim (destructive — confirm scope first):
```bash
docker builder prune                   # build cache only (safe-ish)
docker image prune                     # dangling images
docker system prune                    # stopped ctrs + dangling imgs + unused nets + build cache
docker system prune -a --volumes       # EVERYTHING unused incl. volumes — DESTRUCTIVE
```
Caches grow forever with BuildKit. In CI, prune the builder or cap it (`docker buildx prune --keep-storage 10GB`).

### Symptom: secret leaked into an image

```bash
docker history --no-trunc <img>                          # spot ARG/ENV/RUN with secrets
docker run --rm <img> env                                # ENV-baked secrets
trivy image --scanners secret <img>                      # automated secret scan
```
A secret in any layer is permanent — `RUN rm` in a later layer does NOT remove it. **Rotate the credential**, then rebuild correctly with `--mount=type=secret` (see Automation). Never pass secrets via `--build-arg` (visible in `docker history`).

---

## Automation

### Production multi-stage Dockerfiles

**Go (static binary → scratch/distroless):**
```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

**Node (deps cached, non-root, slim):**
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
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.js"]      # exec form → node is PID 1, handles SIGTERM
```

**Python (slim, non-root, no pyc bloat):**
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
RUN useradd -m -u 10001 appuser
COPY --from=build /install /usr/local
WORKDIR /app
COPY . .
USER appuser
ENTRYPOINT ["python", "-m", "myapp"]
```

### `.dockerignore` (always)
```gitignore
.git
.gitignore
**/node_modules
**/__pycache__
*.pyc
dist
build
target
.venv
.env
*.log
Dockerfile
docker-compose*.yml
.dockerignore
**/.DS_Store
```

### BuildKit secrets (never bake credentials)
```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```
```bash
docker build --secret id=npmrc,src=$HOME/.npmrc -t img .
# SSH for private repos:  RUN --mount=type=ssh git clone … ; build with --ssh default
```

### Multi-arch build & push (buildx)
```bash
docker buildx create --name multi --use --bootstrap        # idempotent: || docker buildx use multi
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag registry.example.com/app:1.4.2 \
  --tag registry.example.com/app:latest \
  --cache-from type=registry,ref=registry.example.com/app:buildcache \
  --cache-to   type=registry,ref=registry.example.com/app:buildcache,mode=max \
  --push .
```

### docker compose for local dev (`compose.yaml`)
```yaml
services:
  api:
    build:
      context: .
      target: runtime
    ports: ["3000:3000"]
    environment:
      DATABASE_URL: postgres://app:app@db:5432/app
    depends_on:
      db:
        condition: service_healthy
    develop:
      watch:                       # compose watch: hot-reload on file change
        - { action: sync, path: ./src, target: /app/src }
        - { action: rebuild, path: package.json }
  db:
    image: postgres:16-alpine
    environment: { POSTGRES_USER: app, POSTGRES_PASSWORD: app, POSTGRES_DB: app }
    volumes: ["pgdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 5s
      timeout: 3s
      retries: 5
volumes:
  pgdata:
```
```bash
docker compose up --build --watch
docker compose down -v            # -v also removes named volumes
```

### CI: build, scan, push (idempotent, fails on criticals)
```bash
#!/usr/bin/env bash
set -euo pipefail
IMAGE="registry.example.com/app"
TAG="${GIT_SHA:-$(git rev-parse --short HEAD)}"

DOCKER_BUILDKIT=1 docker build -t "$IMAGE:$TAG" .

# Scan; --exit-code 1 makes the pipeline fail on findings
trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed "$IMAGE:$TAG"
# grype alternative:  grype "$IMAGE:$TAG" --fail-on high

docker tag "$IMAGE:$TAG" "$IMAGE:latest"
docker push "$IMAGE:$TAG"
docker push "$IMAGE:latest"
```

### Reproducible / pinned base images
```dockerfile
FROM python:3.12-slim@sha256:<digest>     # pin by digest, not just tag
```
```bash
docker buildx imagetools inspect python:3.12-slim   # get the digest to pin
```

---

## Common gotchas

- **`EXPOSE` does not publish a port.** It's documentation. You still need `-p`/`ports:`.
- **Shell-form `CMD`/`ENTRYPOINT` breaks signals.** `CMD node app.js` → PID 1 is `/bin/sh`, SIGTERM ignored, slow/forced shutdown. Use the exec (JSON-array) form.
- **`ENTRYPOINT` + `CMD` interplay:** with exec-form `ENTRYPOINT`, `CMD` supplies *default args* appended to it. `docker run img X` replaces `CMD`, not `ENTRYPOINT`.
- **`RUN rm secret` does not delete it from history** — the file persists in the earlier layer. Rotate + rebuild with `--mount=type=secret`.
- **`COPY . .` before installing deps** kills the dependency-layer cache. Manifests first.
- **`latest` is not pinned.** It moves. Pin by digest for reproducible CI.
- **`--build-arg` is not secret** — it shows in `docker history`. Use BuildKit secrets.
- **Default `bridge` network has no name-based DNS.** Create a user-defined network for container-to-container DNS.
- **`localhost` inside a container is the container**, not the host (`host.docker.internal`) and not another service (use its name).
- **`docker stop` waits 10s then SIGKILLs.** If your PID 1 traps SIGTERM and shuts down cleanly, it's instant; if not, you eat 10s + exit 137.
- **Volumes outlive `docker rm`.** `docker rm` keeps named/anonymous volumes; use `docker rm -v` or `docker volume prune` — and watch anonymous volumes piling up from `VOLUME` instructions.
- **`apt-get` cleanup must be in the same `RUN`** or it doesn't shrink the layer.
- **Bind mounts shadow image contents** at the mount path — your image's `/app/node_modules` vanishes if you bind-mount `/app`.

## Quick reference

| Task | Command |
|---|---|
| Inspect exit code / OOM | `docker inspect -f '{{.State.ExitCode}} {{.State.OOMKilled}}' <ctr>` |
| Full plain build log | `docker build --progress=plain --no-cache -t img .` |
| Per-layer sizes | `docker history --no-trunc <img>` |
| Explore wasted space | `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock wagoodman/dive <img>` |
| Disk usage / reclaimable | `docker system df` / `docker system df -v` |
| Prune build cache | `docker builder prune` / `docker buildx prune --keep-storage 10GB` |
| Nuke everything unused | `docker system prune -a --volumes` (DESTRUCTIVE) |
| Live resource use | `docker stats --no-stream` |
| Shell into running ctr | `docker exec -it <ctr> sh` (or `bash`) |
| Shell into a build stage | `docker build --target <stage> -t dbg . && docker run -it dbg sh` |
| Port mappings | `docker port <ctr>` |
| Inspect a network | `docker network inspect <net>` |
| DNS check inside ctr | `docker exec <ctr> getent hosts <name>` |
| Run as host user | `docker run --user $(id -u):$(id -g) …` |
| Force/select arch | `docker run --platform linux/amd64 img` |
| Multi-arch build+push | `docker buildx build --platform linux/amd64,linux/arm64 --push -t img .` |
| Health probe history | `docker inspect -f '{{json .State.Health}}' <ctr> \| jq` |
| Scan image | `trivy image --severity HIGH,CRITICAL --exit-code 1 <img>` |
| Get digest to pin | `docker buildx imagetools inspect <img>` |
| Add init (reap zombies) | `docker run --init …` |

See `references/` for the full failure-mode catalog, the Dockerfile template library, and the BuildKit & multi-arch deep dive.
