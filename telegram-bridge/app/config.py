from typing import List
from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    BOT_TOKEN: str
    CHAT_ID: str
    SECRET_KEY: str

    # Use PostgreSQL for production (Render); SQLite for local dev
    DATABASE_URL: str = "postgresql+asyncpg://user:pass@localhost:5432/medis_touch"

    LOG_LEVEL: str = "INFO"

    RATE_LIMIT_ENABLED: bool = True
    RATE_LIMIT_MAX_REQUESTS: int = 5        # per window
    RATE_LIMIT_WINDOW_SECONDS: int = 60

    MAX_REQUEST_BODY_SIZE: int = 10 * 1024  # 10 KB

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
    def allowed_origins_list(self) -> List[str]:
        if not self.ALLOWED_ORIGINS.strip():
            return []
        return [o.strip() for o in self.ALLOWED_ORIGINS.split(",") if o.strip()]


settings = Settings()
