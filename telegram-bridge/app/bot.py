from __future__ import annotations

from telegram import BotCommand, Update
from telegram.ext import Application, ApplicationBuilder, CallbackQueryHandler, CommandHandler, MessageHandler, PreCheckoutQueryHandler, filters

from app.bot_handlers import COMMAND_LIST, analysis, help_command, mute, muted_command, pause, performance, positions, resume, retry, risk, signal, start, stats, status, symbols_command, unknown_command, unmute, version_command
from app.bot_promotions import CALLBACK_PREFIX, handle_promotion_callback
from app.config import settings
from app.control_plane import config, ea, learning, portfolio_detail
from app.copytrading_admin import COPYTRADING_COMMAND_LIST, checkpayments_command, confirm_text_handler, copytrading_command
from app.logger import logger
from app.payments_bot import PAYMENTS_COMMAND_LIST, my_subscription, precheckout_callback, subscribe, successful_payment_callback

application: Application | None = None

for _name, _desc in PAYMENTS_COMMAND_LIST + COPYTRADING_COMMAND_LIST:
    if _name not in {n for n, _ in COMMAND_LIST}:
        COMMAND_LIST.append((_name, _desc))


def _build_application() -> Application:
    app = ApplicationBuilder().token(settings.BOT_TOKEN).updater(None).build()
    for name, handler in [
        ("start", start), ("help", help_command), ("signal", signal), ("analysis", analysis),
        ("positions", positions), ("risk", risk), ("performance", performance), ("stats", stats),
        ("symbols", symbols_command), ("status", status), ("mute", mute), ("unmute", unmute),
        ("muted", muted_command), ("pause", pause), ("resume", resume), ("retry", retry),
        ("version", version_command), ("portfolio", portfolio_detail), ("config", config),
        ("ea", ea), ("learning", learning), ("subscribe", subscribe), ("mysubscription", my_subscription),
        ("copytrading", copytrading_command), ("checkpayments", checkpayments_command),
    ]:
        app.add_handler(CommandHandler(name, handler))
    app.add_handler(CallbackQueryHandler(handle_promotion_callback, pattern=f"^{CALLBACK_PREFIX}:"))
    app.add_handler(PreCheckoutQueryHandler(precheckout_callback))
    app.add_handler(MessageHandler(filters.SUCCESSFUL_PAYMENT, successful_payment_callback))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, confirm_text_handler))
    app.add_handler(MessageHandler(filters.COMMAND, unknown_command))
    return app


async def init_bot() -> None:
    global application
    application = _build_application()
    try:
        await application.initialize()
        await application.start()
        await application.bot.set_my_commands(
            [BotCommand(name, desc) for name, desc in COMMAND_LIST]
            + [
                BotCommand("portfolio", "Portfolio status and exposure views"),
                BotCommand("config", "Read configuration registry"),
                BotCommand("ea", "Read EA deployment and ACK status"),
                BotCommand("learning", "Read optimizer and challenger status"),
            ]
        )
        if not settings.RENDER_EXTERNAL_URL and not settings.WEBHOOK_URL:
            logger.warning("Neither RENDER_EXTERNAL_URL nor WEBHOOK_URL is set — skipping set_webhook().")
            return
        await application.bot.set_webhook(
            url=settings.webhook_url,
            secret_token=settings.WEBHOOK_SECRET_TOKEN,
            allowed_updates=["message", "callback_query", "pre_checkout_query"],
            drop_pending_updates=True,
        )
        logger.info("Telegram webhook set to %s", settings.webhook_url)
    except Exception as exc:
        logger.warning("Bot setup incomplete - inbound commands may not work (%s): %s", type(exc).__name__, exc)


async def shutdown_bot() -> None:
    global application
    if application is None:
        return
    try:
        await application.stop()
        await application.shutdown()
    except Exception as exc:
        logger.warning("Bot shutdown incomplete (%s): %s", type(exc).__name__, exc)
    finally:
        application = None


async def process_update(data: dict) -> None:
    if application is None:
        raise RuntimeError("Bot application not initialized - call init_bot() on startup")
    await application.process_update(Update.de_json(data, application.bot))
