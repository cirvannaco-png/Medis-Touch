from __future__ import annotations

from sqlalchemy import func, select
from telegram import Update
from telegram.ext import ContextTypes

from app.bot_handlers import _authorized_only
from app.config import settings
from app.copy_settings import confirm_copy_trading_on, get_pending_copy_trading_on, is_copy_trading_enabled, request_copy_trading_on, set_copy_trading_enabled
from app.database import async_session
from app.payment_models import SUBSCRIBER_STATUS_ACTIVE, Subscriber

COPYTRADING_COMMAND_LIST = [
    ("copytrading", "Copy-trading switch: /copytrading on|off|status"),
    ("checkpayments", "Run the subscription sweep now (warn/expire/remove)"),
]


@_authorized_only
async def copytrading_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    args = getattr(context, "args", None) or []
    action = args[0].lower() if args else "status"
    async with async_session() as session:
        if action == "status":
            enabled = await is_copy_trading_enabled(session)
            pending = await get_pending_copy_trading_on(session)
            text = f"Copy trading: {'🟢 ON' if enabled else '🔴 OFF'}"
            if pending:
                text += '\nA pending ON request is awaiting "yes" confirmation.'
            await update.message.reply_text(text)
            return
        if action == "off":
            await set_copy_trading_enabled(session, False)
            await update.message.reply_text("🔴 Copy trading turned OFF.")
            return
        if action == "on":
            if await is_copy_trading_enabled(session):
                await update.message.reply_text("Copy trading is already ON.")
                return
            await request_copy_trading_on(session, str(update.effective_user.id), settings.COPY_TRADING_CONFIRM_TTL_SECONDS)
            await update.message.reply_text(f'⚠️ Reply exactly "yes" within {settings.COPY_TRADING_CONFIRM_TTL_SECONDS} seconds to enable copy trading.')
            return
        await update.message.reply_text("Usage: /copytrading on|off|status")


async def confirm_text_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user, message = update.effective_user, update.message
    if user is None or message is None or message.text is None:
        return
    if str(user.id) != settings.authorized_user_id or message.text.strip().lower() != "yes":
        return
    async with async_session() as session:
        confirmed = await confirm_copy_trading_on(session, str(user.id))
    if confirmed:
        await message.reply_text("🟢 Copy trading turned ON. Entitled subscribers can now pull the feed.")


@_authorized_only
async def checkpayments_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    from app.group_enforcement import run_subscription_enforcement
    await update.message.reply_text("🔁 Running subscription sweep…")
    async with async_session() as session:
        active = await session.scalar(select(func.count()).select_from(Subscriber).where(Subscriber.status == SUBSCRIBER_STATUS_ACTIVE))
        result = await run_subscription_enforcement(session)
    await update.message.reply_text(f"Active subscribers: {active}\nWarned: {result['warned']}\nExpired: {result['expired']}\nRemoved: {result['removed']}")
