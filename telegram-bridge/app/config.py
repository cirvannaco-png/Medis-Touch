import re

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Single source of truth for the app version. Previously "1.0.0" was
# hardcoded in three places (FastAPI app, and two HealthResponse literals
# in routes.py) while pyproject.toml said "1.1.0" - they'd drifted.
APP_VERSION = "1.4.0"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    BOT_TOKEN: str

    # Outbound destination: signals and trade alerts are broadcast here
    # (typically the subscriber group or channel).
    CHAT_ID: str

    # Inbound authorization: the only chat whose commands the bot obeys
    # (typically your personal DM). Kept separate from CHAT_ID so members
    # of the signal group can't run /positions, /risk, etc.
    ADMIN_CHAT_ID: str
    SECRET_KEY: str

    # Use PostgreSQL for production (Render); SQLite for local dev.
    # Render's fromDatabase injects a postgres:// or postgresql:// URL;
    # the validator below normalises it to postgresql+asyncpg:// so
    # SQLAlchemy's asyncpg driver works without any manual URL editing.
    DATABASE_URL: str = "postgresql+asyncpg://user:pass@localhost:5432/medis_touch"

    @field_validator("DATABASE_URL", mode="before")
    @classmethod
    def _normalise_db_url(cls, v: str) -> str:
        """Accept postgres:// or postgresql:// and rewrite to asyncpg dialect."""
        if v.startswith("postgres://"):
            return "postgresql+asyncpg://" + v[len("postgres://"):]
        if v.startswith("postgresql://"):
            return "postgresql+asyncpg://" + v[len("postgresql://"):]
        return v

    LOG_LEVEL: str = "INFO"

    RATE_LIMIT_ENABLED: bool = True
    RATE_LIMIT_MAX_REQUESTS: int = 5        # per window
    RATE_LIMIT_WINDOW_SECONDS: int = 60

    MAX_REQUEST_BODY_SIZE: int = 10 * 1024  # 10 KB

    # If the process crashes/restarts between reserving a signal_id (PENDING)
    # and resolving the Telegram send, the row is stuck at PENDING forever
    # unless something reclaims it. /retry-failed treats PENDING rows older
    # than this as eligible for retry, same as FAILED rows.
    PENDING_STALE_SECONDS: int = 120

    # Comma-separated list of allowed origins. Empty = no browser origins allowed
    # (fine for EA->API traffic, which isn't subject to CORS at all).
    ALLOWED_ORIGINS: str = ""

    # Telegram send tuning. Keep TELEGRAM_TIMEOUT_SECONDS * TELEGRAM_MAX_RETRIES
    # comfortably under whatever WebRequest timeout the EA's SignalPublisher uses,
    # or the EA will time out and resend before the backend finishes retrying.
    TELEGRAM_TIMEOUT_SECONDS: float = 8.0
    TELEGRAM_MAX_RETRIES: int = 3
    TELEGRAM_RETRY_MAX_WAIT_SECONDS: float = 4.0

    @field_validator("ALLOWED_ORIGINS")
    @classmethod
    def _noop(cls, v: str) -> str:
        return v

    @property
    def allowed_origins_list(self) -> list[str]:
        if not self.ALLOWED_ORIGINS.strip():
            return []
        return [o.strip() for o in self.ALLOWED_ORIGINS.split(",") if o.strip()]

    # ---- Inbound bot (commands: /start /signal /positions /risk ...) ----
    # Telegram signs every webhook delivery with this token in the
    # X-Telegram-Bot-Api-Secret-Token header (set via bot.set_webhook). The
    # /telegram/webhook route rejects anything that doesn't match, so a
    # third party who discovers the webhook URL can't inject fake /start,
    # /positions, etc. into the bot. Required, same treatment as BOT_TOKEN.
    WEBHOOK_SECRET_TOKEN: str

    @field_validator("WEBHOOK_SECRET_TOKEN")
    @classmethod
    def _validate_webhook_secret_token(cls, v: str) -> str:
        """Telegram's setWebhook requires secret_token to match
        ^[A-Za-z0-9_-]{1,256}$ - anything else (e.g. base64 output with
        '+', '/', '=') is rejected with BadRequest at set_webhook() time,
        which init_bot() swallows into a warning. Fail fast at startup
        instead, with a message that says exactly what's wrong.
        """
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", v):
            raise ValueError(
                "WEBHOOK_SECRET_TOKEN must match ^[A-Za-z0-9_-]{1,256}$ "
                "(Telegram's requirement for secret_token). Regenerate with: "
                "openssl rand -hex 32"
            )
        return v

    # Render injects this automatically for every web service (no manual
    # setup needed) - e.g. "https://medis-touch-telegram.onrender.com".
    # Only set WEBHOOK_URL by hand for local tunneling (ngrok) or if the
    # service is fronted by a custom domain Render doesn't know about.
    RENDER_EXTERNAL_URL: str = ""
    WEBHOOK_URL: str = ""
    WEBHOOK_PATH: str = "/telegram/webhook"

    @property
    def webhook_url(self) -> str:
        base = (self.WEBHOOK_URL or self.RENDER_EXTERNAL_URL).rstrip("/")
        return f"{base}{self.WEBHOOK_PATH}"

    # Commands that touch trading data reply only inside ADMIN_CHAT_ID (your
    # personal DM), independent of CHAT_ID, which is where outbound
    # signals/trade alerts are broadcast (the group). Anyone else who finds
    # the bot and sends /positions gets silently ignored rather than a
    # peek at live signals, open positions, or P/L.
    @property
    def authorized_chat_id(self) -> str:
        return self.ADMIN_CHAT_ID


settings = Settings()
