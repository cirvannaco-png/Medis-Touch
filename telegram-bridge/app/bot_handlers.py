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
from app.database import async_session, check_db_connection
from app.logger import logger
from app.models import Signal, TradeEvent, TradeEventType
from app.settings_store import (
    get_muted_symbols,
    is_broadcast_paused,
    mute_symbol,
    set_broadcast_paused,
    unmute_symbol,
)

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
    ("stats", "Today's signal & trade summary"),
    ("symbols", "Symbols active in the last 7 days"),
    ("status", "Bridge health (DB, uptime, version)"),
    ("mute", "Mute broadcasts for a symbol, e.g. /mute XAUUSD"),
    ("unmute", "Unmute a symbol, e.g. /unmute XAUUSD"),
    ("muted", "List currently muted symbols"),
    ("pause", "Pause all outbound signal broadcasts"),
    ("resume", "Resume outbound signal broadcasts"),
    ("retry", "Retry failed/stuck signal & trade deliveries"),
    ("version", "Bridge version"),
    ("help", "Show this list"),
]


def _authorized_only(handler):
    """
    Reject anything not sent by settings.authorized_user_id (ADMIN_USER_ID,
    falling back to ADMIN_CHAT_ID). Authorizing on the *user* id rather than
    the chat id means admin commands work from the DM and from inside the
    signal group, while everyone else is still ignored.
    CHAT_ID is only the broadcast destination for signals and trade fills;
    it is deliberately not authorized here, so neither a stranger who finds
    the bot's username nor a member of the signal group can pull open
    positions or performance history out of it.
    """

    @wraps(handler)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        user = update.effective_user
        chat = update.effective_chat
        if user is None or str(user.id) != settings.authorized_user_id:
            logger.warning(
                f"Ignored command from unauthorized user_id="
                f"{user.id if user else None} chat_id={chat.id if chat else None}"
            )
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
async def stats(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    since = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)

    async with async_session() as session:
        sig_result = await session.execute(
            select(Signal).where(Signal.received_at >= since)
        )
        today_signals = sig_result.scalars().all()

        evt_result = await session.execute(
            select(TradeEvent).where(TradeEvent.received_at >= since)
        )
        today_events = evt_result.scalars().all()

    opened = [e for e in today_events if e.event == TradeEventType.OPENED]
    closed = [e for e in today_events if e.event in _CLOSE_EVENTS]
    profits = [e.profit for e in closed if e.profit is not None]
    total_pl = sum(profits) if profits else 0.0
    wins = len([p for p in profits if p > 0])

    lines = [
        "🗓️ Today's summary",
        "",
        f"Signals received: {len(today_signals)}",
        f"Trades opened: {len(opened)}",
        f"Trades closed: {len(closed)} ({wins}W / {len(closed) - wins}L)",
        f"Realized P/L today: {total_pl:+.2f}",
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def symbols_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    since = datetime.now(timezone.utc) - timedelta(days=7)

    async with async_session() as session:
        sig_result = await session.execute(
            select(Signal.symbol).where(Signal.received_at >= since).distinct()
        )
        active_symbols = {row[0] for row in sig_result.all()}
        muted = await get_muted_symbols(session)

    if not active_symbols and not muted:
        await update.message.reply_text("No symbol activity in the last 7 days.")
        return

    lines = ["📋 Symbols — last 7 days", ""]
    for sym in sorted(active_symbols | muted):
        tag = " 🔇 muted" if sym in muted else ""
        seen = " (no recent signals)" if sym not in active_symbols else ""
        lines.append(f"{sym}{tag}{seen}")
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    db_ok = await check_db_connection()

    async with async_session() as session:
        paused = await is_broadcast_paused(session)
        muted = await get_muted_symbols(session)
        last_signal_result = await session.execute(
            select(Signal).order_by(Signal.received_at.desc()).limit(1)
        )
        last_signal = last_signal_result.scalar_one_or_none()

    last_signal_age = "never"
    if last_signal and last_signal.received_at:
        delta = datetime.now(timezone.utc) - last_signal.received_at
        last_signal_age = f"{int(delta.total_seconds() // 60)} min ago"

    lines = [
        f"🩺 Medis Touch bridge status (v{APP_VERSION})",
        "",
        f"Database: {'🟢 connected' if db_ok else '🔴 unreachable'}",
        f"Broadcast: {'⏸️ paused' if paused else '🟢 active'}",
        f"Muted symbols: {', '.join(sorted(muted)) if muted else 'none'}",
        f"Last signal received: {last_signal_age}",
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def version_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(f"Medis Touch bridge v{APP_VERSION}")


def _parse_symbol_arg(context: ContextTypes.DEFAULT_TYPE) -> str | None:
    if not context.args:
        return None
    return context.args[0].strip().upper()


@_authorized_only
async def mute(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    sym = _parse_symbol_arg(context)
    if not sym:
        await update.message.reply_text("Usage: /mute SYMBOL (e.g. /mute XAUUSD)")
        return
    async with async_session() as session:
        muted = await mute_symbol(session, sym)
    await update.message.reply_text(
        f"🔇 {sym} muted. New signals for this symbol will not be broadcast.\n"
        f"Currently muted: {', '.join(sorted(muted))}"
    )


@_authorized_only
async def unmute(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    sym = _parse_symbol_arg(context)
    if not sym:
        await update.message.reply_text("Usage: /unmute SYMBOL (e.g. /unmute XAUUSD)")
        return
    async with async_session() as session:
        muted = await unmute_symbol(session, sym)
    await update.message.reply_text(
        f"🔊 {sym} unmuted.\n"
        f"Currently muted: {', '.join(sorted(muted)) if muted else 'none'}"
    )


@_authorized_only
async def muted_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    async with async_session() as session:
        muted = await get_muted_symbols(session)
    await update.message.reply_text(
        f"🔇 Muted symbols: {', '.join(sorted(muted))}" if muted else "No symbols currently muted."
    )


@_authorized_only
async def pause(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    async with async_session() as session:
        await set_broadcast_paused(session, True)
    await update.message.reply_text(
        "⏸️ All outbound signal broadcasts paused. Signals are still recorded, "
        "just not sent to Telegram. Send /resume to re-enable."
    )


@_authorized_only
async def resume(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    async with async_session() as session:
        await set_broadcast_paused(session, False)
    await update.message.reply_text("🟢 Broadcasts resumed.")


@_authorized_only
async def retry(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    # Deferred import to avoid a circular import at module load time:
    # app.routes imports app.bot (for bot_module), and app.bot imports
    # app.bot_handlers - importing app.routes at the top of this module
    # would close that loop. By the time this handler actually runs,
    # everything is already fully imported, so a local import is safe.
    from app.routes import retry_failed_signals_core, retry_failed_trade_events_core

    await update.message.reply_text("🔁 Retrying failed/stuck deliveries…")
    async with async_session() as session:
        sig_result = await retry_failed_signals_core(session)
        trade_result = await retry_failed_trade_events_core(session)

    lines = [
        "Signals: " + sig_result.get("message", "done"),
        "Trade events: " + trade_result.get("message", "done"),
    ]
    await update.message.reply_text("\n".join(lines))


@_authorized_only
async def unknown_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text("Unrecognized command. Send /help to see what's available.")
