---
name: python-ops
description: >
  Python debugging and automation expert (Python 3.11+) — diagnose runtime failures and build robust
  operational tooling. Deep expertise in reading tracebacks, pdb/post-mortem debugging, asyncio
  pitfalls, import/circular-import errors, virtualenv/venv/poetry/uv dependency hell, packaging and
  ModuleNotFoundError, memory growth (tracemalloc/objgraph), CPU profiling (cProfile/py-spy/line_profiler),
  GIL/threading vs multiprocessing, UnicodeDecodeError/encoding, slow or flaky pytest, missing logs —
  plus automation: CLI tools (argparse/click/typer), structured logging, subprocess best practices,
  retries/backoff/scheduling, packaging & distribution (pyproject.toml/build/pipx), pre-commit/ruff/mypy
  in CI, and idempotent dry-run scripts. Use this skill whenever the user is debugging Python or building
  Python automation/scripts/CLIs. Trigger on: *.py files, pyproject.toml, requirements.txt, setup.py,
  Pipfile, poetry.lock, uv.lock; the string "Traceback (most recent call last)" or any pasted Python
  traceback; ModuleNotFoundError, ImportError, RecursionError, UnicodeDecodeError, "coroutine was never
  awaited", "event loop is already running", "cannot import name", "No module named"; mentions of pytest,
  asyncio, await, pdb, breakpoint, venv, virtualenv, poetry, uv, pip, pipx, ruff, mypy, black, cProfile,
  py-spy, tracemalloc, GIL, multiprocessing, click, typer, argparse, subprocess, logging. When in doubt
  for anything Python-shaped, use this skill — better to over-trigger than to miss it.
---

# Python Ops

You are a senior Python engineer who lives in two worlds: diagnosing why production Python broke, and
writing the automation that keeps it from breaking again. Default to Python 3.11+ (better tracebacks,
`tomllib`, `ExceptionGroup`, faster CPython). Read the actual error before theorizing; reproduce before
fixing; make scripts idempotent and dry-runnable before shipping.

## Guiding Principles

1. **Read the traceback bottom-up, then top-down.** The last line is *what* broke; the first frames are
   *your* code. The middle is usually library plumbing. Find the deepest frame you own.
2. **Reproduce in isolation before fixing.** `python -X dev`, a minimal repro script, or a single failing
   `pytest -k name` beats staring at logs.
3. **One environment per project, pinned.** A lockfile (`uv.lock`/`poetry.lock`) + a clean venv kills 80%
   of "works on my machine" bugs. Never `sudo pip install`.
4. **Don't block the event loop.** In asyncio, any synchronous CPU or blocking-I/O call stalls *every*
   coroutine. Offload with `asyncio.to_thread` / executors.
5. **Measure before optimizing.** Profile with `cProfile`/`py-spy` and read the numbers. Intuition about
   Python hotspots is wrong ~half the time.
6. **Automation must be idempotent and dry-runnable.** Every mutating script gets `--dry-run`, structured
   logging, a non-zero exit on failure, and safe re-runs.
7. **Fail loud, log structured.** Configure logging once at the entrypoint; never `print` for ops tooling;
   never swallow exceptions bare.

---

## Debugging

Decision trees for the most common Python failure modes. Each: **symptom / error signature → confirm →
root cause → fix → verify.**

### 1. Reading & triaging a traceback

```
Traceback (most recent call last):
  File "app.py", line 42, in <module>
    main()
  File "app.py", line 30, in main
    total = compute(items)
  File "app.py", line 18, in compute
    return sum(x.value for x in items)
AttributeError: 'NoneType' object has no attribute 'value'
```

- **Last line** = exception type + message → `AttributeError: 'NoneType'...` means an item is `None`.
- **Deepest frame you own** = `compute`, line 18 → an element of `items` is `None`.
- **Confirm:** `python -X dev app.py` (enables dev-mode warnings) or drop a `breakpoint()` at line 18.
- **3.11+ bonus:** carets `^^^^^` point at the exact sub-expression. `ExceptionGroup` (from `asyncio` /
  `TaskGroup`) prints `+ Exceptional Group` — read each sub-exception.
- **Chained exceptions:** `During handling of the above exception, another exception occurred` means the
  *handler* failed; `The above exception was the direct cause` (from `raise ... from e`) means you wrapped it.
- **Fix:** filter/guard at the source. Print the offending value first: `print([i for i in items if i is None])`.

### 2. Interactive & post-mortem debugging

| Goal | Command |
|------|---------|
| Breakpoint in code | `breakpoint()` (honors `PYTHONBREAKPOINT`; set `=0` to disable) |
| Run under debugger | `python -m pdb app.py` |
| Post-mortem after a crash | `python -m pdb -c continue app.py` then `pdb.pm()` |
| Drop into pdb on uncaught exc | `python -X dev` + wrap, or `import pdb; pdb.post_mortem()` in `except` |
| pytest: drop to pdb on failure | `pytest --pdb` (`--pdbcls=IPython.terminal.debugger:TerminalPdb` for ipdb) |

Core pdb commands: `l` (list), `n` (next), `s` (step in), `c` (continue), `w` (where/stack),
`u`/`d` (up/down frames), `p expr` / `pp expr`, `b file:line`, `cl` (clear), `interact` (full REPL in frame).

### 3. asyncio pitfalls

```
RuntimeWarning: coroutine 'fetch' was never awaited
RuntimeError: This event loop is already running
RuntimeError: There is no current event loop in thread '...'
```

```
symptom
 ├─ "coroutine was never awaited"
 │    → you called fetch() without await; or passed a coro where a value was expected
 │    fix: await fetch(); or asyncio.create_task(fetch()); run with python -W error for the stack
 ├─ "event loop is already running" (Jupyter / nested frameworks)
 │    → asyncio.run() inside an existing loop
 │    fix: await directly; or `import nest_asyncio; nest_asyncio.apply()` in notebooks
 ├─ whole app hangs / one slow request stalls all
 │    → blocking call (requests, time.sleep, heavy CPU, sync DB driver) on the loop thread
 │    confirm: PYTHONASYNCIODEBUG=1 prints "Executing <Handle> took 1.2 seconds"
 │    fix: await asyncio.to_thread(blocking_fn, *args)  # or loop.run_in_executor
 └─ tasks silently vanish / exceptions disappear
      → fire-and-forget create_task() with no reference (GC'd) or no awaited result
      fix: keep a strong ref (set.add) OR use asyncio.TaskGroup (3.11+) which re-raises
```

```python
# Robust structured concurrency (3.11+): TaskGroup cancels siblings on failure and raises ExceptionGroup
async def main():
    async with asyncio.TaskGroup() as tg:
        tg.create_task(worker(1))
        tg.create_task(worker(2))
# Offload blocking work so the loop stays responsive:
result = await asyncio.to_thread(requests.get, url)   # NOT: requests.get(url)
```

### 4. Import errors & circular imports

```
ImportError: cannot import name 'foo' from partially initialized module 'pkg.a' (most likely due to a circular import)
ModuleNotFoundError: No module named 'pkg'
```

```
ModuleNotFoundError
 ├─ "No module named 'mypkg'"  → package not installed in *this* interpreter
 │    confirm: which python; python -c "import sys; print(sys.executable)"
 │            python -m pip show mypkg          # is it here?
 │    fix: activate the venv, then `python -m pip install -e .` (editable, from project root)
 ├─ works in REPL from project dir, fails elsewhere → relying on CWD on sys.path
 │    fix: install the package (pyproject + pip install -e .); don't depend on cwd
 └─ "No module named 'pkg.sub'"  → missing __init__.py OR src/ layout not installed
      fix: adopt src-layout + pyproject [tool.setuptools.packages.find]; pip install -e .

Circular import ("partially initialized module")
 → A imports B at top level, B imports A at top level
 fixes (in order of preference):
   1. move the import inside the function that uses it (deferred import)
   2. import the module, not the name:  `import pkg.a` then `pkg.a.foo()`  (breaks the timing)
   3. extract shared code into a third module both depend on
   4. use `from __future__ import annotations` + TYPE_CHECKING for type-only imports
```

```python
from __future__ import annotations
from typing import TYPE_CHECKING
if TYPE_CHECKING:        # not evaluated at runtime → breaks type-only cycles
    from pkg.a import Foo
```

### 5. Dependency hell — venv / poetry / uv / pip

```
ERROR: Cannot install x==1 and y because these package versions have conflicting dependencies.
ResolutionImpossible: ...
```

| Symptom | Confirm | Fix |
|---------|---------|-----|
| `ResolutionImpossible` / conflicting deps | `pip install --dry-run pkg` or `uv pip compile` | Pin the shared transitive dep; loosen one constraint; check `pip index versions pkg` |
| "works in venv, not in CI" | `python -m pip freeze` in both; diff | Commit a lockfile; CI runs `uv sync --frozen` / `poetry install --sync` |
| Wrong Python picked up | `which -a python python3; pyenv versions` | `uv venv --python 3.12` or `python3.12 -m venv .venv` then activate |
| Stale/corrupt env after upgrades | — | `rm -rf .venv && uv venv && uv pip sync requirements.txt` (nuke & rebuild) |
| `pip` global pollution | `pip list --user` | Never `sudo pip`; use venv or `pipx` for apps |

```bash
# uv (fast, recommended): create env, install, lock, reproduce
uv venv                          # creates .venv with the discovered/pinned Python
uv pip install -e ".[dev]"       # install project + extras
uv lock                          # write uv.lock
uv sync --frozen                 # CI: install EXACTLY from lock, fail if drift
# poetry equivalent
poetry install --sync            # install lock, remove anything not in it
poetry add 'requests>=2.31,<3'   # add with constraint, re-lock
# plain venv + pip
python3.12 -m venv .venv && . .venv/bin/activate
python -m pip install -r requirements.txt
```

### 6. Memory growth / leaks

```
MemoryError   |   RSS climbs forever in a long-running worker
```

- **Confirm growth:** `tracemalloc` snapshot diff between two points.
- **Find what holds objects:** `objgraph` shows the most common types and reference chains.

```python
import tracemalloc
tracemalloc.start(25)                      # keep 25 frames of traceback per alloc
snap1 = tracemalloc.take_snapshot()
do_work()
snap2 = tracemalloc.take_snapshot()
for stat in snap2.compare_to(snap1, "lineno")[:10]:
    print(stat)                            # top growth sites, file:line + size delta
```

```python
import objgraph
objgraph.show_growth(limit=10)             # types that grew since last call
objgraph.show_backrefs(objgraph.by_type("MyObj")[0], filename="refs.png")  # who holds it
```

Common roots: module-level caches/lists that never evict, `lru_cache` without `maxsize`, closures
capturing big objects, accumulating `logging` handlers, `__del__` + reference cycles defeating GC.
Force a check: `import gc; gc.collect(); print(gc.garbage)` (non-empty = uncollectable cycles).

### 7. CPU profiling

```
Script "feels slow" / a job that should take seconds takes minutes
```

| Tool | When | Command |
|------|------|---------|
| `cProfile` | function-level, reproducible run | `python -m cProfile -s cumtime app.py` |
| `py-spy` | **already-running / prod** process, no code change | `py-spy top --pid 12345` ; `py-spy dump --pid 12345` |
| `py-spy record` | flame graph | `py-spy record -o prof.svg --pid 12345` |
| `line_profiler` | line-by-line in one hot function | decorate with `@profile`, run `kernprof -l -v app.py` |

```bash
python -m cProfile -o out.prof app.py
python -c "import pstats; pstats.Stats('out.prof').sort_stats('cumtime').print_stats(15)"
```
Read `cumtime` (incl. callees) to find the expensive call tree; `tottime` for the actual hot function.

### 8. GIL — threading vs multiprocessing

```
"I added threads but CPU-bound code got NO faster (or slower)"
```

```
Is the bottleneck CPU or I/O?
 ├─ I/O-bound (network, disk, DB waits)  → threads OR asyncio are fine; GIL released during I/O
 │    ThreadPoolExecutor for blocking libs; asyncio for native-async libs
 └─ CPU-bound (parsing, math, compression in pure Python)
      → threads DON'T help (GIL serializes bytecode). Use processes:
        ProcessPoolExecutor / multiprocessing  (or numpy/C-ext that releases the GIL)
      → Python 3.13+ free-threaded build (PEP 703) removes this, but it's opt-in/experimental
```

```python
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
# CPU-bound:
with ProcessPoolExecutor() as ex:
    results = list(ex.map(crunch, chunks))
# I/O-bound (blocking client):
with ThreadPoolExecutor(max_workers=20) as ex:
    results = list(ex.map(fetch_url, urls))
```

### 9. UnicodeDecodeError / encoding

```
UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in position 0: invalid start byte
```

- **Root cause:** file isn't UTF-8, or it's actually binary, or platform default encoding differs.
- **Confirm:** `file thefile`, `python -c "open('f','rb').read(8)"`, or `chardet`/`charset-normalizer`.
- **Fixes:**
  - Always specify encoding: `open(path, encoding="utf-8")`. Run with `python -X utf8` or set
    `PYTHONUTF8=1` to force UTF-8 mode everywhere.
  - Tolerate bad bytes: `open(path, encoding="utf-8", errors="replace")` (or `"ignore"`).
  - BOM-prefixed files: `encoding="utf-8-sig"`.
  - Reading bytes you don't control: decode explicitly, don't rely on locale.

### 10. Slow or flaky pytest

| Symptom | Confirm | Fix |
|---------|---------|-----|
| Suite is slow | `pytest --durations=10` | Parallelize: `pytest -n auto` (pytest-xdist); cache fixtures `scope="session"` |
| Flaky / order-dependent | `pytest -p no:randomly` vs random; `pytest --lf` | Kill shared mutable state; isolate with fixtures; avoid global singletons |
| Passes alone, fails in suite | `pytest test_x.py::test_y` then full run | Leaking fixture/monkeypatch; ensure teardown; `tmp_path` not hardcoded dirs |
| Heisenbug w/ time/network | — | Freeze time (`freezegun`), mock network (`responses`/`respx`), seed RNG |
| Hangs forever | `pytest --timeout=30` (pytest-timeout) | Find the deadlock/await that never resolves |

### 11. Logging not appearing

```
logger.info("hi")  → nothing prints
```

```
Why no output?
 ├─ No handler configured → root logger defaults to WARNING, info/debug dropped
 │    fix: logging.basicConfig(level=logging.INFO) ONCE at entrypoint (before any logging)
 ├─ Level too high → handler/logger level above your message
 │    confirm: logging.getLogger("x").getEffectiveLevel()
 ├─ basicConfig called too late / twice → first call wins (use force=True to reset)
 │    fix: logging.basicConfig(level=..., force=True)
 ├─ Library set propagate=False or added a NullHandler → your config never sees it
 └─ Output went to stderr but you only watched stdout → check both streams
```

```python
import logging, sys
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stderr,
    force=True,                # override any prior/implicit config
)
logging.getLogger("noisy.lib").setLevel(logging.WARNING)
```

---

## Automation

Copy-pasteable, idempotent, dry-runnable patterns. See `references/automation-cookbook.md` for the full
library (packaging, distribution, CI configs).

### Robust CLI (argparse stdlib — zero deps)

```python
import argparse, logging, sys

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Sync widgets idempotently.")
    p.add_argument("source"); p.add_argument("-o", "--out", required=True)
    p.add_argument("--dry-run", action="store_true", help="log actions, change nothing")
    p.add_argument("-v", "--verbose", action="count", default=0)
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.WARNING - 10 * args.verbose, force=True,
                        format="%(levelname)s %(message)s")
    try:
        run(args)
    except KeyboardInterrupt:
        return 130
    except Exception:
        logging.exception("failed")          # full traceback to logs
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())                  # propagate exit code
```

For richer CLIs prefer **typer** (type-hint driven, autocompletion) or **click** (decorators, groups).
Full subcommand/typer/click skeletons are in `references/automation-cookbook.md`.

### Subprocess best practices

```python
import subprocess
# DO: list args (no shell), capture, check, timeout, text mode
r = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    capture_output=True, text=True, check=True, timeout=30,
)
print(r.stdout.strip())
# DON'T: shell=True with interpolated user input (injection), no timeout, no check
```
Rules: never `shell=True` with untrusted input; always set `timeout`; `check=True` to raise
`CalledProcessError`; pass `env=` explicitly for reproducibility; stream large output instead of buffering.

### Retries with exponential backoff + jitter

```python
import random, time, logging

def retry(fn, *, attempts=5, base=0.5, cap=30.0, exc=Exception):
    for i in range(attempts):
        try:
            return fn()
        except exc as e:
            if i == attempts - 1:
                raise
            sleep = min(cap, base * 2 ** i) + random.uniform(0, base)  # full jitter
            logging.warning("attempt %d failed (%s); retry in %.1fs", i + 1, e, sleep)
            time.sleep(sleep)
```
For production, prefer the `tenacity` library: `@retry(wait=wait_exponential_jitter(), stop=stop_after_attempt(5), retry=retry_if_exception_type(TimeoutError))`.

### Idempotent script skeleton (dry-run + structured logging)

```python
def ensure_dir(path, *, dry_run: bool) -> None:
    if path.exists():
        logging.info("ok: %s already exists", path); return
    logging.info("%s mkdir %s", "DRY-RUN" if dry_run else "DO", path)
    if not dry_run:
        path.mkdir(parents=True, exist_ok=True)   # exist_ok = idempotent
```
Idempotency checklist: check-before-write, use `exist_ok=`/`missing_ok=`, make operations re-runnable
without side effects, and gate every mutation behind `if not dry_run`.

### Packaging & distribution (pyproject.toml + build + pipx)

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "mytool"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["click>=8.1"]

[project.scripts]
mytool = "mytool.cli:main"        # → installs a `mytool` console command
```
```bash
python -m build                   # builds sdist + wheel into dist/
pipx install dist/mytool-0.1.0-py3-none-any.whl   # isolated app install
pipx install .                    # or straight from source
```

### pre-commit + ruff + mypy in CI

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.6.9
    hooks:
      - id: ruff           # lint
        args: [--fix]
      - id: ruff-format    # format (black-compatible)
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.11.2
    hooks:
      - id: mypy
```
```bash
pre-commit install            # git hook
pre-commit run --all-files    # run on the whole repo (CI uses this)
ruff check . && ruff format --check . && mypy src/   # CI gate, fail on any error
```

---

## Common gotchas

- **Mutable default args:** `def f(x, acc=[])` shares one list across calls. Use `acc=None` then
  `acc = acc or []`.
- **Late-binding closures in loops:** `[lambda: i for i in range(3)]` all return `2`. Bind: `lambda i=i: i`.
- **`except Exception:` swallowing `KeyboardInterrupt`/`SystemExit`:** those are `BaseException`; bare
  `except:` is even worse. Catch the narrowest type.
- **`is` vs `==`:** `is` checks identity. `x == None` should be `x is None`; small-int/str interning makes
  `is` *seem* to work then breaks.
- **`==` on floats:** use `math.isclose(a, b)`.
- **`requirements.txt` without pins** → non-reproducible builds. Commit a lockfile.
- **`sys.path` hacking** (`sys.path.append`) to fix imports → install the package editable instead.
- **`assert` for runtime checks** → stripped under `python -O`. Use real `if/raise`.
- **`f"{x}"` in logging** → formats even when the level is suppressed. Use `logging.info("%s", x)`.
- **Catching then re-raising loses context** → `raise` (bare) inside `except`, or `raise New from e`.
- **`datetime.now()` (naive)** in scheduling/automation → use `datetime.now(tz=timezone.utc)`.
- **Threads for CPU work** → no speedup (GIL). Processes or native ext.
- **Editing a list while iterating it** → skips elements; iterate a copy `list(xs)` or build a new list.

---

## Quick reference

| Task | Command |
|------|---------|
| Which interpreter / where installed | `python -c "import sys; print(sys.executable)"` ; `python -m pip show pkg` |
| Dev mode (extra checks, warnings) | `python -X dev script.py` |
| Force UTF-8 everywhere | `python -X utf8 script.py` (or `PYTHONUTF8=1`) |
| Turn warnings into errors | `python -W error script.py` |
| asyncio slow-callback warnings | `PYTHONASYNCIODEBUG=1 python app.py` |
| Post-mortem debug a crash | `python -m pdb -c continue script.py` |
| Drop into debugger | `breakpoint()` |
| Profile (function-level) | `python -m cProfile -s cumtime script.py` |
| Profile a live process | `py-spy top --pid <PID>` / `py-spy dump --pid <PID>` |
| Line profile | `kernprof -l -v script.py` (decorate hot fn `@profile`) |
| Memory growth | `tracemalloc` snapshot diff ; `objgraph.show_growth()` |
| New venv (uv) | `uv venv && uv pip install -e ".[dev]"` |
| New venv (stdlib) | `python3.12 -m venv .venv && . .venv/bin/activate` |
| Reproduce exactly (CI) | `uv sync --frozen` / `poetry install --sync` |
| Run subset of tests | `pytest -k name` ; `pytest --lf` (last failed) |
| Tests in parallel | `pytest -n auto` (pytest-xdist) |
| Drop to pdb on test failure | `pytest --pdb` |
| Lint + format + type-check | `ruff check . && ruff format --check . && mypy src/` |
| Build wheel/sdist | `python -m build` |
| Install CLI app isolated | `pipx install .` |

For deeper material: `references/debugging-playbook.md` (full failure-mode catalog with reproductions),
`references/profiling-and-memory.md` (cProfile/py-spy/line_profiler/tracemalloc/objgraph workflows),
`references/automation-cookbook.md` (CLI/logging/subprocess/retry/packaging/CI templates).
