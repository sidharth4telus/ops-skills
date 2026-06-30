# BuildKit, buildx & Multi-Arch Deep Dive

Everything about modern Docker builds: enabling BuildKit, cache mounts, secrets/SSH, multi-platform images, registry cache, and CI integration. Defaults to Docker 27+ where BuildKit is the default builder.

---

## Enabling / confirming BuildKit

BuildKit is the default since Docker 23.0. To be explicit or on older engines:
```bash
export DOCKER_BUILDKIT=1
docker build .                  # uses BuildKit
docker buildx version           # buildx is the multi-platform-capable CLI
docker buildx ls                # list builders and their platforms
```
`docker build` (classic CLI with BuildKit) and `docker buildx build` share the engine; `buildx` adds `--platform` multi-arch, multiple outputs, and named builder instances.

The `# syntax=docker/dockerfile:1` line at the top of a Dockerfile pulls the latest stable frontend, enabling `RUN --mount`, heredocs, and other modern features regardless of engine version.

---

## Cache mounts — persist package caches across builds

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=cache,target=/root/.npm        npm ci
RUN --mount=type=cache,target=/root/.cache/pip  pip install -r requirements.txt
RUN --mount=type=cache,target=/go/pkg/mod       go mod download
RUN --mount=type=cache,target=/root/.m2         ./mvnw package
RUN --mount=type=cache,target=/root/.cargo/registry cargo build --release
```
The cache mount survives even when the layer cache is busted (e.g. a manifest change), so dependency downloads are reused. Add `sharing=locked` if parallel builds could corrupt the cache:
```dockerfile
RUN --mount=type=cache,target=/root/.npm,sharing=locked npm ci
```

### Bind & tmpfs mounts
```dockerfile
RUN --mount=type=bind,source=.,target=/src \    # read context without COPY (no layer)
    make -C /src build
RUN --mount=type=tmpfs,target=/scratch ...       # ephemeral scratch space
```

---

## Secrets at build time (never bake credentials)

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
RUN --mount=type=secret,id=aws,target=/root/.aws/credentials aws s3 cp ...
```
```bash
docker build --secret id=npmrc,src=$HOME/.npmrc -t img .
docker build --secret id=aws,src=$HOME/.aws/credentials -t img .
# from an env var:
export NPM_TOKEN=...
docker build --secret id=npm_token,env=NPM_TOKEN -t img .
```
The secret is mounted only for that `RUN` and never written to a layer or `docker history`.

### SSH forwarding (private git deps)
```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=ssh git clone git@github.com:org/private.git
```
```bash
docker build --ssh default -t img .       # uses your ssh-agent
```

---

## Multi-architecture images

### Why
A single image *tag* can be a manifest list ("fat manifest") pointing at per-arch images. The registry serves `arm64` to Apple Silicon / Graviton and `amd64` to Intel automatically — no `--platform` needed at `docker run`.

### One-time builder setup (idempotent)
```bash
# create a builder that can do multi-platform; reuse if it exists
docker buildx inspect multi >/dev/null 2>&1 || \
  docker buildx create --name multi --driver docker-container --bootstrap
docker buildx use multi

# enable emulation for foreign archs (QEMU binfmt) — once per host
docker run --privileged --rm tonistiigi/binfmt --install all
```

### Build & push
```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag registry.example.com/app:1.4.2 \
  --tag registry.example.com/app:latest \
  --push .
```
> Multi-platform images can't be loaded into the local engine's image store (`--load` only supports one platform). They must be `--push`ed to a registry, or use `--output type=oci`.

### Inspect the resulting manifest list
```bash
docker buildx imagetools inspect registry.example.com/app:1.4.2
# shows each platform + its digest
```

### Run / force a specific arch locally
```bash
docker run --platform linux/amd64 registry.example.com/app:1.4.2   # via emulation
```

---

## Registry-backed build cache (fast CI)

Persist the build cache in the registry so a fresh CI runner reuses it:
```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --cache-from type=registry,ref=registry.example.com/app:buildcache \
  --cache-to   type=registry,ref=registry.example.com/app:buildcache,mode=max \
  --tag registry.example.com/app:$TAG \
  --push .
```
- `mode=max` caches *all* intermediate layers (vs `min` = only exported layers). Bigger cache, better hit rate.
- GitHub Actions has a native backend: `--cache-to type=gha,mode=max --cache-from type=gha`.
- Inline cache (single image, simpler): `--build-arg BUILDKIT_INLINE_CACHE=1` + `--cache-from <image:tag>`.

---

## Reproducible / pinned builds

```dockerfile
FROM python:3.12-slim@sha256:<digest>
```
```bash
# resolve a tag to its current digest to pin it
docker buildx imagetools inspect python:3.12-slim --format '{{json .Manifest.Digest}}'
```
- Pin base images by `@sha256:` digest, not just by floating tag.
- Pin OS packages (`apt-get install pkg=1.2.3`) and language deps via lockfiles.
- `SOURCE_DATE_EPOCH` + BuildKit `--build-arg SOURCE_DATE_EPOCH=...` can normalize timestamps for bit-reproducible images.

---

## Image scanning in CI

```bash
# Trivy — vulnerabilities, fails build on HIGH/CRITICAL that have a fix
trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed registry.example.com/app:$TAG
# Trivy — secret + misconfig scan
trivy image --scanners vuln,secret,config registry.example.com/app:$TAG

# Grype — alternative scanner
grype registry.example.com/app:$TAG --fail-on high

# Generate an SBOM (supply-chain)
syft registry.example.com/app:$TAG -o spdx-json > sbom.json
docker buildx build --sbom=true --provenance=true --push -t app:$TAG .   # attach attestations
```

---

## GitHub Actions example (build → scan → push, multi-arch, cached)

```yaml
name: docker
on: { push: { branches: [main] } }
jobs:
  build:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3            # emulation for arm64
      - uses: docker/setup-buildx-action@v3          # buildx builder
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=sha
            type=ref,event=branch
      - uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: true
          sbom: true
      - name: Scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ghcr.io/${{ github.repository }}:sha-${{ github.sha }}
          severity: HIGH,CRITICAL
          exit-code: "1"
          ignore-unfixed: true
```

---

## Debugging buildx

```bash
docker buildx build --progress=plain .            # full step output (not the collapsed TTY view)
docker buildx build --no-cache .                  # bypass all cache
docker buildx build --target <stage> -t dbg .     # build only up to a stage, then `docker run -it dbg sh`
docker buildx du                                  # cache disk usage
docker buildx prune --keep-storage 10GB           # cap the cache
docker buildx rm multi                            # remove a builder instance
```
Common buildx errors:
- `ERROR: Multiple platforms feature is currently not supported for docker driver` → you're on the default `docker` driver; create a `docker-container` builder (`docker buildx create --use`).
- `failed to solve: failed to load cache key` with registry cache → cache ref auth/permissions; ensure you're logged in to the cache registry.
- `--load` with multiple `--platform` → not allowed; `--push` instead.
