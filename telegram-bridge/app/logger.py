import sys

from loguru import logger

from app.config import settings


def _format_record(record) -> str:
    base = (
        "<green>{time:YYYY-MM-DD HH:mm:ss}</green> | "
        "<level>{level: <8}</level> | "
        "<level>{message}</level>"
    )
    extra = record["extra"]
    if extra:
        extra_str = " | " + " ".join(f"{k}={v}" for k, v in extra.items())
        base += extra_str
    return base + "\n{exception}"


logger.remove()
logger.add(
    sys.stdout,
    level=settings.LOG_LEVEL,
    format=_format_record,
    colorize=True,
)
# NOTE: File sink removed. Render's filesystem is ephemeral — the log file
# is wiped on every restart, redeploy, or spin-down cycle, providing no
# persistent value. stdout above is already captured as Render's log stream.
