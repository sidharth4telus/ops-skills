# Profiling & Memory — workflows

How to find *where* Python spends time and *what* holds memory. Measure first; never guess.

---

## 1. Decide what kind of slow

```
Is the process slow or is it leaking?
 ├─ slow (CPU / wall-clock)        → §2 cProfile (offline) or §3 py-spy (live)
 ├─ slow but mostly waiting on I/O → §2 with cumtime; look for blocking calls / serial requests
 ├─ one function is hot            → §4 line_profiler
 └─ RSS keeps climbing             → §5 tracemalloc + §6 objgraph
```

---

## 2. cProfile — function-level, reproducible

```bash
python -m cProfile -s cumtime myscript.py            # quick, sorted by cumulative time
python -m cProfile -o out.prof myscript.py           # save for analysis
python -c "import pstats; pstats.Stats('out.prof').sort_stats('cumtime').print_stats(20)"
```
- `cumtime` = time in the function **including** everything it calls → find the expensive call *tree*.
- `tottime` = time in the function **excluding** callees → find the actual hot function.
- `ncalls` huge with tiny `percall` → death by a thousand calls (often N+1 or per-row work).
- Visualize: `pip install snakeviz && snakeviz out.prof` (browser flame/icicle).
- In-code, profile a region only:
  ```python
  import cProfile, pstats
  pr = cProfile.Profile(); pr.enable()
  hot_region()
  pr.disable(); pstats.Stats(pr).sort_stats("tottime").print_stats(15)
  ```

---

## 3. py-spy — sample a LIVE process (no code change, no restart)

Best tool for production: it attaches to a running PID and samples the C stack; near-zero overhead and
**no instrumentation**.
```bash
pip install py-spy
py-spy top --pid 12345                      # live top-like view of hot functions
py-spy dump --pid 12345                     # one-shot stack of every thread (great for hangs/deadlocks)
py-spy record -o profile.svg --pid 12345 --duration 30   # flame graph
py-spy record -o profile.svg -- python myscript.py        # or launch + record
```
- A process **stuck** (not slow, frozen)? `py-spy dump` shows exactly which line every thread is parked on
  (lock, socket recv, etc.).
- May need elevated privileges to attach (`sudo`, or `--cap-add SYS_PTRACE` in containers).

---

## 4. line_profiler — line-by-line inside one function

```bash
pip install line_profiler
```
```python
@profile                       # injected by kernprof; no import needed
def hot(): ...
```
```bash
kernprof -l -v myscript.py     # -l line mode, -v print results
```
Output shows `% Time` per line — pinpoints the exact expensive statement (a regex recompiled in a loop,
an O(n) `in list`, a `.append` triggering reallocations, etc.).

---

## 5. tracemalloc — where memory was allocated (stdlib)

```python
import tracemalloc
tracemalloc.start(25)                       # 25 = frames of traceback kept per allocation

snap1 = tracemalloc.take_snapshot()
run_workload()
snap2 = tracemalloc.take_snapshot()

top = snap2.compare_to(snap1, "lineno")     # growth between the two points
for stat in top[:10]:
    print(stat)                             # file:line  +N KiB  (+count)

# Full traceback for the single biggest grower:
biggest = top[0]
for line in biggest.traceback.format():
    print(line)
```
- Take snapshots at the *same logical point* across iterations of a long-running loop; growing deltas =
  leak. Stable deltas = steady-state (fine).
- `tracemalloc` only tracks Python-level allocations (not C extensions' own heaps).

---

## 6. objgraph — what *holds* the objects

```python
import objgraph
objgraph.show_growth(limit=10)              # types that grew since the last call → run twice
objgraph.show_most_common_types(limit=15)   # snapshot of the heap by type

# Why isn't MyObj being collected? Show the reference chain keeping it alive:
obj = objgraph.by_type("MyObj")[-1]
objgraph.show_backrefs([obj], max_depth=5, filename="backrefs.png")
```
Typical culprits the backref graph reveals: a module-level list/dict cache, an unbounded `functools.lru_cache`,
a registry/observer that never unregisters, closures capturing large objects, or a logging handler list.

---

## 7. Garbage collector & reference cycles

```python
import gc
gc.collect()
print(gc.garbage)                           # objects with __del__ in uncollectable cycles
gc.set_debug(gc.DEBUG_SARTH := gc.DEBUG_LEAK)   # verbose leak reporting (dev only)
```
- Reference cycles are normally collected — **unless** they involve objects with a `__del__` finalizer
  (pre-3.4 rules) or C-level cycles. Prefer `weakref` for back-references and caches (`weakref.WeakValueDictionary`).
- A common "leak" is just delayed collection; force `gc.collect()` before measuring.

---

## 8. Quick decision table

| Observation | Tool | Next move |
|-------------|------|-----------|
| "Script slow", can re-run | `cProfile -s cumtime` | inspect call tree, find biggest `cumtime` |
| Prod process slow, can't restart | `py-spy top --pid` | identify hot frame live |
| Process frozen / deadlocked | `py-spy dump --pid` | see where each thread is parked |
| One known-hot function | `line_profiler` | find the expensive line |
| RSS grows over hours | `tracemalloc` snapshot diff | find growing alloc site |
| Object won't free | `objgraph.show_backrefs` | find the referrer holding it |
| Cycles suspected | `gc.collect()`, `gc.garbage` | break cycle with `weakref` |
