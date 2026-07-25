from app.formatter import format_signal_message

SIGNAL = {
    "signal_id": "abc-123",
    "symbol": "EURUSD",
    "direction": "BUY",
    "entry": 1.1000,
    "sl": 1.0950,
    "tp1": 1.1050,
    "tp2": 1.1100,
    "confidence": 87,
    "reasons": ["structure break", "liquidity sweep"],
    "timeframe": "M15",
}


def test_buy_uses_green_emoji():
    msg = format_signal_message(SIGNAL)
    assert msg.startswith("🟢 MEDIS TOUCH")


def test_sell_uses_red_emoji():
    msg = format_signal_message({**SIGNAL, "direction": "SELL"})
    assert msg.startswith("🔴 MEDIS TOUCH")


def test_contains_all_fields():
    msg = format_signal_message(SIGNAL)
    for expected in ["abc-123", "EURUSD", "BUY", "1.1", "1.095", "87%", "M15"]:
        assert expected in msg


def test_all_reasons_included_with_checkmark():
    msg = format_signal_message(SIGNAL)
    assert "✓ structure break" in msg
    assert "✓ liquidity sweep" in msg


def test_ends_with_active_status():
    msg = format_signal_message(SIGNAL)
    assert msg.strip().endswith("ACTIVE")
