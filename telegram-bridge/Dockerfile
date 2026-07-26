FROM python:3.11-slim

# Build context is the repository root (Render's default; dockerContext is
# not supported in render.yaml). All COPY paths are relative to the repo root.
WORKDIR /app

COPY telegram-bridge/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY telegram-bridge/app/ ./app/

# Alembic migrations — needed to run `alembic upgrade head` at startup so
# schema changes are applied before the server begins accepting traffic.
COPY telegram-bridge/migrations/ ./migrations/
COPY telegram-bridge/alembic.ini .

EXPOSE 8000

# 1. Run migrations first (idempotent: no-op if already at head).
# 2. `exec` replaces the shell so uvicorn is PID 1 and receives SIGTERM
#    cleanly on container shutdown.
# PORT is injected by Render (and most container platforms); fall back to
# 8000 for local `docker run` without -e PORT.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
