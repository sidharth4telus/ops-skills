# Python Debugging Playbook — full failure-mode catalog

Each entry: **error signature → minimal reproduction → confirm command → root cause → fix → verify.**
Default to Python 3.11+.

---

## A. Tracebacks & exceptions

### A1. `AttributeError: 'NoneType' object has no attribute 'x'`
- **Cause:** a function returned `None` (implicit) where an object was expected, or a dict `.get()` miss.
- **Confirm:** add `breakpoint()` at the failing frame; inspect the object: `p obj`.
- **Fix:** guard at the source; make functions return a sentinel or raise instead of falling off the end.
- **3.11 caret:** the `^^^^` under the line pinpoints which sub-expression is `None`.

### A2. `RecursionError: maximum recursion depth exceeded`
- **Cause:** missing/incorrect base case, or accidental infinite recursion (e.g. `__getattr__` calling itself).
- **Confirm:** `python -X dev` then read the repeating frame in the traceback.
- **Fix:** add base case; convert to iteration; for legit deep recursion `sys.setrecursionlimit(N)` *and*
  raise the OS thread stack (`threading.stack_size`) — but prefer iteration.

### A3. `ExceptionGroup` / `TaskGroup` traceback (3.11+)
```
+ Exception Group Traceback (most recent call last):
  | ExceptionGroup: unhandled errors in a TaskGroup (2 sub-exceptions)
  +-+---------------- 1 ----------------
    | ValueError: bad id
    +---------------- 2 ----------------
    | TimeoutError
```
- **Cause:** multiple concurrent tasks failed; `TaskGroup` aggregates them.
- **Fix:** handle with `except*`:
  ```python
  try:
      async with asyncio.TaskGroup() as tg: ...
  except* ValueError as eg:
      for e in eg.exceptions: ...
  except* TimeoutError:
      ...
  ```

### A4. Chained-exception confusion
- `During handling of the above exception, another exception occurred` → the **except block** itself threw.
  Fix the handler, not the original.
- `The above exception was the direct cause` → you did `raise New() from original`. Intentional wrap.
- To hide a noisy chain: `raise New() from None`.

---

## B. Imports & packaging

### B1. `ModuleNotFoundError: No module named 'X'`
- **Confirm which interpreter:** `python -c "import sys; print(sys.executable)"` then
  `python -m pip show X`. If empty, it's not installed *here*.
- **Causes & fixes:**
  - Wrong venv active → activate the project venv.
  - Installed for a different Python → reinstall in the right one (`python3.12 -m pip install X`).
  - Local package not installed → `pip install -e .` from project root (needs `pyproject.toml`).
  - Relying on CWD being on `sys.path` → don't; install the package.

### B2. `ImportError: cannot import name 'foo' from partially initialized module` (circular import)
- **Reproduce:**
  ```python
  # a.py
  from b import g
  def f(): return g()
  # b.py
  from a import f          # cycle: importing a triggers a importing b importing a…
  def g(): return f()
  ```
- **Fixes (preference order):** deferred import inside the function → `import module` not `from module import name`
  → extract shared code to a third module → `TYPE_CHECKING` for type-only imports.

### B3. `src/` layout not importable
- **Symptom:** tests import the package only when run from a specific dir.
- **Fix:** adopt src-layout and declare it:
  ```toml
  [tool.setuptools.packages.find]
  where = ["src"]
  ```
  then `pip install -e .`. Tests now import the installed package, not a path accident.

### B4. `Pipfile` / mixed tooling
- Pipenv (`Pipfile`/`Pipfile.lock`): `pipenv install`, `pipenv run pytest`, `pipenv --rm` to delete env.
- Migrating Pipenv→uv/poetry: export `pipenv requirements > requirements.txt`, then import into the new tool.

---

## C. Dependency resolution

### C1. `ResolutionImpossible` / conflicting versions
- **Confirm the conflict graph:**
  - pip: `pip install --dry-run 'a' 'b'` (shows what it would do / why it can't).
  - uv: `uv pip compile requirements.in` (prints the resolver's complaint precisely).
  - `pipdeptree` to see who requires the pinned transitive dep.
- **Fix:** loosen one constraint, pin the shared transitive dep to a compatible version, or split into
  two environments if genuinely incompatible.

### C2. "Works locally, breaks in CI"
- **Confirm:** `pip freeze` in both, diff. Different transitive versions = no lockfile.
- **Fix:** commit a lockfile; CI installs frozen: `uv sync --frozen` / `poetry install --sync` /
  `pip install -r requirements.txt` where requirements is fully pinned (use `pip-compile`/`uv pip compile`).

### C3. uv / poetry / venv cheat sheet
```bash
# uv
uv venv --python 3.12
uv pip install -e ".[dev]"
uv lock && uv sync --frozen
uv run pytest                     # run in the project env without activating
# poetry
poetry env use 3.12
poetry install --sync
poetry add 'httpx>=0.27,<1' && poetry lock
poetry run pytest
# nuke & rebuild (corruption)
rm -rf .venv && uv venv && uv pip sync requirements.txt
```

---

## D. asyncio

### D1. `RuntimeWarning: coroutine 'X' was never awaited`
- **Cause:** called a coroutine function without `await` / scheduling.
- **Confirm the exact line:** run with `python -W error::RuntimeWarning` to turn it into a raised exception
  with a full traceback.
- **Fix:** `await X()`; or `task = asyncio.create_task(X())` and later `await task`.

### D2. `RuntimeError: This event loop is already running`
- **Cause:** `asyncio.run()` (or `loop.run_until_complete`) called inside an already-running loop (Jupyter,
  some web frameworks).
- **Fix:** just `await` the coroutine; in notebooks `import nest_asyncio; nest_asyncio.apply()`.

### D3. Event loop stalls — one slow op freezes everything
- **Confirm:** `PYTHONASYNCIODEBUG=1` logs `Executing <Handle ...> took 0.512 seconds`.
- **Cause:** synchronous blocking call (`requests`, `time.sleep`, sync DB driver, CPU loop) on the loop.
- **Fix:** `await asyncio.to_thread(blocking_fn, *args)` or a `ProcessPoolExecutor` for CPU; switch to an
  async client (`httpx.AsyncClient`, `aiomysql`, etc.); `await asyncio.sleep()` not `time.sleep()`.

### D4. Disappearing tasks / swallowed exceptions
- **Cause:** `asyncio.create_task(coro())` with no reference → may be GC'd; or never awaited → its
  exception is logged only at GC ("Task exception was never retrieved").
- **Fix:** keep a strong reference, or use `asyncio.TaskGroup` (3.11+) which propagates failures and
  cancels siblings. For fan-out-and-collect, `asyncio.gather(*tasks, return_exceptions=True)`.

---

## E. Encoding

### E1. `UnicodeDecodeError: 'utf-8' codec can't decode byte 0x.. `
- **Confirm the real encoding:** `file thefile`; `python -c "print(open('f','rb').read(16))"`;
  `python -m charset_normalizer thefile` (or `chardet`).
- **Fixes:** `open(path, encoding="utf-8")` (always specify!); `errors="replace"`/`"ignore"` to tolerate;
  `encoding="utf-8-sig"` for BOM; `PYTHONUTF8=1` / `python -X utf8` to default to UTF-8 platform-wide.

### E2. `UnicodeEncodeError` writing to stdout/file
- **Cause:** target encoding (often platform default / `latin-1`) can't represent the char.
- **Fix:** `print(..., file=open(p, "w", encoding="utf-8"))`; set `PYTHONIOENCODING=utf-8` for stdout;
  on Windows consoles use UTF-8 mode.

---

## F. Tests (pytest)

### F1. Slow suite
- `pytest --durations=10` → find the slow tests.
- Parallelize `pytest -n auto` (pytest-xdist); promote expensive fixtures to `scope="session"`; mock
  network/sleep; reuse DB containers across the session.

### F2. Flaky / order-dependent
- Toggle randomization: with pytest-randomly, compare `pytest` vs `pytest -p no:randomly`.
- `pytest --lf` reruns last failures; `pytest test::case` runs in isolation. If it passes alone but fails
  in the suite → **leaking state** (global singletons, unclosed fixtures, monkeypatch not undone, files in
  a fixed dir instead of `tmp_path`).
- Time/RNG/network heisenbugs: `freezegun` to freeze time, seed RNG, `responses`/`respx` to mock HTTP.

### F3. Hangs
- `pytest --timeout=30` (pytest-timeout) to surface where; usually a never-resolving `await`, a deadlock,
  or a real network call that should be mocked.

---

## G. Logging

### G1. Nothing prints
- Root logger defaults to WARNING; `info`/`debug` are dropped until you configure a handler.
- `logging.basicConfig(level=logging.INFO, force=True)` **once**, at the entrypoint, before other logging.
- `force=True` resets handlers added by an earlier (e.g. library) `basicConfig`.

### G2. Duplicate log lines
- **Cause:** handler added multiple times (e.g. `basicConfig` + a manual handler, or module imported
  twice), or child logger propagating to root which also has a handler.
- **Fix:** configure handlers once; set `logger.propagate = False` on a logger that has its own handler;
  guard handler-adding code with `if not logger.handlers`.

### G3. Logs from a library you don't control
- Set its level explicitly: `logging.getLogger("urllib3").setLevel(logging.WARNING)`. If it attached a
  `NullHandler` and you want its output, add your own handler to that logger and `propagate=True`.
