"""Inbound bot wiring and commerce API registration."""
from __future__ import annotations
from telegram import BotCommand, Update
from telegram.ext import Application, ApplicationBuilder, CallbackQueryHandler, CommandHandler, MessageHandler, filters
from app.bot_handlers import (COMMAND_LIST, analysis, help_command, mute, muted_command, pause, performance, positions, resume, retry, risk, signal, start, stats, status, symbols_command, unknown_command, unmute, version_command)
from app.bot_promotions import CALLBACK_PREFIX, handle_promotion_callback
from app.commerce_bot import subscribe, myplan, copy_status
from app.config import settings
from app.logger import logger
from app.routes import router as api_router
from app.copytrade_payment import router as commerce_router
api_router.include_router(commerce_router)
application: Application | None = None

def _build_application() -> Application:
    app=ApplicationBuilder().token(settings.BOT_TOKEN).updater(None).build()
    handlers=[("start",start),("help",help_command),("signal",signal),("analysis",analysis),("positions",positions),("risk",risk),("performance",performance),("stats",stats),("symbols",symbols_command),("status",status),("mute",mute),("unmute",unmute),("muted",muted_command),("pause",pause),("resume",resume),("retry",retry),("version",version_command),("subscribe",subscribe),("myplan",myplan),("copy",copy_status)]
    for name,handler in handlers: app.add_handler(CommandHandler(name,handler))
    app.add_handler(CallbackQueryHandler(handle_promotion_callback,pattern=f"^{CALLBACK_PREFIX}:"))
    app.add_handler(MessageHandler(filters.COMMAND,unknown_command))
    return app

async def init_bot() -> None:
    global application
    application=_build_application()
    try:
        await application.initialize(); await application.start()
        await application.bot.set_my_commands([BotCommand(n,d) for n,d in COMMAND_LIST]+[BotCommand("subscribe","View subscription plan"),BotCommand("myplan","Check subscription"),BotCommand("copy","Check copy trading")])
        if not settings.RENDER_EXTERNAL_URL and not settings.WEBHOOK_URL:
            logger.warning("Neither RENDER_EXTERNAL_URL nor WEBHOOK_URL is set — skipping set_webhook()."); return
        await application.bot.set_webhook(url=settings.webhook_url,secret_token=settings.WEBHOOK_SECRET_TOKEN,allowed_updates=["message","callback_query"],drop_pending_updates=True)
        logger.info(f"Telegram webhook set to {settings.webhook_url}")
    except Exception as e: logger.warning(f"Bot setup incomplete - inbound commands may not work ({type(e).__name__}): {e}")

async def shutdown_bot() -> None:
    global application
    if application is None:return
    try: await application.stop(); await application.shutdown()
    except Exception as e: logger.warning(f"Bot shutdown incomplete ({type(e).__name__}): {e}")
    finally: application=None

async def process_update(data: dict) -> None:
    if application is None:raise RuntimeError("Bot application not initialized - call init_bot() on startup")
    await application.process_update(Update.de_json(data,application.bot))
