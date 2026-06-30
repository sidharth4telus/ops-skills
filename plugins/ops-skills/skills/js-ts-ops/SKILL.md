---
name: js-ts-ops
description: >
  Debugging and automation specialist for JavaScript / TypeScript / Node.js (Node 20+, TS 5.x) —
  the operational complement to design-focused skills. Use this skill whenever you need to DIAGNOSE
  a Node/TS failure or AUTOMATE a JS/TS workflow: reading sync and async stack traces, attaching
  `node --inspect` / Chrome DevTools / VS Code debuggers, hunting unhandled promise rejections,
  finding event-loop blocking with `--prof` / clinic.js, capturing and reading heap snapshots for
  memory leaks, untangling ESM ↔ CommonJS interop errors, decoding TypeScript compiler errors and
  tsconfig module/moduleResolution mistakes, fixing source maps that don't map, resolving
  EADDRINUSE / ECONNREFUSED, repairing npm/pnpm/yarn dependency, peer-dep and lockfile-drift
  problems, and stabilizing flaky Jest/Vitest suites or processes that won't exit. On the automation
  side: npm/pnpm scripts, build tooling (tsc, esbuild, tsup, vite), CI pipelines, lint/format
  (eslint, prettier, biome), release automation (changesets, semantic-release), Node CLI tooling,
  and source-map-aware error reporting. Trigger on: *.ts, *.tsx, *.js, *.mjs, *.cjs files; package.json,
  tsconfig.json, pnpm-lock.yaml, yarn.lock, package-lock.json; pasted Node stack traces; TypeScript
  error codes (TS2322, TS2345, TS7006, TS2307, TS1259); ERR_REQUIRE_ESM, ERR_MODULE_NOT_FOUND,
  "Cannot use import statement outside a module"; UnhandledPromiseRejection; EADDRINUSE, ECONNREFUSED;
  mentions of jest, vitest, esbuild, tsup, vite, clinic, --inspect, heap snapshot, event loop,
  open handles, peer dependency, lockfile. When in doubt for any Node/TS debugging or ops task,
  use this skill.
---

# JS / TS Ops

You are a Node.js / TypeScript operations engineer. Your job is to **diagnose runtime and build
failures fast**, then **automate the toolchain** so the failure can't recur silently. You think in
decision trees: symptom → confirm with a command → root cause → fix → verify. You prefer reproducing
the failure with a flag (`--inspect`, `--prof`, `--trace-warnings`) over guessing. This skill
complements the design-oriented `nodejs-expert` and `mastering-typescript` skills — they decide *how
to write* code; this skill decides *why it broke* and *how to ship it reliably*.

## Guiding Principles

1. **Reproduce before you theorize.** A flag (`NODE_OPTIONS=--stack-trace-limit=50`,
   `--trace-warnings`, `--inspect-brk`) or a minimal repro beats reading code blind.
2. **Async stacks lie unless you ask for them.** Enable `--async-stack-traces` (default in Node 16+)
   and never swallow the original `Error` — always `throw new Error(msg, { cause: err })`.
3. **Crash on unhandled rejection.** A process that logs-and-continues after `unhandledRejection`
   has corrupt state. Let it die and restart clean.
4. **Pin and verify the environment.** Lockfile + `engines` + `--frozen-lockfile`/`--frozen` in CI.
   "Works on my machine" is a version-drift bug until proven otherwise.
5. **Read the compiler, don't fight it.** A `TSxxxx` code is a precise contract violation. Fix the
   type or the `tsconfig`, never reach for `any`/`@ts-ignore` as a first move.
6. **Idempotent, dry-runnable automation.** Every script can run twice safely; destructive steps gate
   behind `--dry-run` or an explicit confirmation. `set -euo pipefail` on every bash wrapper.
7. **Source maps are non-negotiable in prod.** An un-mapped stack trace is a half-solved incident.

---

## Debugging

Decision trees for the most common Node/TS failure modes. Each: **symptom → confirm → root cause →
fix → verify.**

### 1. `UnhandledPromiseRejection` / silent async failure

**Symptom**
```
node:internal/process/promises:288
            triggerUncaughtException(err, true /* fromPromise */);
UnhandledPromiseRejection: This error originated either by throwing inside of an async function
without a catch block, or by rejecting a promise which was not handled with .catch()
```
**Confirm** — find *where*: run with full async stacks and crash-on-reject.
```bash
node --unhandled-rejections=strict --stack-trace-limit=100 app.js
node --trace-warnings app.js   # also surfaces the deprecation/warning origin
```
**Root cause** (branch):
- A promise is created but never `await`ed / `.catch()`ed — e.g. `arr.forEach(async ...)` (forEach
  ignores returned promises), a fire-and-forget `doThing()` with no `await`, or a `.then()` without
  a `.catch()`.
- An `await`ed call throws but the caller isn't wrapped in `try/catch` and isn't itself awaited up
  the chain.

**Fix**
```ts
// forEach swallows rejections — use for...of or Promise.all
for (const item of items) await process(item);          // sequential
await Promise.all(items.map(item => process(item)));      // parallel
// last-resort safety net (logs + exits non-zero — does NOT keep running)
process.on('unhandledRejection', (reason) => {
  console.error('UNHANDLED', reason);
  process.exit(1);
});
```
**Verify** `node --unhandled-rejections=strict` runs clean; the safety-net handler never fires.

### 2. Async stack trace is useless (`<anonymous>` / no app frames)

**Symptom** Stack shows only `node:internal/...` frames or `at processTicksAndRejections`.
**Confirm**
```bash
node --version                       # need >= 16 for async-stack-traces by default
node --async-stack-traces app.js     # explicit
NODE_OPTIONS=--stack-trace-limit=50 node app.js
```
**Root cause** Errors re-thrown without `cause`, or a library re-creates errors losing the chain;
or the trace was truncated at the default 10 frames.
**Fix** Always chain causes; raise the limit; for libraries that flatten errors, wrap at the call site.
```ts
try { await db.query(sql); }
catch (err) { throw new Error(`query failed: ${sql}`, { cause: err }); }
```
**Verify** Trace now shows your app frames and `[cause]:` with the original error.

### 3. ESM ↔ CommonJS interop errors

| Error signature | Root cause | Fix |
|---|---|---|
| `Error [ERR_REQUIRE_ESM]: require() of ES Module ...` | `require()`-ing a package that is ESM-only (`"type":"module"` or `.mjs`) from CJS | Use dynamic `await import('pkg')`, or make your file ESM. On Node 22+ enable `--experimental-require-module` / upgrade to Node 23+ where `require(esm)` is on by default |
| `SyntaxError: Cannot use import statement outside a module` | `import` used in a file Node treats as CJS | Add `"type":"module"` to package.json, rename to `.mjs`, or compile with `tsc` to CJS |
| `ERR_MODULE_NOT_FOUND: Cannot find module '.../util' imported from ...` | ESM requires **explicit file extensions** in relative imports | Import `./util.js` (not `./util`), even from `.ts` source compiled to ESM |
| `SyntaxError: Named export 'foo' not found. The requested module 'cjs-pkg' is a CommonJS module` | CJS module's named exports aren't statically analyzable | `import pkg from 'cjs-pkg'; const { foo } = pkg;` |
| `__dirname is not defined in ES module scope` | `__dirname`/`__filename` don't exist in ESM | `import { fileURLToPath } from 'node:url'; const __dirname = path.dirname(fileURLToPath(import.meta.url));` |

**Confirm which module system Node is using**
```bash
node -e "console.log(require('node:path'))"   # if this works the dir is CJS
cat package.json | grep '"type"'              # "module" => ESM, absent/"commonjs" => CJS
```

### 4. Event-loop blocking / 100% CPU on one core

**Symptom** Requests hang, latency spikes, but CPU is pegged on a single core; `--prof` shows one
hot function.
**Confirm**
```bash
# 1. Built-in V8 profiler -> isolate-*.log
node --prof app.js
# reproduce load, then:
node --prof-process isolate-*.log > processed.txt   # read "Summary" + "ticks" sections

# 2. clinic.js — best first reach
npx clinic doctor -- node app.js     # diagnoses event-loop / GC / I/O bottleneck
npx clinic flame -- node app.js      # flamegraph of CPU time

# 3. live event-loop lag, no restart needed
node -e "const {monitorEventLoopDelay}=require('perf_hooks');const h=monitorEventLoopDelay();h.enable();setInterval(()=>console.log('p99(ms)',h.percentile(99)/1e6),1000)"
```
**Root cause** Synchronous work on the main thread: a big `JSON.parse`, a regex with catastrophic
backtracking, `crypto.pbkdf2Sync`, `fs.readFileSync` in a hot path, or a tight CPU loop.
**Fix** Move CPU work off the loop — `node:worker_threads` for CPU-bound work, async variants
(`fs.promises.readFile`, promisified `crypto.pbkdf2`) for I/O, stream-parse instead of `JSON.parse`
for large payloads. See `references/profiling-and-memory.md` for a Worker wrapper.
**Verify** `clinic doctor` no longer flags the event loop; p99 loop delay < a few ms under load.

### 5. Memory leak / climbing RSS / `JavaScript heap out of memory`

**Symptom**
```
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
```
**Confirm**
```bash
# watch the trend
node -e "setInterval(()=>console.log(process.memoryUsage()),2000)" &
# raise the ceiling only to buy time, not as a fix:
node --max-old-space-size=4096 app.js
# capture heap snapshots to diff
node --inspect app.js     # then Chrome DevTools > Memory > take 2 snapshots, compare
# or signal-triggered snapshot (Node 12+):
kill -USR2 <pid>          # if --heapsnapshot-signal=SIGUSR2 was set
node --heapsnapshot-signal=SIGUSR2 app.js
```
**Root cause** Retained references that should be GC-able: unbounded `Map`/array caches, listeners
added in a loop without `removeListener`, closures captured by long-lived timers, global arrays that
only grow.
**Confirm the leak class** — take snapshot A, exercise the suspected path N times, take snapshot B,
in DevTools choose **"Objects allocated between A and B"**. The constructor with N× growth is your leak.
**Fix** Bound caches (LRU with max size + TTL), `off()`/`removeListener()` paired with every `on()`,
use `WeakMap`/`WeakRef` for caches keyed by objects, clear timers on shutdown.
**Verify** RSS plateaus under sustained load; snapshot diff shows no monotonically growing constructor.

### 6. `EADDRINUSE` — port already bound

**Symptom** `Error: listen EADDRINUSE: address already in use :::3000`
**Confirm & fix**
```bash
lsof -i :3000                      # macOS/Linux — find the PID
kill -9 $(lsof -t -i:3000)         # kill it
# Windows:
netstat -ano | findstr :3000  &&  taskkill /PID <pid> /F
```
**Root cause** A previous run didn't exit (common with `nodemon`/`tsx watch` zombies), or two
processes share a port. **Also** check the handler that masks the real bug:
```ts
server.on('error', (e: NodeJS.ErrnoException) => {
  if (e.code === 'EADDRINUSE') { console.error(`port ${port} busy`); process.exit(1); }
  else throw e;
});
```
**Verify** `lsof -i :<port>` is empty before start.

### 7. `ECONNREFUSED` — can't reach a dependency

**Symptom** `Error: connect ECONNREFUSED 127.0.0.1:5432`
**Confirm**
```bash
nc -vz localhost 5432              # is anything listening?
docker ps                          # is the dependency container up?
getent hosts db || nslookup db     # does the hostname resolve (compose/k8s)?
```
**Root cause** Service not started yet (race in CI/compose), wrong host/port, or `localhost` vs
container DNS name mismatch (`127.0.0.1` inside a container ≠ the host).
**Fix** Add a readiness wait, use the right hostname (compose service name), retry with backoff.
```bash
# wait for a TCP port before starting the app (CI / compose)
npx wait-on tcp:5432 && node app.js
```
**Verify** `nc -vz host port` succeeds before the app connects.

### 8. TypeScript compile errors (TS2322 / TS2345 / TS7006 / TS2307)

| Code | Meaning | Typical fix |
|---|---|---|
| `TS2322` | Type 'X' is not assignable to type 'Y' | Narrow/convert the value, fix the declared type, or widen the target type — don't cast away with `as` |
| `TS2345` | Argument of type 'X' is not assignable to parameter of type 'Y' | Same as 2322 but at a call site — check the function signature you're calling |
| `TS7006` | Parameter 'x' implicitly has an 'any' type | Add an explicit type; this only fires under `noImplicitAny` (i.e. `strict`) |
| `TS2307` | Cannot find module 'x' or its type declarations | `npm i -D @types/x`, or add a `*.d.ts` shim, or fix `moduleResolution` (see #9) |
| `TS2531/2532` | Object is possibly 'null'/'undefined' | Guard it (`if (x)`), `x?.foo`, or `x!` only when you've proven non-null |
| `TS1259` | Module can only be default-imported using esModuleInterop | Set `"esModuleInterop": true` (and `"allowSyntheticDefaultImports": true`) |

**Confirm** Run the checker alone (no emit) to see all errors:
```bash
npx tsc --noEmit                      # type-check the whole project
npx tsc --noEmit --explainFiles | grep <module>   # why a file is included
```

### 9. `tsconfig` module / moduleResolution mistakes

**Symptom** Imports that exist fail with TS2307, or `.js` extensions are required/forbidden
inconsistently, or `import.meta` errors.
**Confirm**
```bash
npx tsc --showConfig        # the FULLY-RESOLVED config tsc actually uses (after extends)
```
**Root cause / fix** — pick the matching preset for your runtime:

| You are targeting | `module` | `moduleResolution` | Notes |
|---|---|---|---|
| Modern Node ESM (Node 16+) | `nodenext` | `nodenext` | Requires `.js` extensions in imports; respects package.json `"exports"`/`"type"` |
| Node CommonJS | `commonjs` | `node10` (a.k.a. `node`) | Classic resolution, no extensions needed |
| Bundler (vite/esbuild/webpack) | `esnext` | `bundler` | No extensions; bundler resolves. TS 5.0+ |

Common traps: `"moduleResolution": "node"` with `"module": "nodenext"` is contradictory; `import.meta`
needs `module` of `es2020`+/`nodenext`. **Verify** with `npx tsc --noEmit` clean.

### 10. Source maps don't map (prod stack points at compiled JS)

**Symptom** Production stack trace shows `dist/index.js:1:24813` instead of `src/foo.ts:42`.
**Confirm**
```bash
ls dist/*.js.map                              # were maps emitted?
node --enable-source-maps dist/index.js       # Node maps traces itself (v12.12+)
grep sourceMappingURL dist/index.js | tail -1 # is the comment present & correct?
```
**Root cause** `sourceMap` not set in tsconfig, maps not deployed, or the runtime isn't told to use
them.
**Fix** `"sourceMap": true` (tsc) / `sourcemap: true` (esbuild/tsup/vite) **and** run Node with
`--enable-source-maps` (or `NODE_OPTIONS=--enable-source-maps`). For error reporters, register
`source-map-support` early:
```ts
import 'source-map-support/register';   // first import in the entrypoint
```
**Verify** Stack trace now references `.ts` files and original line numbers.

### 11. npm/pnpm/yarn dependency, peer-dep & lockfile drift

| Symptom | Confirm | Fix |
|---|---|---|
| `ERESOLVE unable to resolve dependency tree` (npm) | `npm ls <pkg>` shows conflicting versions | Fix the real version conflict; `--legacy-peer-deps` only as a documented escape hatch |
| `peer <x>@<v> from <y>` warnings | `npm ls` / `pnpm why <pkg>` | Align the peer to the required range; add it to your deps |
| CI install differs from local | `git status package-lock.json` shows drift | CI must use `npm ci` / `pnpm i --frozen-lockfile` / `yarn --frozen-lockfile`; commit the lockfile |
| `Cannot find module 'X'` at runtime though it's installed | `npm ls X`, check it's a `dep` not `devDep` | Move to `dependencies`; rebuild |
| Phantom/duplicate versions | `npm ls X` shows X at two paths | `npm dedupe`; pin via `overrides` (npm) / `resolutions` (yarn) / `pnpm.overrides` |

**Confirm the source of truth**
```bash
npm ls <pkg>                 # full dep tree for one package
pnpm why <pkg>               # who pulls it in
npm dedupe --dry-run         # what would collapse
```

### 12. Flaky Jest/Vitest + process won't exit (open handles)

**Symptom** `Jest did not exit one second after the test run completed. This usually means that
there are asynchronous operations that weren't stopped...` or intermittent failures.
**Confirm**
```bash
# Jest — list the handles keeping it alive
npx jest --detectOpenHandles --runInBand
# Vitest
npx vitest run --reporter=verbose --no-file-parallelism
# rerun only the flaky test many times to reproduce
npx vitest run -t "name" --retry=0 && for i in {1..50}; do npx vitest run -t "name" || break; done
```
**Root cause** Open handles: un-closed servers, DB pools, `setInterval`/`setTimeout` not cleared,
or leaked listeners. Flake: shared mutable state between tests, real timers/dates, unmocked network,
ordering dependence.
**Fix**
```ts
afterAll(async () => { await server.close(); await pool.end(); clearInterval(timer); });
beforeEach(() => { vi.useFakeTimers(); });   // deterministic time
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });
```
Isolate ordering bugs with `--runInBand` (Jest) / `--no-file-parallelism` (Vitest); if it passes
serially but fails parallel, it's shared state. **Verify** `--detectOpenHandles` reports none and 50
serial reruns pass.

---

## Automation

Real, copy-pasteable toolchain automation. Every script is idempotent and safe to re-run.

### package.json scripts (npm/pnpm)
```jsonc
{
  "engines": { "node": ">=20", "pnpm": ">=9" },
  "scripts": {
    "clean": "rm -rf dist coverage .turbo",
    "build": "tsup",                                  // see config below
    "typecheck": "tsc --noEmit",
    "lint": "eslint . --max-warnings=0",
    "format": "prettier --write . && eslint . --fix",
    "test": "vitest run",
    "test:watch": "vitest",
    "ci": "pnpm run typecheck && pnpm run lint && pnpm run test -- --coverage",
    "release": "changeset publish"
  }
}
```

### Fast bundling with tsup (esbuild under the hood)
```ts
// tsup.config.ts
import { defineConfig } from 'tsup';
export default defineConfig({
  entry: ['src/index.ts'],
  format: ['esm', 'cjs'],     // dual-publish; drop one if you only need it
  dts: true,                  // emit .d.ts (uses tsc; slower — disable in dev for speed)
  sourcemap: true,            // ALWAYS — required for #10
  clean: true,
  target: 'node20',
  splitting: false,
});
```
Raw esbuild equivalent (single command, no config):
```bash
npx esbuild src/index.ts --bundle --platform=node --target=node20 \
  --format=esm --sourcemap --outfile=dist/index.js
```

### Flat ESLint config (v9+) with TypeScript + Prettier
```js
// eslint.config.js
import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import prettier from 'eslint-config-prettier';
export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  { languageOptions: { parserOptions: { projectService: true } } },
  prettier,                       // turns off rules Prettier owns — must be LAST
  { ignores: ['dist/', 'coverage/'] },
);
```
Biome as an all-in-one (lint+format, no config sprawl, much faster):
```bash
npx @biomejs/biome check --write .     # format + lint + fix in one pass
```

### Release automation with Changesets
```bash
pnpm add -D @changesets/cli && pnpm changeset init
# contributor records intent (idempotent — creates a markdown file):
pnpm changeset                         # pick bump type, write summary
# CI on main: version bump + changelog + publish
pnpm changeset version                 # consumes .changeset/*.md -> bumps package.json + CHANGELOG
git add -A && git commit -m "chore: version packages"
pnpm changeset publish                 # publishes only packages with new versions (idempotent)
```

### CI pipeline (GitHub Actions) — frozen lockfile, cached, fail-fast
```yaml
# .github/workflows/ci.yml
name: ci
on: { push: { branches: [main] }, pull_request: {} }
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4        # reads packageManager field
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: pnpm }
      - run: pnpm install --frozen-lockfile   # fails if lockfile drifted (see #11)
      - run: pnpm run typecheck
      - run: pnpm run lint
      - run: pnpm run test -- --coverage
      - run: pnpm run build
```

### Node CLI tooling skeleton (built-in `parseArgs`, no framework)
```ts
#!/usr/bin/env node
import { parseArgs } from 'node:util';     // built-in since Node 18.3
const { values } = parseArgs({ options: {
  dryRun: { type: 'boolean', default: false },
  file:   { type: 'string', short: 'f' },
  help:   { type: 'boolean', short: 'h' },
}});
if (values.help) { console.log('usage: tool -f <file> [--dry-run]'); process.exit(0); }
if (values.dryRun) console.error('[dry-run] no changes will be written');
```

### Source-map-aware error reporting in production
Register source-map support before anything throws, run with `--enable-source-maps`, and ship the
`.map` files alongside the `.js`. For a reporter (Sentry et al.), upload source maps in CI so traces
map to `.ts` even off-box.

---

## Common gotchas

- **`array.forEach(async ...)` swallows rejections** — the returned promise is dropped. Use
  `for...of` (sequential) or `Promise.all(map(...))` (parallel).
- **`await` inside a `.forEach`/`.map` doesn't pause the loop** the way you think — `map` returns an
  array of promises you must `await Promise.all` on.
- **`process.on('unhandledRejection')` that logs and continues** leaves corrupt state. Exit non-zero.
- **`--max-old-space-size` is not a leak fix** — it just delays the crash. Find the retained refs.
- **Missing `.js` extension in ESM relative imports** → `ERR_MODULE_NOT_FOUND`. Required for
  `nodenext`, even when authoring `.ts`.
- **`"moduleResolution": "node"` (i.e. node10) with modern `"module": "nodenext"`** is contradictory
  and ignores package `"exports"`. Match them (table in #9).
- **`esModuleInterop: false`** makes `import express from 'express'` fail (TS1259). Turn it on.
- **`npm install` in CI** (vs `npm ci`) can silently mutate the lockfile and mask drift. Always
  `npm ci` / `--frozen-lockfile`.
- **`tsc` does NOT bundle** — it transpiles file-by-file. For a single shippable artifact use
  esbuild/tsup/vite.
- **`tsc` does NOT check at runtime** — types are erased. Validate external input with Zod/Valibot.
- **`localhost` inside a Docker container is the container**, not the host → `ECONNREFUSED`. Use the
  service name or `host.docker.internal`.
- **Jest open handles** (DB pools, servers, intervals) keep the process alive — close them in
  `afterAll`, confirm with `--detectOpenHandles`.
- **`tsx`/`ts-node` skip type-checking by default** for speed — run `tsc --noEmit` separately in CI or
  bugs ship.
- **Shipping without `.map` files** turns every prod stack trace into minified gibberish.

---

## Quick reference

### Node runtime flags
| Flag | Purpose |
|---|---|
| `--inspect` / `--inspect-brk` | Open the DevTools debugger (break on first line) |
| `--enable-source-maps` | Map stack traces back to source |
| `--unhandled-rejections=strict` | Crash on any unhandled rejection |
| `--trace-warnings` | Show the stack origin of process warnings/deprecations |
| `--prof` + `--prof-process` | V8 CPU profiler (isolate log → readable summary) |
| `--max-old-space-size=<MB>` | Raise heap ceiling (diagnostic only) |
| `--heapsnapshot-signal=SIGUSR2` | Dump a heap snapshot on signal |
| `--stack-trace-limit=<n>` | Capture deeper stacks |
| `--cpu-prof` / `--heap-prof` | Write `.cpuprofile` / `.heapprofile` on exit |

### Diagnostic commands
| Need | Command |
|---|---|
| Profile event loop / GC | `npx clinic doctor -- node app.js` |
| Flamegraph | `npx clinic flame -- node app.js` |
| Who's on a port | `lsof -i :<port>` / `netstat -ano \| findstr :<port>` |
| Reachability | `nc -vz <host> <port>` |
| Type-check only | `npx tsc --noEmit` |
| Resolved tsconfig | `npx tsc --showConfig` |
| Why a dep exists | `pnpm why <pkg>` / `npm ls <pkg>` |
| Open test handles | `npx jest --detectOpenHandles --runInBand` |

### tsconfig presets (see #9 for the full table)
| Runtime | module | moduleResolution |
|---|---|---|
| Node ESM | `nodenext` | `nodenext` |
| Node CJS | `commonjs` | `node10` |
| Bundler | `esnext` | `bundler` |

See `references/` for the full failure-mode catalog, the profiling & heap-snapshot playbook, and the
automation recipe library.
