from __future__ import annotations

from telegram import LabeledPrice, Update
from telegram.error import TelegramError
from telegram.ext import ContextTypes

from app.config import settings
from app.database import async_session
from app.logger import logger
from app.subscriptions import get_or_create_subscriber, record_payment

PAYMENTS_COMMAND_LIST = [
    ("subscribe", "Subscribe / renew (opens a Telegram payment)"),
    ("mysubscription", "Your subscription status and copy-feed key"),
]

_PAYLOAD_PREFIX = "medistouch_sub"


def _build_invoice_payload(user_id: int) -> str:
    return f"{_PAYLOAD_PREFIX}:{user_id}"


async def subscribe(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    if user is None or update.message is None:
        return
    async with async_session() as session:
        await get_or_create_subscriber(session, str(user.id), user.username)
    try:
        await context.bot.send_invoice(
            chat_id=update.effective_chat.id,
            title="Medis Touch — copy-trading access",
            description=f"{settings.SUBSCRIPTION_PERIOD_DAYS}-day access to the Medis Touch copy-trading feed.",
            payload=_build_invoice_payload(user.id),
            provider_token=settings.SUBSCRIPTION_PROVIDER_TOKEN,
            currency=settings.SUBSCRIPTION_CURRENCY,
            prices=[LabeledPrice("Medis Touch subscription", settings.SUBSCRIPTION_PRICE_AMOUNT)],
        )
    except TelegramError as exc:
        logger.error("send_invoice failed for user_id=%s (%s): %s", user.id, type(exc).__name__, exc)
        await update.message.reply_text("Couldn't open the payment window right now — please try /subscribe again shortly.")


async def precheckout_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.pre_checkout_query
    if query is None:
        return
    if query.invoice_payload != _build_invoice_payload(query.from_user.id):
        await query.answer(ok=False, error_message="This payment link doesn't match your account. Send /subscribe again.")
        return
    await query.answer(ok=True)


async def successful_payment_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    message = update.message
    user = update.effective_user
    if message is None or message.successful_payment is None or user is None:
        return
    sp = message.successful_payment
    async with async_session() as session:
        subscriber = await get_or_create_subscriber(session, str(user.id), user.username)
        payment = await record_payment(session, subscriber, telegram_payment_charge_id=sp.telegram_payment_charge_id, amount=sp.total_amount, currency=sp.currency, invoice_payload=sp.invoice_payload, raw_payload=sp.to_dict())
        period_end = subscriber.current_period_end
    if payment is None:
        return
    await message.reply_text(f"✅ Payment received — access is active until {period_end.strftime('%Y-%m-%d %H:%M UTC')}.\nSend /mysubscription to check your status or copy-feed key.")


async def my_subscription(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if user is None or update.message is None:
        return
    if chat is not None and chat.type != "private":
        await update.message.reply_text("Send /mysubscription in a DM with the bot — it includes a private key.")
        return
    async with async_session() as session:
        subscriber = await get_or_create_subscriber(session, str(user.id), user.username)
    if subscriber.current_period_end is None:
        await update.message.reply_text("You don't have an active subscription yet. Send /subscribe to get started.")
        return
    lines = [f"Status: {subscriber.status}", f"Access until: {subscriber.current_period_end.strftime('%Y-%m-%d %H:%M UTC')}"]
    if subscriber.copy_feed_api_key:
        lines.append(f"Copy-feed key: {subscriber.copy_feed_api_key}")
        lines.append("Keep this private — anyone with it can pull your copy-trading feed.")
    await update.message.reply_text("\n".join(lines))
