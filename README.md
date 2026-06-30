# ops-skills

**Debug-and-automate operations skills for [Claude Code](https://claude.com/claude-code).**

A family of `*-ops` skills — one per technology — that each combine **debugging** (symptom → confirm → root-cause → fix decision trees with real error strings and commands) and **automation** (copy-pasteable scripts, IaC, and CI patterns). They auto-activate from file types, tooling, and error signatures in your prompt.

| Skill | What it does |
|-------|--------------|
| **python-ops** | Tracebacks, pdb, asyncio pitfalls, import/dependency hell (venv/poetry/uv), profiling (cProfile/py-spy/tracemalloc), packaging — plus CLI/logging/retry/CI automation. |
| **js-ts-ops** | Node/TS debugging: async stack traces, `--inspect`, ESM↔CJS, TS compiler errors, source maps, heap snapshots, flaky Jest/Vitest — plus build/release/CI automation. The debug/ops complement to design-focused Node/TS skills. |
| **docker-ops** | Build/cache/image-size, exit codes (137/139/125/126/127), OOMKilled, PID-1 signals, networking, volume UID/GID, arch mismatch — plus multi-stage Dockerfiles, buildx multi-arch, compose, CI build/scan/push. |
| **k8s-ops** | CrashLoopBackOff, ImagePullBackOff, OOMKilled, Pending/unschedulable, probes, RBAC, Service/DNS/Ingress — plus manifests, Helm (`upgrade --install --atomic`), kustomize overlays, rollout/rollback, GitOps. |
| **cloud-ops** | AWS **+** GCP IAM/permission denials, auth/credentials, throttling/quota, networking, DNS, 5xx & cost triage — shown with `aws` and `gcloud` side by side — plus least-privilege IAM, log queries, and cross-cloud IaC. |
| **redis-saas-ops** | Managed Redis (Redis Cloud / ElastiCache / Memorystore): TLS, AUTH/ACL, eviction/OOM, latency & big keys, cluster MOVED/CROSSSLOT, failover, pool exhaustion — plus Terraform, client config, monitoring, safe SCAN. |
| **cloudfront-ops** | CloudFront/CDN: cache hit-ratio, invalidations vs versioned keys, OAC/origin 403, 502/503/504, signed URLs/cookies, CORS, redirect loops — plus distribution-as-code, CI invalidation, Athena log analysis. |
| **dynatrace-ops** | Incident-investigation playbooks (problem → impacted entities → failing services → failure traces → RCA) and observability-as-code (dtctl, DQL, dashboards/notebooks/SLOs/Workflows). Orchestrates the `dt-*` skills. |

Each skill directory contains `SKILL.md`, `references/*.md` deep dives, and an `evals/evals.json` eval suite.

---

## Install

### Option A — as a Claude Code plugin (recommended)

```bash
# 1. add this repo as a plugin marketplace
/plugin marketplace add sidharth4telus/ops-skills        # or a full git URL

# 2. install the plugin (the @ops-skills suffix is the marketplace name)
/plugin install ops-skills@ops-skills
```

(If you fork this repo, swap `sidharth4telus/ops-skills` for your own `owner/repo`.) To update later: `/plugin marketplace update ops-skills`.

### Option B — install the skills directly

Copy the skill folders into your personal skills directory:

```bash
git clone https://github.com/sidharth4telus/ops-skills.git
cd ops-skills
./install.sh                 # copies skills into ~/.claude/skills/
# or symlink them (stay in sync with the repo):
./install.sh --link
```

Or do it by hand:

```bash
cp -R plugins/ops-skills/skills/* ~/.claude/skills/
```

Restart Claude Code (or start a new session) and the skills will be discovered automatically.

### Project-scoped install

To make the skills available only inside one project, copy them into that repo's `.claude/skills/` instead of `~/.claude/skills/`.

---

## How the skills activate

Skills load automatically when your prompt matches their triggers — a pasted stack trace, an error signature (`CrashLoopBackOff`, `OOMKilled`, `NOAUTH`, `AccessDenied`, `exec format error`, …), a file type (`Dockerfile`, `*.tf`, `tsconfig.json`), or a tool name (`kubectl`, `gcloud`, `redis-cli`). You can also invoke one explicitly, e.g. *"use k8s-ops to debug this pod"*.

## Layout

```
ops-skills/
├── .claude-plugin/
│   └── marketplace.json         # marketplace manifest (this repo)
├── plugins/
│   └── ops-skills/
│       ├── .claude-plugin/
│       │   └── plugin.json       # plugin manifest
│       └── skills/
│           ├── python-ops/       # SKILL.md + references/ + evals/
│           ├── js-ts-ops/
│           ├── docker-ops/
│           ├── k8s-ops/
│           ├── cloud-ops/
│           ├── redis-saas-ops/
│           ├── cloudfront-ops/
│           └── dynatrace-ops/
├── install.sh
├── LICENSE
└── README.md
```

## Contributing

Each new technology gets one `<tech>-ops` skill that combines debugging + automation, following the shape of the existing ones: rich auto-trigger frontmatter, a `## Debugging` decision-tree section (the heart), a `## Automation` section, `## Common gotchas`, a `## Quick reference`, 2–3 `references/*.md`, and an `evals/evals.json` with at least one debugging, one automation, and one review eval.

## License

MIT — see [LICENSE](LICENSE).
