"""
Inbound bot wiring: builds the python-telegram-bot Application, registers
command handlers, and manages the Telegram webhook subscription.

This runs in *webhook* mode, not polling. Render exposes a single HTTP
port per web service - polling would mean a second long-running process
Render has no straightforward way to host alongside the FastAPI server on
a free/starter plan. Webhook mode fits the existing deployment exactly:
Telegram POSTs updates to POST /telegram/webhook (see routes.py), which
hands them to application.process_update(). No second process, no extra
Render service.

Mirrors the init_http_client()/close_http_client() pattern in telegram.py
so app/main.py's lifespan reads consistently.
"""

from __future__ import annotations

from telegram import BotCommand, Update
from telegram.ext import (
    Application,
    ApplicationBuilder,
    CallbackQueryHandler,
    CommandHandler,
    MessageHandler,
    filters,
)

from app.bot_handlers import (
    COMMAND_LIST,
    analysis,
    help_command,
    mute,
    muted_command,
    pause,
    performance,
    positions,
    resume,
    retry,
    risk,
    signal,
    start,
    stats,
    status,
    symbols_command,
    unknown_command,
    unmute,
    version_command,
)
from app.bot_promotions import CALLBACK_PREFIX, handle_promotion_callback
from app.config import settings
from app.control_plane import (
    config,
    ea,
    learning,
    portfolio,
    portfolio_detail,
)
from app.logger import logger

application: Application | None = None


def _build_application() -> Application:
    app = ApplicationBuilder().token(settings.BOT_TOKEN).updater(None).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_command))
    app.add_handler(CommandHandler("signal", signal))
    app.add_handler(CommandHandler("analysis", analysis))
    app.add_handler(CommandHandler("positions", positions))
    app.add_handler(CommandHandler("risk", risk))
    app.add_handler(CommandHandler("performance", performance))
    app.add_handler(CommandHandler("stats", stats))
    app.add_handler(CommandHandler("symbols", symbols_command))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("mute", mute))
    app.add_handler(CommandHandler("unmute", unmute))
    app.add_handler(CommandHandler("muted", muted_command))
    app.add_handler(CommandHandler("pause", pause))
    app.add_handler(CommandHandler("resume", resume))
    app.add_handler(CommandHandler("retry", retry))
    app.add_handler(CommandHandler("version", version_command))
    app.add_handler(CommandHandler("portfolio", portfolio_detail))
    app.add_handler(CommandHandler("portfolio", portfolio))
    app.add_handler(CommandHandler("config", config))
    app.add_handler(CommandHandler("ea", ea))
    app.add_handler(CommandHandler("learning", learning))
    app.add_handler(CallbackQueryHandler(handle_promotion_callback, pattern=f"^{CALLBACK_PREFIX}:"))
    app.add_handler(MessageHandler(filters.COMMAND, unknown_command))

    return app


async def init_bot() -> None:
    """Build the Application, register commands with Telegram, and point
    the webhook at this service. Called once from main.py's lifespan.

    Everything below this point talks to Telegram's API over the network.
    Mirrors check_bot_token()'s style in telegram.py: any failure here (bad
    token, Telegram outage, no network reachability) is logged and
    swallowed rather than raised, so a Telegram-side problem degrades only
    the bot's inbound commands instead of crash-looping the whole service -
    outbound signal/trade alerts via POST /signal and /trade don't depend
    on any of this.
    """
    global application
    application = _build_application()

    try:
        await application.initialize()
        await application.start()

        await application.bot.set_my_commands(
            [BotCommand(name, desc) for name, desc in COMMAND_LIST]
            + [
                BotCommand("portfolio", "Portfolio status; use subcommands for detail"),
                BotCommand("config", "Read configuration registry"),
                BotCommand("ea", "Read EA deployment and ACK status"),
                BotCommand("learning", "Read optimizer and challenger status"),
            ]
        )

        if not settings.RENDER_EXTERNAL_URL and not settings.WEBHOOK_URL:
            logger.warning(
                "Neither RENDER_EXTERNAL_URL nor WEBHOOK_URL is set — "
                "skipping set_webhook(). Inbound commands will not work "
                "until the webhook is registered."
            )
            return

        url = settings.webhook_url
        await application.bot.set_webhook(
            url=url,
            secret_token=settings.WEBHOOK_SECRET_TOKEN,
            allowed_updates=["message", "callback_query"],
            drop_pending_updates=True,
        )
        logger.info(f"Telegram webhook set to {url}")
    except Exception as e:
        logger.warning(
            f"Bot setup incomplete - inbound commands may not work "
            f"({type(e).__name__}): {e}"
        )


async def shutdown_bot() -> None:
    global application
    if application is None:
        return
    try:
        await application.stop()
        await application.shutdown()
    except Exception as e:
        logger.warning(f"Bot shutdown incomplete ({type(e).__name__}): {e}")
    finally:
        application = None


async def process_update(data: dict) -> None:
    if application is None:
        raise RuntimeError("Bot application not initialized - call init_bot() on startup")
    update = Update.de_json(data, application.bot)
    await application.process_update(update)
