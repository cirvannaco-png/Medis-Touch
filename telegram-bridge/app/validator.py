

def validate_signal(data: dict) -> tuple[bool, list[str] | None]:
    """
    Business rules beyond what Pydantic already enforces (types, presence, gt=0 ranges):
      - Stop loss must be on the correct side of entry.
      - Take-profit levels must be on the correct side of entry.
      - TP2 must be farther from entry than TP1 (in the trade's direction).
    """
    direction = data["direction"]
    entry = data["entry"]
    sl = data["sl"]
    tp1 = data["tp1"]
    tp2 = data["tp2"]
    errors: list[str] = []

    if direction == "BUY":
        if sl >= entry:
            errors.append("For BUY, stop loss must be below entry price")
        if tp1 <= entry:
            errors.append("For BUY, TP1 must be above entry price")
        if tp2 <= entry:
            errors.append("For BUY, TP2 must be above entry price")
        if tp2 <= tp1:
            errors.append("For BUY, TP2 must be above TP1")
    elif direction == "SELL":
        if sl <= entry:
            errors.append("For SELL, stop loss must be above entry price")
        if tp1 >= entry:
            errors.append("For SELL, TP1 must be below entry price")
        if tp2 >= entry:
            errors.append("For SELL, TP2 must be below entry price")
        if tp2 >= tp1:
            errors.append("For SELL, TP2 must be below TP1")

    if errors:
        return False, errors
    return True, None


def validate_trade_event(data: dict) -> tuple[bool, list[str] | None]:
    """
    Business rules for POST /trade payloads. Deliberately lighter than
    validate_signal(): SL/TP are optional here (a closed_sl/closed_tp1/
    closed_manual event may legitimately omit levels that no longer apply
    once the position is flat), so we only check side-of-entry ordering
    for whichever of sl/tp1/tp2 are actually present, using `price` as the
    reference level instead of a pre-trade `entry`.
    """
    direction = data["direction"]
    price = data["price"]
    sl = data.get("sl")
    tp1 = data.get("tp1")
    tp2 = data.get("tp2")
    errors: list[str] = []

    if direction == "BUY":
        if sl is not None and sl >= price:
            errors.append("For BUY, stop loss must be below price")
        if tp1 is not None and tp1 <= price:
            errors.append("For BUY, TP1 must be above price")
        if tp2 is not None and tp2 <= price:
            errors.append("For BUY, TP2 must be above price")
        if tp1 is not None and tp2 is not None and tp2 <= tp1:
            errors.append("For BUY, TP2 must be above TP1")
    elif direction == "SELL":
        if sl is not None and sl <= price:
            errors.append("For SELL, stop loss must be above price")
        if tp1 is not None and tp1 >= price:
            errors.append("For SELL, TP1 must be below price")
        if tp2 is not None and tp2 >= price:
            errors.append("For SELL, TP2 must be below price")
        if tp1 is not None and tp2 is not None and tp2 >= tp1:
            errors.append("For SELL, TP2 must be below TP1")

    if data["volume"] <= 0:
        errors.append("volume must be greater than 0")

    if errors:
        return False, errors
    return True, None
