"""
Inbound Telegram command handlers for Medis Touch.

app/telegram.py (existing) only ever *sends* — it's a one-way webhook from
the EA into a fixed CHAT_ID. Nothing in the service previously listened for
messages a user typed back to the bot, so /start, /positions, /risk etc.
were undefined and Telegram would just show "no response" for them. This
module is the other half: it turns inbound Telegram updates into replies,
backed by the same signals/trade_events tables the outbound side writes to.

All data shown here is real, queried from the database - nothing is
fabricated. Where the bridge genuinely doesn't have a piece of data (e.g.
live account equity, which only exists inside the MT5 terminal, not this
service), the handler says so rather than inventing a number.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from functools import wraps

from sqlalchemy import select
from telegram import Update
from telegram.ext import ContextTypes

from app.config import APP_VERSION, settings
from app.database import async_session
from app.logger import logger
from app.models import Signal, TradeEvent, TradeEventType

_CLOSE_EVENTS = {
    TradeEventType.CLOSED_TP1,
    TradeEventType.CLOSED_TP2,
    TradeEventType.CLOSED_SL,
    TradeEventType.CLOSED_MANUAL,
}

COMMAND_LIST = [
    ("start", "Start Medis Touch bot"),
    ("signal", "Latest trading signals"),
    ("analysis", "Latest signal reasoning / confidence"),
    ("positions", "Currently open positions"),
    ("risk", "Risk information"),
    ("performance", "Trading performance"),
    ("help", "Show this list"),
]


def _authorized_only(handler):
    """
    Reject anything not coming from settings.CHAT_ID. This bot's CHAT_ID is
    where live signals and trade fills are posted - the same restriction
    is enforced here so a stranger who finds the bot's username can't pull
    open positions or performance history out of it.
    """

    @wraps(handler)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        chat = update.effective_chat
        if chat is None or str(chat.id) != settings.authorized_chat_id:
            logger.warning(f"Ignored command from unauthorized chat_id={chat.id if chat else None}")
            return
        return await handler(update, context)

    return wrapper


@_authorized_only
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    lines = [
        f"🟢 Medis Touch Bot online (v{APP_VERSION})",
        "",
        "Connected to the MT5 Expert Advisor's Telegram bridge.",
        "Send /help to see available commands.",
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    lines = ["Medis Touch — available commands", ""]
    lines += [f"/{name} — {desc}" for name, desc in COMMAND_LIST]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def signal(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    async with async_session() as session:
        result = await session.execute(
            select(Signal).order_by(Signal.received_at.desc()).limit(5)
        )
        signals = result.scalars().all()

    if not signals:
        await update.message.reply_text("No signals recorded yet.")
        return

    lines = ["📡 Last 5 signals", ""]
    for s in signals:
        emoji = "🟢" if s.direction == "BUY" else "🔴"
        ts = s.received_at.strftime("%Y-%m-%d %H:%M UTC") if s.received_at else "?"
        lines.append(
            f"{emoji} {s.symbol} {s.direction} @ {s.entry} | "
            f"conf {s.confidence}% | {s.timeframe} | {s.status.value} | {ts}"
        )
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def analysis(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    async with async_session() as session:
        result = await session.execute(
            select(Signal).order_by(Signal.received_at.desc()).limit(1)
        )
        s = result.scalar_one_or_none()

    if s is None:
        await update.message.reply_text("No signal data yet to analyse.")
        return

    lines = [
        f"🔎 Analysis basis — most recent signal ({s.symbol}, {s.timeframe})",
        "",
        f"Direction: {s.direction}",
        f"Confidence: {s.confidence}%",
        "",
        "Reasons flagged by the EA:",
    ]
    lines += [f"✓ {r}" for r in (s.reasons or [])]
    lines += [
        "",
        (
            "Note: this bridge relays what the EA already computed — it "
            "does not run its own live market analysis independently of a "
            "signal."
        ),
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def positions(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    # "Open" = the most recent event for a trade_id is not a close event.
    # Pull recent events (bounded window) and reduce to the latest per
    # trade_id in Python rather than a window-function query, to keep this
    # readable and DB-portable (SQLite in dev, Postgres in prod).
    async with async_session() as session:
        result = await session.execute(
            select(TradeEvent).order_by(TradeEvent.received_at.desc()).limit(200)
        )
        events = result.scalars().all()

    latest_by_trade: dict[str, TradeEvent] = {}
    for e in events:
        if e.trade_id not in latest_by_trade:
            latest_by_trade[e.trade_id] = e  # first seen = most recent, already ordered desc

    open_trades = [e for e in latest_by_trade.values() if e.event not in _CLOSE_EVENTS]

    if not open_trades:
        await update.message.reply_text("No open positions.")
        return

    lines = [f"📊 Open positions ({len(open_trades)})", ""]
    for e in sorted(
        open_trades,
        key=lambda x: x.received_at or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    ):
        pl = f" | P/L {e.profit:+.2f}" if e.profit is not None else ""
        lines.append(f"{e.symbol} {e.direction} | vol {e.volume} | entry {e.price}{pl}")
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def risk(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    async with async_session() as session:
        result = await session.execute(
            select(TradeEvent).order_by(TradeEvent.received_at.desc()).limit(200)
        )
        events = result.scalars().all()

    latest_by_trade: dict[str, TradeEvent] = {}
    for e in events:
        if e.trade_id not in latest_by_trade:
            latest_by_trade[e.trade_id] = e

    open_trades = [e for e in latest_by_trade.values() if e.event not in _CLOSE_EVENTS]
    symbols = sorted({e.symbol for e in open_trades})
    total_volume = sum(e.volume for e in open_trades)

    lines = [
        "⚠️ Risk snapshot",
        "",
        f"Open positions: {len(open_trades)}",
        f"Symbols exposed: {', '.join(symbols) if symbols else '—'}",
        f"Total open volume: {total_volume:.2f} lots",
        "",
        (
            "Per-trade SL sizing, R:R validation, and account-level risk "
            "limits are enforced by the EA's risk engine (CRiskEngine) on "
            "the MT5 terminal — this bridge only sees what's been reported "
            "to it, not live account equity or margin."
        ),
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def performance(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    since = datetime.now(timezone.utc) - timedelta(days=30)
    async with async_session() as session:
        result = await session.execute(
            select(TradeEvent).where(
                TradeEvent.event.in_(list(_CLOSE_EVENTS)),
                TradeEvent.received_at >= since,
            )
        )
        closed = result.scalars().all()

    if not closed:
        await update.message.reply_text("No closed trades in the last 30 days.")
        return

    profits = [e.profit for e in closed if e.profit is not None]
    wins = [p for p in profits if p > 0]
    losses = [p for p in profits if p <= 0]
    total_pl = sum(profits)
    win_rate = (len(wins) / len(profits) * 100) if profits else 0.0

    lines = [
        "📈 Performance — last 30 days",
        "",
        f"Closed trades: {len(closed)}",
        f"Win rate: {win_rate:.1f}% ({len(wins)}W / {len(losses)}L)",
        f"Total P/L: {total_pl:+.2f}",
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def unknown_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text("Unrecognized command. Send /help to see what's available.")
