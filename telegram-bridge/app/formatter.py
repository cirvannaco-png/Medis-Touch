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


_LIFECYCLE_BANNER = {
    "stale": "\u26a0\ufe0f SIGNAL STALE",
    "expired": "🔴 SIGNAL EXPIRED",
    "invalidated": "🔴 SIGNAL INVALIDATED",
}


def format_lifecycle_banner(status: str, reason: str) -> str:
    """v2.9 addition. Prepended to the original card text on an edit —
    see routes.py's PATCH /signal/{signal_id}/status. Deliberately does
    NOT replace the original card (which still has the entry/SL/TP
    someone may want for reference); it makes clear the analysis behind
    it no longer applies."""
    label = _LIFECYCLE_BANNER.get(status, status.upper())
    return f"{label}\nReason: {reason}"


_SWEEP_GRADE_LABEL = {"SWEEP_GRADE_A": "A", "SWEEP_GRADE_B": "B", "SWEEP_GRADE_C": "C", "SWEEP_GRADE_NONE": "-"}
_NEWS_RISK_LABEL = {"NEWS_NONE": "🟢 NONE", "NEWS_WARNING": "🟠 WARNING", "NEWS_BLOCKED": "🔴 BLOCKED"}


def format_signal_message(signal: dict) -> str:
    """Produce the exact Telegram message (plain text).

    v2.9: renders the enriched `extra` diagnostics block (sweep grade,
    BOS strength, decay, chase distance, news risk, calibrated
    probability + sample size, pip distances) when present. `extra` is
    optional (see routes.py:SignalRequest.extra) — a signal from a
    pre-v2.9 EA build, or one that simply omitted it, still renders the
    original card exactly as before with no missing-key errors.
    """
    direction = signal["direction"]
    emoji = "🟢" if direction == "BUY" else "🔴"
    extra = signal.get("extra") or {}

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
    ]

    pips_sl = extra.get("pips_sl")
    pips_tp1 = extra.get("pips_tp1")
    pips_tp2 = extra.get("pips_tp2")

    lines += ["", "Stop Loss", str(signal["sl"]) + (f"  ({pips_sl} pips)" if pips_sl is not None else "")]
    lines += ["", "TP1", str(signal["tp1"]) + (f"  ({pips_tp1} pips)" if pips_tp1 is not None else "")]
    lines += ["", "TP2", str(signal["tp2"]) + (f"  ({pips_tp2} pips)" if pips_tp2 is not None else "")]

    rr1 = extra.get("rr_tp1")
    rr2 = extra.get("rr_tp2")
    if rr1 is not None and rr2 is not None:
        lines += ["", "R:R", f"1:{rr1:.2f} / 1:{rr2:.2f}"]

    lines += [
        "",
        "Timeframe",
        signal["timeframe"],
        "",
        "Confidence",
        f"{signal['confidence']}%",
    ]

    calib_prob = extra.get("calibrated_probability")
    calib_sample = extra.get("calibration_sample")
    calib_ok = extra.get("calibration_has_enough_data")
    if calib_prob is not None and calib_sample is not None:
        if calib_ok:
            lines += ["", "Historical Win Probability", f"{calib_prob:.0f}%  ({calib_sample} comparable setups)"]
        else:
            # review item #2: don't call an unproven number a "probability"
            lines += ["", "Historical Win Probability", f"Insufficient sample ({calib_sample} setups) — not yet reliable"]

    # --- v2.9 setup grading breakdown (review items #16/#17) ---------
    sweep_grade = extra.get("sweep_grade")
    bos_strength = extra.get("bos_strength")
    time_decay = extra.get("time_decay")
    if sweep_grade is not None or bos_strength is not None:
        lines += ["", "Setup Grading", ""]
        if sweep_grade is not None:
            lines.append(f"  Sweep grade: {_SWEEP_GRADE_LABEL.get(sweep_grade, sweep_grade)}")
        if bos_strength is not None:
            lines.append(f"  BOS strength: {bos_strength:.0f}%")
        if time_decay is not None:
            lines.append(f"  Setup freshness: {time_decay:.0f}%")

    chase_dist = extra.get("chase_dist_atr")
    if chase_dist is not None:
        flag = "  \u26a0\ufe0f late entry" if extra.get("chase_ok") is False else ""
        lines += ["", "Entry Distance", f"{chase_dist:.2f} ATR from BOS confirmation{flag}"]

    news_risk = extra.get("news_risk")
    if news_risk is not None:
        news_line = _NEWS_RISK_LABEL.get(news_risk, news_risk)
        news_label = extra.get("news_label")
        news_minutes = extra.get("news_minutes_to_event")
        if news_risk != "NEWS_NONE" and news_label:
            when = f"in {news_minutes}m" if isinstance(news_minutes, (int, float)) and news_minutes >= 0 else "recently"
            news_line += f" — {news_label} {when}"
        lines += ["", "News Risk", news_line]

    lines += ["", "Reasons", ""]
    for reason in signal["reasons"]:
        lines.append(f"\u2713 {reason}")

    lines += [
        "",
        "\u26a0\ufe0f Risk Notice",
        "Algorithmic analysis, not a guarantee of profit. Trading involves substantial risk of loss.",
        "",
        "Status",
        "ACTIVE"
    ]
    return "\n".join(lines)
