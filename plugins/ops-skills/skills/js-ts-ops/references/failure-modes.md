# Failure-mode catalog (Node 20+ / TS 5.x)

Deep reference for failure modes that don't fit in SKILL.md. Each entry: **error signature →
how to confirm → root cause → fix**.

## Runtime errors

### `ERR_REQUIRE_ESM`
```
Error [ERR_REQUIRE_ESM]: require() of ES Module /node_modules/chalk/source/index.js
from /app/index.js not supported.
Instead change the require of index.js to a dynamic import() which is available in all
CommonJS modules.
```
- **Confirm**: `node -p "require('./node_modules/<pkg>/package.json').type"` → `module`.
- **Cause**: A CJS file `require()`s a package that ships only ESM (common after a major bump, e.g.
  `chalk@5`, `node-fetch@3`, `nanoid@4`).
- **Fix options** (pick one):
  1. `const { default: chalk } = await import('chalk');` (dynamic import works in CJS).
  2. Convert your file to ESM (`"type":"module"`), update all relative imports to add `.js`.
  3. Pin the last CJS major (`chalk@4`) if you can't migrate yet.
  4. Node 22.12+: run with `--experimental-require-module`; Node 23+ has `require(esm)` on by default.

### `Cannot use import statement outside a module`
```
import { foo } from './foo.js';
^^^^^^
SyntaxError: Cannot use import statement outside a module
```
- **Confirm**: `cat package.json | grep type` — missing or `"commonjs"`.
- **Cause**: ESM syntax in a file Node parses as CJS.
- **Fix**: add `"type": "module"`, OR rename the file to `.mjs`, OR (if TS) compile with
  `"module": "commonjs"` so `tsc` rewrites `import` to `require`.

### `ERR_UNSUPPORTED_DIR_IMPORT` / `ERR_MODULE_NOT_FOUND`
```
Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/app/src/util' imported from /app/src/index.js
Did you mean to import ./util.js?
```
- **Cause**: ESM has no directory-index or extensionless resolution.
- **Fix**: import the full path `./util/index.js` or `./util.js`. In TS, author `./util.js` even
  though the source file is `util.ts` (TS rewrites nothing; the path must be the *emitted* path).

### `MaxListenersExceededWarning`
```
(node:1234) MaxListenersExceededWarning: Possible EventEmitter memory leak detected.
11 close listeners added to [Server]. Use emitter.setMaxListeners() to increase limit
```
- **Confirm**: `node --trace-warnings app.js` → shows the `.on()` call site.
- **Cause**: listeners added in a loop / per-request without removal — a real leak signal.
- **Fix**: pair every `on()` with `off()`/`once()`, or hoist the listener out of the hot path. Only
  raise `setMaxListeners` when you genuinely need >10 and have proven it's bounded.

### `ERR_INVALID_ARG_TYPE` from streams/buffers
- **Cause**: passing an object where a string/Buffer is expected (often `undefined` env var).
- **Fix**: validate env at boot (Zod schema over `process.env`); fail fast with a clear message.

## TypeScript errors

### `TS2307: Cannot find module 'x' or its corresponding type declarations`
- **Confirm**: `ls node_modules/@types/x`; `npx tsc --traceResolution 2>&1 | grep x` (verbose
  resolution log).
- **Causes & fixes**:
  - No bundled types and no `@types/x` → `npm i -D @types/x`, or write `declare module 'x';` in a
    `*.d.ts`.
  - Wrong `moduleResolution` for the package's `"exports"` map → switch to `nodenext`/`bundler`.
  - Path alias not mirrored in tsconfig → add `"paths"` + ensure the bundler/runtime resolves it
    (e.g. `tsconfig-paths`, or build-time alias).

### `TS2305 / TS2614: Module has no exported member` & default/named confusion
- **Cause**: importing a named export that's actually a default (or vice versa), often a CJS package.
- **Fix**: with `esModuleInterop: true`, `import x from 'pkg'`; without it, `import * as x`.

### `TS2532 / TS18048: Object is possibly 'undefined'`
- **Cause**: `strictNullChecks` (part of `strict`).
- **Fix**: guard (`if (x)`), optional chain (`x?.y`), nullish default (`x ?? d`), or assert (`x!`)
  only when proven. Array access under `noUncheckedIndexedAccess` returns `T | undefined` — handle it.

### `TS5023 / TS5024: Unknown compiler option`
- **Cause**: tsconfig option from a different TS version, or a typo.
- **Fix**: `npx tsc --version` and check the option exists for that version; `npx tsc --showConfig`.

## tsconfig diagnosis quick table

| Symptom | Likely option | Set to |
|---|---|---|
| `import.meta` errors | `module` too old | `nodenext` / `es2020`+ |
| Relative imports need/forbid `.js` inconsistently | `moduleResolution` mismatch | match `module` (see SKILL #9) |
| Default import fails (TS1259) | `esModuleInterop` | `true` |
| Decorators error | `experimentalDecorators` / target | enable + `target` `es2022`+ |
| `process`/`__dirname` unknown | missing `@types/node` | `npm i -D @types/node` |
| Emit has wrong JS version | `target` | `es2022` for Node 20 |
| `.d.ts` not generated | `declaration` | `true` (+ `declarationMap` for nav) |

## Debugger attach recipes

### VS Code `launch.json`
```jsonc
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "node", "request": "launch", "name": "Debug TS (tsx)",
      "runtimeExecutable": "tsx", "program": "${workspaceFolder}/src/index.ts",
      "skipFiles": ["<node_internals>/**"], "console": "integratedTerminal"
    },
    {
      "type": "node", "request": "attach", "name": "Attach 9229",
      "port": 9229, "skipFiles": ["<node_internals>/**"], "sourceMaps": true
    }
  ]
}
```

### Chrome DevTools
```bash
node --inspect-brk dist/index.js   # then open chrome://inspect -> "inspect"
```
`--inspect-brk` halts on line 1 so you can set breakpoints before any code runs. Use `--inspect`
(no break) to attach to an already-running process via the printed `ws://` URL.

### Debugging a running prod process (carefully)
```bash
kill -USR1 <pid>     # tells Node to open the inspector on 127.0.0.1:9229 (legacy)
# Node 20+: start with --inspect=0.0.0.0:9229 behind a firewall, NEVER public.
```
Inspector port is RCE if exposed — bind to localhost and tunnel via SSH (`ssh -L 9229:localhost:9229`).
