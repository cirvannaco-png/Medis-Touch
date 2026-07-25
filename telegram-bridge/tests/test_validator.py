from app.validator import validate_signal

BASE_BUY = {
    "direction": "BUY",
    "entry": 1.1000,
    "sl": 1.0950,
    "tp1": 1.1050,
    "tp2": 1.1100,
}

BASE_SELL = {
    "direction": "SELL",
    "entry": 1.1000,
    "sl": 1.1050,
    "tp1": 1.0950,
    "tp2": 1.0900,
}


def test_valid_buy_passes():
    valid, errors = validate_signal(BASE_BUY)
    assert valid is True
    assert errors is None


def test_valid_sell_passes():
    valid, errors = validate_signal(BASE_SELL)
    assert valid is True
    assert errors is None


def test_buy_sl_above_entry_rejected():
    data = {**BASE_BUY, "sl": 1.1050}
    valid, errors = validate_signal(data)
    assert valid is False
    assert any("stop loss must be below entry" in e for e in errors)


def test_buy_tp1_below_entry_rejected():
    data = {**BASE_BUY, "tp1": 1.0900}
    valid, errors = validate_signal(data)
    assert valid is False
    assert any("TP1 must be above entry" in e for e in errors)


def test_buy_tp2_not_farther_than_tp1_rejected():
    data = {**BASE_BUY, "tp2": 1.1010}  # still above entry, but not above tp1
    valid, errors = validate_signal(data)
    assert valid is False
    assert any("TP2 must be above TP1" in e for e in errors)


def test_sell_sl_below_entry_rejected():
    data = {**BASE_SELL, "sl": 1.0950}
    valid, errors = validate_signal(data)
    assert valid is False
    assert any("stop loss must be above entry" in e for e in errors)


def test_sell_tp2_not_farther_than_tp1_rejected():
    data = {**BASE_SELL, "tp2": 1.0990}
    valid, errors = validate_signal(data)
    assert valid is False
    assert any("TP2 must be below TP1" in e for e in errors)


def test_multiple_violations_all_reported():
    # Every rule broken at once - errors should list all four, not short-circuit.
    data = {"direction": "BUY", "entry": 1.1000, "sl": 1.15, "tp1": 1.05, "tp2": 1.0}
    valid, errors = validate_signal(data)
    assert valid is False
    assert len(errors) == 4
