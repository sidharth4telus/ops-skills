# Profiling & memory playbook (Node 20+)

How to find CPU bottlenecks, event-loop stalls, and memory leaks with real tools and the exact steps
to read their output.

## Decide what you're profiling

| Symptom | Tool | Output |
|---|---|---|
| One CPU core at 100%, latency up | CPU profiler (`--prof`, `--cpu-prof`, `clinic flame`) | hot functions |
| Requests queue but CPU low | event-loop delay monitor / `clinic doctor` | loop lag, GC, I/O |
| RSS climbs over hours, eventual OOM | heap snapshots (`--inspect`, `--heapsnapshot-signal`) | retained objects |
| Allocation churn / frequent GC | `--heap-prof` / allocation timeline in DevTools | allocation sites |

## CPU profiling

### Quickest: `--cpu-prof` (no setup)
```bash
node --cpu-prof --cpu-prof-dir=./prof app.js
# reproduce load, Ctrl-C -> writes ./prof/CPU.<date>.cpuprofile
# open in Chrome DevTools (Performance tab > Load profile) or VS Code (built-in viewer)
```

### `--prof` + `--prof-process`
```bash
node --prof app.js                       # writes isolate-0xNNN-NNN-v8.log
# drive traffic, stop the process, then:
node --prof-process isolate-*.log > processed.txt
```
Read `processed.txt`:
- **`Summary`** section: ticks split across JavaScript / C++ / GC. High **GC** ticks → allocation
  problem (go to memory section). High **JavaScript** → a hot JS function.
- **`Bottom up (heavy) profile`**: functions sorted by self-time. The top entry is your hot path.

### clinic.js (best first reach for "it's slow")
```bash
npx clinic doctor -- node app.js     # runs, then opens an HTML report with a diagnosis banner
npx clinic flame  -- node app.js     # CPU flamegraph
npx clinic bubbleprof -- node app.js # async-op latency (where time is spent waiting)
```
`clinic doctor` prints a recommendation: "event loop blocked", "GC pressure", "I/O bound", or
"healthy" — start there before going deeper.

### Live event-loop lag without restart
```js
const { monitorEventLoopDelay } = require('node:perf_hooks');
const h = monitorEventLoopDelay({ resolution: 20 });
h.enable();
setInterval(() => {
  console.log('loop delay ms  p50=%d p99=%d max=%d',
    +(h.percentile(50) / 1e6).toFixed(1),
    +(h.percentile(99) / 1e6).toFixed(1),
    +(h.max / 1e6).toFixed(1));
  h.reset();
}, 1000).unref();
```
p99 loop delay should be a few ms. Tens-to-hundreds of ms = a sync operation is blocking the loop.

### Common event-loop blockers and their fixes
| Blocker | Fix |
|---|---|
| `JSON.parse` of multi-MB payloads | stream-parse, or offload to a worker thread |
| Regex catastrophic backtracking | rewrite the regex; cap input length; use RE2 |
| `crypto.*Sync`, `zlib.*Sync`, `fs.*Sync` in hot paths | use async/promise variants |
| Big synchronous loops / array transforms | chunk with `setImmediate`, or a worker |
| `Buffer`/`JSON` work per request on large data | cache, paginate, or stream |

Offload CPU-bound work:
```ts
import { Worker } from 'node:worker_threads';
function runHeavy(payload: unknown): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const w = new Worker(new URL('./worker.js', import.meta.url), { workerData: payload });
    w.once('message', resolve);
    w.once('error', reject);
    w.once('exit', (code) => { if (code !== 0) reject(new Error(`worker exit ${code}`)); });
  });
}
```

## Memory leak hunting

### Step 1 — confirm it's a leak (vs. expected high usage)
```js
setInterval(() => {
  const m = process.memoryUsage();
  console.log('rss=%dMB heapUsed=%dMB external=%dMB',
    (m.rss / 1048576) | 0, (m.heapUsed / 1048576) | 0, (m.external / 1048576) | 0);
}, 5000).unref();
```
A leak shows `heapUsed` (or `external`/`rss`) trending **up and never coming back down** after GC,
under steady load. Sawtooth that returns to baseline is healthy.

### Step 2 — capture comparable snapshots
```bash
node --inspect app.js        # Chrome chrome://inspect -> Memory -> Heap snapshot
```
Procedure:
1. Take snapshot **A** at steady state.
2. Exercise the suspect code path **N times** (e.g. 1000 requests).
3. Force GC (DevTools trash-can icon), take snapshot **B**.
4. In B's dropdown choose **"Objects allocated between snapshot A and B"**.
5. Sort by **Retained Size**. The constructor that grew ~N× is the leak. Expand **Retainers** to see
   what holds it (the GC root chain).

Signal-triggered snapshot in prod (no inspector port needed):
```bash
node --heapsnapshot-signal=SIGUSR2 app.js
kill -USR2 <pid>             # writes Heap.<date>.heapsnapshot to cwd
```
Programmatic:
```js
const { writeHeapSnapshot } = require('node:v8');
writeHeapSnapshot();         // returns the filename; load it in DevTools
```

### Step 3 — common leak classes & fixes
| Leak | Tell-tale in snapshot | Fix |
|---|---|---|
| Unbounded cache (`Map`/object) | one `Map`/`Object` with huge retained size | LRU with max size + TTL; `WeakMap` if keyed by object |
| Listeners added per request | many closures retained by an `EventEmitter` | `once()` or pair `on()`/`off()`; `MaxListenersExceededWarning` is the early signal |
| Timers capturing big closures | `Timeout` objects retaining arrays | `clearInterval`/`clearTimeout` on shutdown; `.unref()` background timers |
| Global growing array/log buffer | a top-level array with N elements | bound it; flush/rotate |
| Closures over request/response | `IncomingMessage` retained long after request | don't store req/res in long-lived structures |

### Step 4 — allocation timeline (churn / GC pressure)
DevTools → Memory → **"Allocation instrumentation on timeline"** → record → the tall blue bars are
allocation bursts; click one to see the allocating stack. Or `node --heap-prof` and load the
`.heapprofile` in DevTools.

## Don't mistake these for leaks
- `--max-old-space-size` not set → default heap is ~2GB on 64-bit; large but legitimate working sets
  hit it. Set it to match the box.
- `external` / `arrayBuffer` growth is off-heap (Buffers, native addons) — heap snapshots won't show
  it; watch `process.memoryUsage().external` and check for un-freed Buffers / native handles.
- A warm cache that plateaus is fine — only unbounded monotonic growth is a leak.
