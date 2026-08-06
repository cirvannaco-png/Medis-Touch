# Medis-Touch: `telegram-bridge CI` Red X — Root Cause & Fix

**Repo:** `cirvannaco-png/Medis-Touch`
**Branch:** `main`
**Workflow:** `.github/workflows/telegram-bridge-ci.yml`
**Date:** 2026-08-05

---

## TL;DR

The red X on `main` is **not** the `DuplicateObjectError` issue, and it does **not** affect
your Render deployment. It's a `ruff` (linter) import-ordering failure in the CI job — cosmetic
only. Render's Dockerfile never runs `ruff`, so this has zero runtime effect. Fix is a 3-file,
6-line import reorder with no logic change.

---

## 1. Why `main` shows a red X

CI runs four steps, in order, all gated on the job:

```yaml
- Lint (ruff)          -> ruff check app/ migrations/
- Security scan (bandit)
- Dependency scan (pip-audit)
- Test (pytest)
```

If any step fails, the whole job — and the commit's status badge — goes red, even if the
later steps (including your actual test suite) would have passed.

**Verified locally, exactly as CI runs it:**

| Step | Result before fix | Result after fix |
|---|---|---|
| `ruff check app/ migrations/` | **FAILED** (3 errors) | PASSED |
| `bandit -r app/ -q` | PASSED | PASSED |
| `pip-audit -r requirements.txt` | PASSED (no known vulnerabilities) | PASSED |
| `pytest -v` | 40/40 PASSED | 40/40 PASSED |

So: only `ruff` was ever failing. Everything else — including the DuplicateObjectError fix,
the migration idempotency, and the full test suite — was already correct.

---

## 2. The actual ruff error

```
I001 Import block is un-sorted or un-formatted
```

`ruff`'s `I001` rule (isort-equivalent) requires imports grouped/alphabetized: standard library,
then third-party, then local (`app.*`) — each group sorted alphabetically. Three files had a
local import (`app.config`, `app.database`, or `app import models`) sitting above a third-party
import (`sqlalchemy`), which violates the ordering rule.

This has **no effect on behavior**. Python doesn't care about import order across
non-conflicting modules; this is purely a style/consistency lint.

---

## 3. Files changed

### `migrations/env.py`

```diff
 from alembic import context
 from sqlalchemy.ext.asyncio import AsyncEngine

-from app.config import settings
-from app.database import Base, engine
-
 # Import models so Base.metadata is populated with all tables before
 # autogenerate compares against it.
 from app import models  # noqa: F401
+from app.config import settings
+from app.database import Base, engine

 config = context.config
```

### `migrations/versions/0001_initial_signals_table.py`

```diff
-from alembic import op
 import sqlalchemy as sa
+from alembic import op
 from sqlalchemy.dialects.postgresql import ENUM as PG_ENUM

 revision = "0001"
```

### `migrations/versions/0002_trade_events_table.py`

```diff
-from alembic import op
 import sqlalchemy as sa
+from alembic import op
 from sqlalchemy.dialects.postgresql import ENUM as PG_ENUM

 revision = "0002"
```

**Total change: 6 lines reordered across 3 files. No code logic, no SQL, no migration
behavior, no app behavior touched.**

---

## 4. Why this is safe to push (won't touch Render)

Render's `telegram-bridge/Dockerfile` build/start sequence is:

```
pip install -r requirements.txt
COPY app/, migrations/, alembic.ini
CMD: check env vars -> alembic upgrade head -> exec uvicorn app.main:app
```

`ruff`, `bandit`, and `pip-audit` are **only invoked by the GitHub Actions workflow**, not by
the Docker build or the container start command. Render's deploy pipeline never runs them.
The migration files' *behavior* (the `DO $$ ... EXCEPTION WHEN duplicate_object`
idempotency block, `create_type=False`, `if_not_exists=True`) is byte-for-byte unchanged —
only the order of two `import` lines moved.

Pushing this commit will trigger Render's normal auto-redeploy (same as any other push to
`main`), and that redeploy will behave identically to your last successful one, because the
built container's runtime code is unchanged. The only thing that changes is the GitHub Actions
badge going from ✗ to ✓.

---

## 5. Recommended commit

```
fix(ci): sort imports to satisfy ruff I001

Reorders imports in migrations/env.py and both migration version files
so third-party imports (alembic, sqlalchemy) precede local app imports,
per ruff's isort rule. No logic change. Verified locally:
ruff/bandit/pip-audit/pytest all pass (40/40 tests).
```

Apply with `ruff check --fix app/ migrations/` (already run and verified in this session), then
commit and push to `main`.
