# Container & Build Failure-Mode Catalog

A deeper, exhaustive reference for the failure modes summarized in SKILL.md. Each entry: signature → confirm → root cause → fix → verify.

---

## 1. Exit-code reference (full)

A container's exit code is `docker inspect -f '{{.State.ExitCode}}' <ctr>`. The conventional meanings:

| Code | Meaning | Typical cause |
|---|---|---|
| 0 | Success | Foreground process completed. Expected for one-shot jobs; a bug only if you expected a long-running server. |
| 1 | General app error | Application threw an uncaught exception / returned 1. Read `docker logs`. |
| 2 | Misuse of shell builtin | Bad shell syntax in an entrypoint script. |
| 125 | Docker daemon / `docker run` failed | The container never started: bad flag, invalid mount source, image not found, port already allocated, invalid `--platform`. Error goes to *your terminal*, not `docker logs`. |
| 126 | Command invoked cannot execute | Entrypoint exists but is not executable (lost `+x`), or it's a directory. |
| 127 | Command not found | Binary not on `$PATH`; or exec-form entrypoint references a shell in a `scratch`/distroless image that has none; or wrong arch path. |
| 128 | Invalid argument to exit | Application called `exit()` with an out-of-range value. |
| 128+N | Killed by signal N | 130 = SIGINT (Ctrl-C), 137 = SIGKILL (128+9), 139 = SIGSEGV (128+11), 143 = SIGTERM (128+15). |
| 137 | SIGKILL | Usually OOMKilled; also `docker kill`, or `docker stop` escalating after the 10s grace period. |
| 139 | SIGSEGV | Native memory fault — or running a binary built for the wrong CPU arch. |
| 143 | SIGTERM | Clean stop *if* PID 1 handled it; otherwise a sign of a stop that wasn't trapped. |
| 255 | Exit out of range / wrapper error | Entrypoint wrapper returned -1 or similar. |

`docker run` itself can also fail before the container exists — that's 125 and the message is on stderr in your shell.

---

## 2. Build failures

### `failed to solve: ... exit code: N`
The `RUN` instruction failed. Get the real error:
```bash
docker build --progress=plain --no-cache -t img . 2>&1 | tee build.log
```
Reproduce interactively by building up to the prior stage/step and shelling in:
```bash
docker build --target <stage> -t dbg .
docker run --rm -it dbg sh        # now run the failing command by hand
```

### `COPY failed: ... no such file or directory`
- The source path is excluded by `.dockerignore`, OR
- The path is outside the build context (you can only `COPY` from the context root downward — `COPY ../foo` is illegal), OR
- A typo / case-sensitivity mismatch (the daemon is case-sensitive even if your host FS isn't).

### Cache invalidation cascade
Once a layer's inputs change, every subsequent layer rebuilds. The #1 cause of "why did my whole build re-run" is `COPY . .` early in the file: any source edit busts it and everything after. Pattern:
```dockerfile
COPY package*.json ./        # changes rarely
RUN npm ci                   # cached unless manifests change
COPY . .                     # changes often — but cheap, nothing expensive after it
```
Cache mounts (`RUN --mount=type=cache,...`) persist *across* builds and survive cache busts — use them for package-manager caches (`/root/.npm`, `/root/.cache/pip`, `/go/pkg/mod`, `~/.m2`).

### Build context bloat
```bash
du -sh .                       # what the daemon would upload
# "Sending build context to Docker daemon  1.9GB" → add .dockerignore
```
A fat context slows every build (upload time), invalidates cache (hashing more files), and can leak secrets/`.git`. The minimal `.dockerignore` in SKILL.md is the baseline.

---

## 3. Image size

```bash
docker images <img>                 # total size
docker history --no-trunc <img>     # per-instruction layer size — find the offender
dive <img>                          # or: docker run --rm wagoodman/dive <img>
```
Reduction tactics, biggest wins first:
1. **Multi-stage**: build artifacts in a fat stage, `COPY --from=build` only the binary/dist into a minimal runtime. (Often 10x.)
2. **Smaller base**: `debian:slim` < `debian`; `alpine` < `slim`; `distroless`/`scratch` smallest. (Alpine uses musl — watch for glibc-only binaries.)
3. **Clean in the same layer**: `RUN apt-get update && apt-get install -y --no-install-recommends X && rm -rf /var/lib/apt/lists/*`.
4. **Don't COPY-then-delete**: deletion creates a new layer; the bytes stay in the earlier layer. Avoid adding the file at all.
5. **`.dockerignore`** keeps junk out of the build (and out of `COPY . .`).

---

## 4. Networking deep dive

### Network drivers
- `bridge` (default): containers get private IPs. The **default bridge has no embedded DNS** — name resolution between containers only works on *user-defined* bridge networks.
- user-defined `bridge`: `docker network create app`. Containers resolve each other by **container name** and by `--network-alias`.
- `host`: container shares the host network namespace (Linux only). No port mapping needed; `localhost` is the host. Beware port conflicts.
- `none`: no networking.

### Container-to-container
```bash
docker network create app
docker run -d --name db --network app postgres:16
docker run --rm --network app postgres:16 psql -h db -U postgres   # 'db' resolves
```

### Published vs exposed
- `EXPOSE 8080` — metadata only. Does nothing at runtime by itself.
- `-p 8080:80` / `-p 127.0.0.1:8080:80` — actually maps host→container. Bind to `127.0.0.1` to avoid exposing on all host interfaces.
- App must listen on `0.0.0.0` inside the container, not `127.0.0.1`, or the published port reaches nothing.

### Reaching the host from a container
- Docker Desktop (Mac/Win): `host.docker.internal` resolves to the host.
- Linux engine: add `--add-host=host.docker.internal:host-gateway`.

### Debugging
```bash
docker exec <ctr> getent hosts <name>    # DNS
docker exec <ctr> nc -zv <host> <port>   # TCP reachability (if nc present)
docker network inspect <net>             # IPs, aliases, attached containers
docker port <ctr>                        # actual mappings
```

---

## 5. Permissions

### Bind-mount UID/GID
Linux maps ownership by **numeric** UID/GID. If the container process is UID 1000 but `/host/data` is owned by UID 0, writes fail with `permission denied`.
```bash
docker exec <ctr> id                  # container's runtime uid/gid
ls -ln /host/data                     # numeric host owner
docker run --user $(id -u):$(id -g) -v "$PWD/data:/data" img   # run as host user
```
Options: run as a matching UID; `chown` the target in an entrypoint; or use a **named volume** (Docker populates it with the image's ownership on first use, avoiding host-owner mismatch).

### SELinux
On RHEL/Fedora/CentOS with SELinux enforcing, bind mounts are blocked unless relabeled:
```bash
docker run -v /host/data:/data:Z img    # :Z = private relabel, :z = shared
```

### Rootless Docker
- Socket is `$XDG_RUNTIME_DIR/docker.sock`; `DOCKER_HOST` must point at it.
- Ports < 1024 can't bind without `net.ipv4.ip_unprivileged_port_start` tuning.
- File ownership inside containers is remapped via subuid/subgid — host files may appear owned by very high UIDs.

### Daemon access denied
```
Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
permission denied while trying to connect to the Docker daemon socket
```
→ Add user to `docker` group (`sudo usermod -aG docker $USER` then re-login), or start the daemon (`sudo systemctl start docker`).

---

## 6. Platform / architecture

```bash
docker image inspect <img> -f '{{.Os}}/{{.Architecture}}'
uname -m                      # host arch (x86_64 / aarch64)
```
- `exec format error` / instant exit 139: arch mismatch (amd64 image on arm64 host or vice versa). Common when an arm64 dev (Apple Silicon) pushes to amd64 prod, or a CI runner differs from prod.
- Run cross-arch with emulation: install binfmt once (`docker run --privileged --rm tonistiigi/binfmt --install all`), then `docker run --platform linux/amd64 img`.
- Build multi-arch images so the registry serves the right one automatically:
  ```bash
  docker buildx build --platform linux/amd64,linux/arm64 -t img --push .
  ```

---

## 7. PID 1, signals, and clean shutdown

Linux treats PID 1 specially: it does **not** get default signal handlers, and it must reap orphaned children. Consequences:
- **Shell-form CMD** (`CMD node app.js`) → `/bin/sh -c "node app.js"` → the shell is PID 1, doesn't forward SIGTERM, so `docker stop` waits the 10s grace period then SIGKILLs (you see a hang then exit 137/143).
- **Exec-form CMD** (`CMD ["node","app.js"]`) → `node` is PID 1 and receives signals directly. Make sure the app traps SIGTERM and shuts down gracefully.
- **Apps that fork children** (e.g. a process manager, or anything spawning subprocesses) can leave zombies because PID 1 isn't reaping them. Fix with an init that reaps:
  ```bash
  docker run --init img            # uses tini built into the engine
  ```
  or bake `tini` and set it as the entrypoint.

Verify graceful shutdown:
```bash
docker run -d --name t img
time docker stop t      # near-instant = signals handled; ~10s = not handled
```

---

## 8. HEALTHCHECK

```bash
docker inspect -f '{{json .State.Health}}' <ctr> | jq
```
Returns `Status` (starting/healthy/unhealthy) and the last 5 probe `Log` entries with `ExitCode` and `Output`.
- Probe tool must exist in the image. `curl`/`wget` are often absent in slim/distroless images. Prefer a probe that uses something present, or have the app expose a tiny health binary.
- `--start-period` gives the app time to boot before failed probes count against it. Too short → flaps to `unhealthy` during startup.
- A `HEALTHCHECK` only sets status; it doesn't restart the container (that's the orchestrator's / `--restart` policy's job in plain Docker; healthcheck integrates with Swarm/compose `depends_on: condition: service_healthy`).

---

## 9. Disk: `no space left on device`

```bash
docker system df          # summary: images / containers / volumes / build cache, RECLAIMABLE column
docker system df -v       # itemized per object
df -h /var/lib/docker     # actual disk
```
Reclaim, least to most destructive:
```bash
docker builder prune                       # build cache
docker buildx prune --keep-storage 10GB    # cap buildx cache
docker image prune                         # dangling (untagged) images
docker container prune                     # stopped containers
docker volume prune                        # unused volumes (DESTRUCTIVE — data loss)
docker system prune                        # ctrs + dangling imgs + nets + cache
docker system prune -a --volumes           # also tagged-but-unused imgs + ALL unused volumes
```
In CI, BuildKit cache grows unbounded — prune or cap it as a scheduled job. Inode exhaustion (`df -i`) can also surface as ENOSPC even with free bytes.

---

## 10. Secrets in layers

A secret written into any layer is permanent and extractable by anyone with the image:
```bash
docker history --no-trunc <img>     # ARG/ENV/RUN lines may show secrets
docker save <img> -o img.tar && tar xf img.tar    # then inspect each layer's tar
trivy image --scanners secret <img>
```
`RUN rm secret` in a later layer does **not** remove it from the earlier layer. Remediation:
1. **Rotate the leaked credential immediately** — assume it's compromised.
2. Rebuild correctly: `RUN --mount=type=secret,id=foo,target=/path …` (BuildKit), or fetch secrets at *runtime* from a secret manager, never at build time.
3. Never use `--build-arg` for secrets (visible in `docker history`).
