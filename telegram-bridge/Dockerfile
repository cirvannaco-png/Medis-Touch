FROM python:3.11-slim

# Build context is the repository root, set explicitly via `dockerContext: .`
# in the root /render.yaml (a supported Render Blueprint field). All COPY
# paths below are relative to that root, not to this Dockerfile's directory.
WORKDIR /app

COPY telegram-bridge/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY telegram-bridge/app/ ./app/

# v2.11 step 6 — app/calibration.py imports tools/gating.py and
# tools/metrics_engine.py directly rather than duplicating their logic
# (single source of truth for the stats/decision code that both the
# solo-dev CLI tools and the deployed scheduled job run). Copied as a
# sibling of app/ (both directly under WORKDIR /app) to match the
# container-layout candidate tools/_pathutil.py and app/calibration.py's
# own path search already account for.
COPY tools/ ./tools/

# Alembic migrations — needed to run `alembic upgrade head` at startup so
# schema changes are applied before the server begins accepting traffic.
COPY telegram-bridge/migrations/ ./migrations/
COPY telegram-bridge/alembic.ini .

EXPOSE 8000

# 0. Fail fast with a readable message if required secrets aren't set,
#    instead of a raw pydantic ValidationError traceback from inside
#    `alembic upgrade head`. On Render, BOT_TOKEN/CHAT_ID/ADMIN_CHAT_ID/SECRET_KEY are
#    `sync: false` in render.yaml, meaning Blueprint sync creates the slots
#    but does NOT populate them — you must set them by hand in the
#    Dashboard (Service → Environment) before the first successful deploy.
#    WEBHOOK_SECRET_TOKEN is required too and must match
#    ^[A-Za-z0-9_-]{1,256}$ (Telegram's rule) — generate with
#    `openssl rand -hex 32`, or let .github/workflows/render-secrets.yml
#    (scripts/render_sync_secrets.py) create and push it for you.
# 1. Run migrations (idempotent: no-op if already at head).
# 2. `exec` replaces the shell so uvicorn is PID 1 and receives SIGTERM
#    cleanly on container shutdown.
# PORT is injected by Render (and most container platforms); fall back to
# 8000 for local `docker run` without -e PORT.
CMD ["sh", "-c", "python -c 'from app.config import settings' || { echo 'FATAL: missing/invalid required env vars (BOT_TOKEN / CHAT_ID / ADMIN_CHAT_ID / SECRET_KEY / WEBHOOK_SECRET_TOKEN). Set them in Render Dashboard -> Service -> Environment, then redeploy.' >&2; exit 1; }; alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
