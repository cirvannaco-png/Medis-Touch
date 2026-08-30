"""
telegram-bridge/app/bot_promotions.py — step 5's tap-to-approve gate.

Handles taps on the inline Approve/Reject buttons app/calibration.py
attaches to a PROMOTE decision's summary message. Deliberately separate
from bot_handlers.py (which is entirely CommandHandler-based) since this
is the one CallbackQueryHandler in the app and has a different update
shape (callback_query, not message) and a different authorization check
(query.from_user, not update.effective_user from a message).
"""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import select
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import ContextTypes

from app.config import settings
from app.database import async_session
from app.logger import logger
from app.models import ApprovedWeightVersion, PromotionRequest

CALLBACK_PREFIX = "promo"  # "promo:approve:<id>" / "promo:reject:<id>"


def build_promotion_keyboard(promotion_request_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("✅ Approve", callback_data=f"{CALLBACK_PREFIX}:approve:{promotion_request_id}"),
        InlineKeyboardButton("❌ Reject", callback_data=f"{CALLBACK_PREFIX}:reject:{promotion_request_id}"),
    ]])


async def handle_promotion_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    user = query.from_user

    # Same authorization boundary as _authorized_only in bot_handlers.py,
    # reimplemented here rather than imported: that decorator wraps a
    # (update, context) command handler and reads update.effective_user,
    # which for a callback_query update resolves to the same person but
    # via a different Update field — the decorator's shape doesn't fit a
    # CallbackQueryHandler cleanly, so this is a deliberate small
    # duplication of the *check*, not a different *policy*.
    if user is None or str(user.id) != settings.authorized_user_id:
        logger.warning(f"Ignored promotion callback from unauthorized user_id={user.id if user else None}")
        await query.answer("Not authorized.", show_alert=True)
        return

    try:
        _, action, id_str = query.data.split(":", 2)
        promotion_request_id = int(id_str)
    except (ValueError, AttributeError):
        await query.answer("Malformed callback data.", show_alert=True)
        return

    async with async_session() as session:
        promo = await session.get(PromotionRequest, promotion_request_id)
        if promo is None:
            await query.answer("This promotion request no longer exists.", show_alert=True)
            return

        # Idempotency: a second tap (double-tap, or a tap after the
        # request was already decided by another path) must never
        # double-execute — just tell the user what already happened.
        if promo.status != "pending":
            await query.answer(f"Already {promo.status} — no action taken.", show_alert=True)
            return

        now = datetime.now(timezone.utc)
        promo.decided_at = now
        promo.decided_by = str(user.id)

        if action == "approve":
            promo.status = "approved"
            existing = await session.scalar(
                select(ApprovedWeightVersion).where(ApprovedWeightVersion.weight_version == promo.weight_version)
            )
            if existing is None:
                session.add(ApprovedWeightVersion(
                    weight_version=promo.weight_version,
                    approved_by=str(user.id),
                    promotion_request_id=promo.id,
                ))
            verdict_line = f"✅ Approved by {user.first_name or user.id} at {now.strftime('%Y-%m-%d %H:%M UTC')}"
        elif action == "reject":
            promo.status = "rejected"
            verdict_line = f"❌ Rejected by {user.first_name or user.id} at {now.strftime('%Y-%m-%d %H:%M UTC')}"
        else:
            await query.answer("Unknown action.", show_alert=True)
            return

        await session.commit()

    await query.answer("Recorded.")
    # Edit the original card in place: remove the buttons, append the
    # verdict — the message becomes its own permanent record of what was
    # decided and by whom, rather than a card that still invites a tap.
    original_text = query.message.text or ""
    try:
        await query.edit_message_text(f"{original_text}\n\n{verdict_line}")
    except Exception as e:  # message too old to edit, or already edited — non-fatal
        logger.warning(f"Couldn't edit promotion card after decision ({type(e).__name__}): {e}")

    logger.info(f"Promotion request {promotion_request_id} ({promo.weight_version}): {promo.status} by user_id={user.id}")
