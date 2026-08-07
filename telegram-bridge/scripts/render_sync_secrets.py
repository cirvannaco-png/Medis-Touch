#!/usr/bin/env python3
"""Sync secret env vars to a Render service and (optionally) redeploy.

Why this exists
---------------
`render.yaml` declares BOT_TOKEN / CHAT_ID / SECRET_KEY / WEBHOOK_SECRET_TOKEN
with `sync: false`, which means Render never manages their values - somebody
has to paste them into the dashboard by hand. That is exactly how the service
ended up booting with a WEBHOOK_SECRET_TOKEN that Telegram rejected.

This script makes that step reproducible:

  * values come from the environment (GitHub Actions secrets in CI),
  * WEBHOOK_SECRET_TOKEN is generated when absent and always validated
    against Telegram's ``^[A-Za-z0-9_-]{1,256}$`` before it is uploaded,
  * env vars are PUT to the Render API, then a deploy is triggered so the
    new values are actually picked up.

Usage:
    RENDER_API_KEY=rnd_xxx RENDER_SERVICE_ID=srv-xxx \
        python scripts/render_sync_secrets.py [--dry-run] [--no-deploy]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.request

RENDER_API = "https://api.render.com/v1"

# Same constraint enforced by app.config.Settings._validate_webhook_secret_token.
TELEGRAM_SECRET_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{1,256}")

# Secrets render.yaml marks `sync: false`. Optional ones are skipped when unset.
REQUIRED_SECRETS = ("BOT_TOKEN", "CHAT_ID", "SECRET_KEY")
GENERATED_SECRETS = ("WEBHOOK_SECRET_TOKEN",)


class RenderSyncError(RuntimeError):
    """Raised for any unrecoverable configuration or API failure."""


def generate_webhook_secret_token() -> str:
    """Return a token that always satisfies Telegram's charset rule.

    ``token_hex`` is used rather than ``token_urlsafe``/base64 because the
    latter emit '+', '/' and '=' which Telegram's setWebhook rejects.
    """
    return secrets.token_hex(32)


def validate_webhook_secret_token(value: str) -> str:
    if not TELEGRAM_SECRET_TOKEN_RE.fullmatch(value):
        raise RenderSyncError(
            "WEBHOOK_SECRET_TOKEN must match ^[A-Za-z0-9_-]{1,256}$ "
            "(Telegram's requirement for secret_token). "
            "Regenerate with: openssl rand -hex 32"
        )
    return value


def collect_secrets(env: dict[str, str]) -> dict[str, str]:
    """Build the env-var payload from the process environment."""
    missing = [k for k in REQUIRED_SECRETS if not env.get(k)]
    if missing:
        raise RenderSyncError(
            "Missing required secret(s): "
            + ", ".join(missing)
            + ". Add them as repository secrets (Settings -> Secrets -> Actions)."
        )

    payload = {k: env[k] for k in REQUIRED_SECRETS}

    for key in GENERATED_SECRETS:
        value = env.get(key) or generate_webhook_secret_token()
        payload[key] = validate_webhook_secret_token(value)

    return payload


def _request(method: str, path: str, api_key: str, body: object | None = None) -> object:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(  # noqa: S310  # nosec B310 - fixed https host
        f"{RENDER_API}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310  # nosec B310
            raw = resp.read().decode() or "null"
    except urllib.error.HTTPError as exc:  # surface Render's message verbatim
        detail = exc.read().decode(errors="replace")
        raise RenderSyncError(f"Render API {method} {path} failed [{exc.code}]: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RenderSyncError(f"Render API {method} {path} unreachable: {exc.reason}") from exc
    return json.loads(raw)


def put_env_vars(service_id: str, api_key: str, values: dict[str, str]) -> None:
    """Replace the service's secret env vars.

    Render's PUT /services/{id}/env-vars replaces the whole list, so the
    non-secret vars declared in render.yaml are re-sent unchanged by reading
    the current list first and merging.
    """
    current = _request("GET", f"/services/{service_id}/env-vars", api_key)
    existing: dict[str, str] = {}
    if isinstance(current, list):
        for item in current:
            ev = item.get("envVar", item) if isinstance(item, dict) else {}
            key = ev.get("key")
            if key and "value" in ev:
                existing[key] = ev["value"]

    merged = {**existing, **values}
    _request(
        "PUT",
        f"/services/{service_id}/env-vars",
        api_key,
        [{"key": k, "value": v} for k, v in sorted(merged.items())],
    )


def trigger_deploy(service_id: str, api_key: str) -> str:
    result = _request("POST", f"/services/{service_id}/deploys", api_key, {"clearCache": "do_not_clear"})
    if isinstance(result, dict):
        return str(result.get("id", "unknown"))
    return "unknown"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="validate only, call no APIs")
    parser.add_argument("--no-deploy", action="store_true", help="update env vars but skip redeploy")
    args = parser.parse_args(argv)

    env = dict(os.environ)
    try:
        values = collect_secrets(env)
    except RenderSyncError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    # Never print values - only key names.
    print("secrets prepared:", ", ".join(sorted(values)))

    if args.dry_run:
        print("dry run: no Render API calls made")
        return 0

    api_key = env.get("RENDER_API_KEY")
    service_id = env.get("RENDER_SERVICE_ID")
    if not api_key or not service_id:
        print("error: RENDER_API_KEY and RENDER_SERVICE_ID must be set", file=sys.stderr)
        return 1

    try:
        put_env_vars(service_id, api_key, values)
        print(f"env vars synced to {service_id}")
        if not args.no_deploy:
            print(f"deploy triggered: {trigger_deploy(service_id, api_key)}")
    except RenderSyncError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
