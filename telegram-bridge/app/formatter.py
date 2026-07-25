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
