
import httpx
from loguru import logger
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from app.config import settings


class TelegramSendError(Exception):
    """Transient error - safe to retry."""


class NonRetryableError(Exception):
    """Permanent error - do not retry."""


# Shared, connection-pooled client. Created on app startup, closed on shutdown.
# Avoids a fresh TCP+TLS handshake to api.telegram.org on every signal.
_client: httpx.AsyncClient | None = None


async def init_http_client() -> None:
    global _client
    _client = httpx.AsyncClient(timeout=settings.TELEGRAM_TIMEOUT_SECONDS)


async def close_http_client() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


def _get_client() -> httpx.AsyncClient:
    if _client is None:
        raise RuntimeError("HTTP client not initialized - call init_http_client() on startup")
    return _client


@retry(
    stop=stop_after_attempt(settings.TELEGRAM_MAX_RETRIES),
    wait=wait_exponential(multiplier=1, min=1, max=settings.TELEGRAM_RETRY_MAX_WAIT_SECONDS),
    retry=retry_if_exception_type((httpx.HTTPStatusError, httpx.RequestError, TelegramSendError)),
    reraise=True,
)
async def _send_to_chat(text: str, chat_id: str) -> int:
    url = f"https://api.telegram.org/bot{settings.BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": text,
        "disable_web_page_preview": True,
    }
    client = _get_client()
    try:
        response = await client.post(url, json=payload)
        response.raise_for_status()
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 429:
            raise TelegramSendError(f"Rate limited: {e.response.text}") from e
        elif e.response.status_code >= 500:
            raise TelegramSendError(f"Server error: {e.response.text}") from e
        else:
            raise NonRetryableError(f"Permanent HTTP error: {e.response.status_code}") from e
    except httpx.RequestError as e:
        raise TelegramSendError(f"Request failed: {e}") from e

    data = response.json()
    if not data.get("ok"):
        error_code = data.get("error_code")
        if error_code in (429, 500, 502, 503, 504):
            raise TelegramSendError(f"Telegram API error (code={error_code}): {data}")
        else:
            raise NonRetryableError(f"Telegram API error (code={error_code}): {data}")

    message_id = data["result"]["message_id"]
    logger.info(f"Telegram message sent to chat_id={chat_id}, id={message_id}")
    return message_id


async def send_telegram_message(text: str, chat_id: str | None = None) -> int:
    """Send `text` to `chat_id`, or broadcast it to every configured
    destination (CHAT_ID plus GROUP_CHAT_ID when set).

    The message_id returned is always the one from the primary destination
    (CHAT_ID) - that's what gets persisted against the signal. A failure on
    a secondary destination is logged and swallowed so one bad group id
    can't fail an otherwise delivered signal; a failure on the primary
    propagates exactly as before.
    """
    if chat_id is not None:
        return await _send_to_chat(text, chat_id)

    targets = settings.broadcast_chat_ids or [settings.CHAT_ID]
    primary_id = await _send_to_chat(text, targets[0])
    for extra in targets[1:]:
        try:
            await _send_to_chat(text, extra)
        except Exception as e:  # secondary delivery is best-effort
            logger.error(
                f"Broadcast to secondary chat_id={extra} failed "
                f"({type(e).__name__}): {e}"
            )
    return primary_id


async def edit_telegram_message(message_id: int, text: str, chat_id: str | None = None) -> bool:
    """v2.9 addition — signal lifecycle support (VALID -> STALE/EXPIRED/
    INVALIDATED). Edits the primary chat's copy of a previously-sent
    message. KNOWN LIMITATION: send_telegram_message() broadcasts to
    every configured chat_id (CHAT_ID + GROUP_CHAT_ID + extras) but only
    persists the primary destination's message_id on the Signal row —
    so this can only edit the primary copy. Secondary/group copies of a
    signal that later goes STALE/EXPIRED/INVALIDATED will NOT be edited
    until message_id tracking is extended to one-per-destination. Not
    silently broken: this is a real gap, flagged rather than hidden.
    Returns False (not raised) on failure — a failed edit shouldn't ever
    take down the caller; the DB-side lifecycle_status update in
    routes.py still lands either way.
    """
    url = f"https://api.telegram.org/bot{settings.BOT_TOKEN}/editMessageText"
    target = chat_id or settings.CHAT_ID
    payload = {
        "chat_id": target,
        "message_id": message_id,
        "text": text,
        "disable_web_page_preview": True,
    }
    client = _get_client()
    try:
        response = await client.post(url, json=payload)
        response.raise_for_status()
        data = response.json()
        if not data.get("ok"):
            logger.warning(f"editMessageText returned ok=false: {data}")
            return False
        return True
    except Exception as e:
        # Intentionally broad + swallowed, same rationale as check_bot_token():
        # a failed lifecycle-status edit must never break signal ingestion.
        logger.warning(f"editMessageText failed ({type(e).__name__}): {e}")
        return False


async def check_bot_token() -> bool:
    """Check if the bot token is valid. Returns True if valid, False otherwise."""
    url = f"https://api.telegram.org/bot{settings.BOT_TOKEN}/getMe"
    client = _get_client()
    try:
        resp = await client.get(url, timeout=settings.TELEGRAM_TIMEOUT_SECONDS)
        data = resp.json()
        if data.get("ok"):
            logger.info(f"Bot token valid. Bot username: @{data['result']['username']}")
            return True
        else:
            logger.error(f"Invalid bot token: {data}")
            return False
    except Exception as e:
        # Intentionally broad: this is a best-effort startup check that must
        # never crash the process. Logging the exception type alongside the
        # message makes it easy to tell "network unreachable" apart from an
        # actual bug here without narrowing (and risking a missed case) the
        # except clause itself.
        logger.error(f"Could not verify bot token ({type(e).__name__}): {e}")
        return False
