"""Read-only Telegram control-plane views for Medis Touch.

This module deliberately exposes observations only. It does not approve,
activate, rollback, stop, flatten, or otherwise mutate trading state.
Live portfolio risk remains authoritative inside the EA; the bridge only
reports data that has actually reached its database.
"""

from __future__ import annotations

from datetime import datetime, timezone
from functools import wraps

from sqlalchemy import select
from telegram import Update
from telegram.ext import ContextTypes

from app.config import settings
from app.database import async_session
from app.logger import logger
from app.models import (
    ParameterConfiguration,
    ParameterDeployment,
    ParameterDeploymentAck,
    PromotionRequest,
    Signal,
    TradeEvent,
    TradeEventType,
)

_CLOSE_EVENTS = {
    TradeEventType.CLOSED_TP1,
    TradeEventType.CLOSED_TP2,
    TradeEventType.CLOSED_SL,
    TradeEventType.CLOSED_MANUAL,
}


def _authorized_only(handler):
    """Allow read-only control-plane views only to the configured admin user."""

    @wraps(handler)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        user = update.effective_user
        if user is None or str(user.id) != settings.authorized_user_id:
            logger.warning("Ignored control-plane command from unauthorized user")
            return
        return await handler(update, context)

    return wrapper


async def _latest_open_trades() -> list[TradeEvent]:
    async with async_session() as session:
        result = await session.execute(
            select(TradeEvent).order_by(TradeEvent.received_at.desc()).limit(500)
        )
        events = result.scalars().all()

    latest: dict[str, TradeEvent] = {}
    for event in events:
        latest.setdefault(event.trade_id, event)
    return [event for event in latest.values() if event.event not in _CLOSE_EVENTS]


@_authorized_only
async def portfolio(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Report the bridge's observed portfolio state without inventing risk data."""
    open_trades = await _latest_open_trades()
    symbols = sorted({trade.symbol for trade in open_trades})
    total_volume = sum(trade.volume for trade in open_trades)
    latest_equity = next((trade.equity for trade in open_trades if trade.equity is not None), None)

    lines = [
        "📊 Portfolio — reported bridge view",
        "",
        f"Open positions: {len(open_trades)}",
        f"Symbols: {', '.join(symbols) if symbols else '—'}",
        f"Open volume: {total_volume:.2f} lots",
        f"Last reported equity: {latest_equity:.2f}" if latest_equity is not None else "Last reported equity: —",
        "",
        "Live portfolio risk, correlation, factor exposure and heat remain authoritative in the EA.",
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def portfolio_detail(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    args = getattr(context, "args", None) or []
    detail = args[0].lower() if args else "risk"

    if detail not in {"risk", "exposure", "correlation", "heat"}:
        await update.message.reply_text("Usage: /portfolio risk|exposure|correlation|heat")
        return

    open_trades = await _latest_open_trades()
    if detail == "exposure":
        by_symbol: dict[str, float] = {}
        for trade in open_trades:
            by_symbol[trade.symbol] = by_symbol.get(trade.symbol, 0.0) + trade.volume
        lines = ["📐 Portfolio exposure", ""]
        lines.extend(f"{symbol}: {volume:.2f} lots" for symbol, volume in sorted(by_symbol.items()))
        if not by_symbol:
            lines.append("No open positions reported.")
    else:
        lines = [
            f"📐 Portfolio {detail}",
            "",
            "The bridge does not fabricate this metric.",
            "The authoritative value is calculated inside the MT5 portfolio/risk engine.",
            "A future telemetry endpoint can expose the EA's signed snapshot here.",
        ]

    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def config(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    args = getattr(context, "args", None) or []
    action = args[0].lower() if args else "status"

    async with async_session() as session:
        if action == "status":
            deployments = (
                await session.execute(
                    select(ParameterDeployment)
                    .where(ParameterDeployment.state.in_(["SCHEDULED", "EA_VALIDATED", "EA_ACKNOWLEDGED", "ACTIVE"]))
                    .order_by(ParameterDeployment.created_at.desc())
                    .limit(20)
                )
            ).scalars().all()
            lines = ["⚙️ Configuration status", ""]
            if not deployments:
                lines.append("No deployable configurations reported.")
            else:
                for deployment in deployments:
                    lines.append(
                        f"{deployment.symbol}: {deployment.state} {deployment.config_hash[:12]}…"
                    )
        elif action == "pending":
            rows = (
                await session.execute(
                    select(ParameterConfiguration)
                    .where(ParameterConfiguration.validation_state.in_(["PENDING_APPROVAL", "APPROVED"]))
                    .order_by(ParameterConfiguration.created_at.desc())
                    .limit(10)
                )
            ).scalars().all()
            lines = ["🕒 Configuration candidates", ""]
            if not rows:
                lines.append("No pending configuration candidates.")
            else:
                lines.extend(
                    f"{row.validation_state}: {row.config_hash} (parent {row.parent_version})"
                    for row in rows
                )
        elif action == "history":
            rows = (
                await session.execute(
                    select(ParameterConfiguration)
                    .order_by(ParameterConfiguration.created_at.desc())
                    .limit(10)
                )
            ).scalars().all()
            lines = ["📚 Configuration history", ""]
            if not rows:
                lines.append("No configurations recorded.")
            else:
                lines.extend(
                    f"{row.validation_state}: {row.config_hash[:16]}… ← {row.parent_version}"
                    for row in rows
                )
        elif action == "show" and len(args) >= 2:
            row = await session.scalar(
                select(ParameterConfiguration).where(ParameterConfiguration.config_hash == args[1])
            )
            if row is None:
                lines = ["Configuration not found."]
            else:
                lines = [
                    "⚙️ Configuration",
                    "",
                    f"Hash: {row.config_hash}",
                    f"Parent: {row.parent_version}",
                    f"State: {row.validation_state}",
                    f"Created: {row.created_at.isoformat()}",
                    f"Parameters: {row.parameters_json}",
                ]
        else:
            lines = ["Usage: /config status|pending|history|show HASH"]

    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def ea(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    args = getattr(context, "args", None) or []
    action = args[0].lower() if args else "status"

    async with async_session() as session:
        if action == "status":
            deployments = (
                await session.execute(
                    select(ParameterDeployment)
                    .order_by(ParameterDeployment.created_at.desc())
                    .limit(50)
                )
            ).scalars().all()
            latest: dict[str, ParameterDeployment] = {}
            for deployment in deployments:
                latest.setdefault(deployment.symbol, deployment)

            lines = ["🤖 EA status — reported bridge state", ""]
            if not latest:
                lines.append("No EA deployment state reported.")
            else:
                lines.extend(f"{symbol}: {row.state}" for symbol, row in sorted(latest.items()))
        elif action == "symbols":
            rows = (await session.execute(select(ParameterDeployment.symbol).distinct())).all()
            lines = ["🤖 EA symbols", "", ", ".join(sorted(row[0] for row in rows)) or "No symbols reported."]
        elif action == "config":
            rows = (
                await session.execute(
                    select(ParameterDeploymentAck)
                    .order_by(ParameterDeploymentAck.received_at.desc())
                    .limit(20)
                )
            ).scalars().all()
            lines = ["🤖 EA configuration acknowledgements", ""]
            lines.extend(
                f"{row.symbol}: {row.status} {row.config_hash[:12]}… ({row.ea_instance})"
                for row in rows
            ) or lines.append("No acknowledgements recorded.")
        elif action == "health":
            row = await session.scalar(
                select(ParameterDeploymentAck).order_by(ParameterDeploymentAck.received_at.desc()).limit(1)
            )
            lines = [
                "🩺 EA health",
                "",
                f"Last configuration ACK: {row.received_at.isoformat()}" if row else "Last configuration ACK: never",
                f"Last status: {row.status}" if row else "Last status: —",
            ]
        else:
            lines = ["Usage: /ea status|symbols|health|config"]

    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def learning(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    args = getattr(context, "args", None) or []
    action = args[0].lower() if args else "status"

    async with async_session() as session:
        configs = (await session.execute(select(ParameterConfiguration))).scalars().all()
        promotions = (await session.execute(select(PromotionRequest))).scalars().all()

    if action == "status":
        pending = sum(1 for row in configs if row.validation_state == "PENDING_APPROVAL")
        approved = sum(1 for row in configs if row.validation_state == "APPROVED")
        lines = [
            "🧠 Learning / optimizer status",
            "",
            f"Configurations recorded: {len(configs)}",
            f"Pending approval: {pending}",
            f"Approved: {approved}",
            f"Promotion requests: {len(promotions)}",
            "",
            "Research/optimization remains off the live tick-to-order path.",
        ]
    elif action == "proposals":
        candidates = [row for row in configs if row.validation_state == "PENDING_APPROVAL"][-10:]
        lines = ["🧠 Learning proposals", ""]
        lines.extend(f"{row.config_hash} ← {row.parent_version}" for row in candidates)
        if not candidates:
            lines.append("No pending proposals.")
    elif action == "challenger":
        rows = [row for row in promotions if row.status == "pending"][-10:]
        lines = ["🧠 Challenger / promotion queue", ""]
        lines.extend(f"{row.weight_version}: {row.action} ({row.status})" for row in rows)
        if not rows:
            lines.append("No pending promotion requests.")
    else:
        lines = ["Usage: /learning status|proposals|challenger"]

    await update.message.reply_text("\n".join(lines))
