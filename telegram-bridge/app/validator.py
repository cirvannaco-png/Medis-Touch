from typing import Tuple, Optional, List


def validate_signal(data: dict) -> Tuple[bool, Optional[List[str]]]:
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
    errors: List[str] = []

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
