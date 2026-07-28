_TRADE_EVENT_EMOJI = {
    "opened": "🟢",
    "modified": "✏️",
    "partial_close": "🟡",
    "closed_tp1": "✅",
    "closed_tp2": "✅",
    "closed_sl": "🛑",
    "closed_manual": "⚪",
}

_TRADE_EVENT_LABEL = {
    "opened": "TRADE OPENED",
    "modified": "TRADE MODIFIED",
    "partial_close": "PARTIAL CLOSE",
    "closed_tp1": "CLOSED — TP1 HIT",
    "closed_tp2": "CLOSED — TP2 HIT",
    "closed_sl": "CLOSED — SL HIT",
    "closed_manual": "CLOSED — MANUAL",
}


def format_trade_message(trade: dict) -> str:
    """Produce the exact Telegram message (plain text) for a trade lifecycle event."""
    event = trade["event"]
    emoji = _TRADE_EVENT_EMOJI.get(event, "ℹ️")
    label = _TRADE_EVENT_LABEL.get(event, event.upper())

    lines = [
        f"{emoji} MEDIS TOUCH — {label}",
        "",
        "Trade ID",
        trade["trade_id"],
    ]
    if trade.get("signal_id"):
        lines += ["", "Signal ID", trade["signal_id"]]

    lines += [
        "",
        "Symbol",
        trade["symbol"],
        "",
        "Direction",
        trade["direction"],
        "",
        "Volume",
        str(trade["volume"]),
        "",
        "Price",
        str(trade["price"]),
    ]

    if trade.get("sl") is not None:
        lines += ["", "Stop Loss", str(trade["sl"])]
    if trade.get("tp1") is not None:
        lines += ["", "TP1", str(trade["tp1"])]
    if trade.get("tp2") is not None:
        lines += ["", "TP2", str(trade["tp2"])]
    if trade.get("profit") is not None:
        pl_emoji = "📈" if trade["profit"] >= 0 else "📉"
        lines += ["", "P/L", f"{pl_emoji} {trade['profit']:+.2f}"]
    if trade.get("balance") is not None:
        lines += ["", "Balance", str(trade["balance"])]
    if trade.get("equity") is not None:
        lines += ["", "Equity", str(trade["equity"])]
    if trade.get("comment"):
        lines += ["", "Comment", trade["comment"]]

    return "\n".join(lines)


def format_signal_message(signal: dict) -> str:
    """Produce the exact Telegram message (plain text)."""
    direction = signal["direction"]
    emoji = "🟢" if direction == "BUY" else "🔴"

    lines = [
        f"{emoji} MEDIS TOUCH",
        "",
        "Signal ID",
        signal["signal_id"],
        "",
        "Symbol",
        signal["symbol"],
        "",
        "Direction",
        direction,
        "",
        "Entry",
        str(signal["entry"]),
        "",
        "Stop Loss",
        str(signal["sl"]),
        "",
        "TP1",
        str(signal["tp1"]),
        "",
        "TP2",
        str(signal["tp2"]),
        "",
        "Timeframe",
        signal["timeframe"],
        "",
        "Confidence",
        f"{signal['confidence']}%",
        "",
        "Reasons",
        ""
    ]
    for reason in signal["reasons"]:
        lines.append(f"✓ {reason}")

    lines += [
        "",
        "Status",
        "",
        "ACTIVE"
    ]
    return "\n".join(lines)
