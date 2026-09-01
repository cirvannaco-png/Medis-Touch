from telegram import Update
from telegram.ext import ContextTypes
from sqlalchemy import select
from app.database import async_session
from app.copy_models import Entitlement, CopyAccount
from datetime import datetime, timezone
import os

async def subscribe(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user=update.effective_user
    plan=(context.args[0] if context.args else "monthly").lower()
    price=os.getenv(f"PLAN_{plan.upper()}_PRICE", os.getenv("DEFAULT_PLAN_PRICE", "0"))
    currency=os.getenv("DEFAULT_CURRENCY","KES")
    await update.effective_message.reply_text(
        f"Medis Touch {plan} plan\nPrice: {price} {currency}\n\n"
        "Payment is verified server-side. After payment confirmation your subscription and copy-trading entitlement are activated automatically."
    )

async def myplan(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id=str(update.effective_user.id)
    async with async_session() as db:
        ent=await db.scalar(select(Entitlement).where(Entitlement.user_id==user_id).order_by(Entitlement.valid_until.desc()))
    if not ent:
        await update.effective_message.reply_text("No subscription found. Use /subscribe to view the plan."); return
    active=ent.status=="active" and ent.valid_until>datetime.now(timezone.utc)
    await update.effective_message.reply_text(f"Subscription: {'ACTIVE' if active else 'EXPIRED'}\nCopy trading: {'ON' if active and ent.copy_trading else 'OFF'}\nValid until: {ent.valid_until}")

async def copy_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id=str(update.effective_user.id)
    async with async_session() as db:
        accounts=(await db.scalars(select(CopyAccount).where(CopyAccount.user_id==user_id))).all()
    if not accounts:
        await update.effective_message.reply_text("No copy-trading account is registered yet."); return
    lines=[f"{a.account_id}: {'ON' if a.copy_enabled else 'OFF'} ({a.broker})" for a in accounts]
    await update.effective_message.reply_text("Copy accounts:\n"+"\n".join(lines))
