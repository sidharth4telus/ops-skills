# Automation Cookbook — copy-pasteable templates

Production-grade, idempotent, dry-runnable. Python 3.11+.

---

## 1. CLI tools

### argparse (stdlib, zero deps) — full skeleton with subcommands
```python
import argparse, logging, sys

def cmd_sync(args: argparse.Namespace) -> int:
    logging.info("sync %s -> %s (dry_run=%s)", args.source, args.dest, args.dry_run)
    return 0

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mytool", description="Ops helper.")
    p.add_argument("-v", "--verbose", action="count", default=0)
    p.add_argument("--dry-run", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync", help="sync source to dest")
    s.add_argument("source"); s.add_argument("dest")
    s.set_defaults(func=cmd_sync)
    return p

def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=max(logging.DEBUG, logging.WARNING - 10 * args.verbose),
                        format="%(levelname)s %(message)s", force=True)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
    except Exception:
        logging.exception("command failed")
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
```

### typer (type-hint driven; recommended for new tools)
```python
import typer, logging
app = typer.Typer(add_completion=True, no_args_is_help=True)

@app.command()
def sync(source: str, dest: str, dry_run: bool = typer.Option(False, "--dry-run"),
         verbose: int = typer.Option(0, "-v", "--verbose", count=True)):
    """Sync source to dest (idempotent)."""
    logging.basicConfig(level=logging.WARNING - 10 * verbose, force=True)
    logging.info("sync %s -> %s dry_run=%s", source, dest, dry_run)

if __name__ == "__main__":
    app()
```

### click (decorators / plugin groups)
```python
import click
@click.group()
@click.option("--dry-run", is_flag=True)
@click.pass_context
def cli(ctx, dry_run):
    ctx.obj = {"dry_run": dry_run}

@cli.command()
@click.argument("source"); @click.argument("dest")
@click.pass_obj
def sync(obj, source, dest):
    click.echo(f"sync {source} -> {dest} (dry_run={obj['dry_run']})")

if __name__ == "__main__":
    cli()
```

---

## 2. Structured logging

### JSON logs (no deps — custom formatter)
```python
import json, logging, sys, datetime as dt

class JsonFormatter(logging.Formatter):
    def format(self, r: logging.LogRecord) -> str:
        payload = {
            "ts": dt.datetime.fromtimestamp(r.created, dt.timezone.utc).isoformat(),
            "level": r.levelname, "logger": r.name, "msg": r.getMessage(),
        }
        if r.exc_info:
            payload["exc"] = self.formatException(r.exc_info)
        for k, v in getattr(r, "extra_fields", {}).items():
            payload[k] = v
        return json.dumps(payload)

def configure_logging(level=logging.INFO):
    h = logging.StreamHandler(sys.stderr)
    h.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [h]            # idempotent: replace, don't append
    root.setLevel(level)

# add context per call:
logging.info("processed", extra={"extra_fields": {"order_id": 42, "rows": 1000}})
```
For richer needs use **structlog** or **loguru**. Always configure **once** at the entrypoint.

---

## 3. Subprocess

```python
import subprocess

def run(cmd: list[str], *, cwd=None, env=None, timeout=60) -> str:
    r = subprocess.run(cmd, cwd=cwd, env=env, timeout=timeout,
                       capture_output=True, text=True, check=True)
    return r.stdout

# Streaming large output line-by-line (don't buffer GBs):
with subprocess.Popen(["long-job"], stdout=subprocess.PIPE, text=True) as p:
    assert p.stdout is not None
    for line in p.stdout:
        handle(line.rstrip())
    if p.wait() != 0:
        raise subprocess.CalledProcessError(p.returncode, "long-job")
```
Rules: **list args, never `shell=True` with untrusted input**; always `timeout=`; `check=True`;
pass `env=` explicitly (start from `os.environ.copy()`); avoid `capture_output` for huge streams.

---

## 4. Retries / backoff / scheduling

### Hand-rolled exponential backoff with full jitter
```python
import random, time, logging
from typing import Callable, TypeVar
T = TypeVar("T")

def retry(fn: Callable[[], T], *, attempts=5, base=0.5, cap=30.0,
          exc: tuple[type[BaseException], ...] = (Exception,)) -> T:
    for i in range(attempts):
        try:
            return fn()
        except exc as e:
            if i == attempts - 1:
                raise
            delay = min(cap, base * 2 ** i) + random.uniform(0, base)
            logging.warning("attempt %d/%d failed: %s; sleeping %.2fs", i + 1, attempts, e, delay)
            time.sleep(delay)
    raise AssertionError("unreachable")
```

### tenacity (recommended)
```python
from tenacity import retry, stop_after_attempt, wait_exponential_jitter, retry_if_exception_type
@retry(stop=stop_after_attempt(5),
       wait=wait_exponential_jitter(initial=0.5, max=30),
       retry=retry_if_exception_type((TimeoutError, ConnectionError)),
       reraise=True)
def call_api(): ...
```

### Scheduling
- One-off / recurring on a host: **cron** calling the CLI, or a **systemd timer** (preferred — logs to
  journal, handles missed runs with `Persistent=true`).
- In-process recurring jobs: **APScheduler** (`BackgroundScheduler().add_job(fn, "interval", minutes=5)`).
- Always make the job **idempotent** so a double-fire or retry is harmless.

---

## 5. Idempotent script pattern

```python
from pathlib import Path
import logging, shutil

def ensure_symlink(link: Path, target: Path, *, dry_run: bool) -> None:
    if link.is_symlink() and link.readlink() == target:
        logging.info("ok: %s already -> %s", link, target); return
    logging.info("%s ln -sfn %s %s", "DRY-RUN" if dry_run else "DO", target, link)
    if dry_run:
        return
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(target)

def copy_if_changed(src: Path, dst: Path, *, dry_run: bool) -> None:
    if dst.exists() and dst.read_bytes() == src.read_bytes():
        logging.info("ok: %s unchanged", dst); return
    logging.info("%s cp %s %s", "DRY-RUN" if dry_run else "DO", src, dst)
    if not dry_run:
        shutil.copy2(src, dst)
```
Checklist: read current state → compare to desired → log intended action → mutate only `if not dry_run` →
use `exist_ok=`/`missing_ok=`/`parents=True` so re-runs are safe.

---

## 6. Packaging & distribution

### pyproject.toml (PEP 621, hatchling backend)
```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "mytool"
version = "0.2.0"
description = "Ops tooling"
requires-python = ">=3.11"
readme = "README.md"
dependencies = ["click>=8.1", "tenacity>=8.2"]

[project.optional-dependencies]
dev = ["pytest>=8", "ruff>=0.6", "mypy>=1.11", "build", "pytest-xdist"]

[project.scripts]
mytool = "mytool.cli:main"        # console entry point → `mytool` on PATH

[tool.hatch.build.targets.wheel]
packages = ["src/mytool"]
```

### Build & ship
```bash
python -m build                                   # dist/*.whl + *.tar.gz
pipx install dist/mytool-0.2.0-py3-none-any.whl   # isolated end-user install
pipx install .                                    # from source
pipx run --spec . mytool sync a b                 # run without installing
python -m twine upload dist/*                      # publish to an index
```
Use **pipx** for CLI apps (each gets its own venv, no global pollution). Use **uv tool install** as a
faster alternative: `uv tool install mytool`.

---

## 7. Quality gates: ruff + mypy + pre-commit in CI

### pyproject config
```toml
[tool.ruff]
line-length = 100
target-version = "py311"
[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM", "PTH"]   # pyflakes, isort, pyupgrade, bugbear, simplify, pathlib

[tool.mypy]
python_version = "3.11"
strict = true
warn_unused_ignores = true
```

### .pre-commit-config.yaml
```yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.6.9
    hooks:
      - {id: ruff, args: [--fix]}
      - {id: ruff-format}
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.11.2
    hooks:
      - {id: mypy, additional_dependencies: [types-requests]}
```

### GitHub Actions
```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v3
      - run: uv python install 3.11
      - run: uv sync --frozen --extra dev
      - run: uv run ruff check .
      - run: uv run ruff format --check .
      - run: uv run mypy src/
      - run: uv run pytest -n auto --durations=10
```
`uv sync --frozen` fails if the lockfile drifts — guarantees CI matches the committed environment.
