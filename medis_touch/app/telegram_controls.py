"""
Adaptive Telegram signal controls.

Handbook section 7. Core rule, verbatim: "Telegram is presentation only.
Backend state is authoritative." This module never decides whether a
copy is *allowed* — copy_trading.py's can_copy() does that, and it is
re-checked again at execution time regardless of what this module
renders. A button existing in a Telegram message is not, and must never
become, an authorization signal.
"""

from __future__ import annotations

from dataclasses import dataclass

from .models import Signal, SignalStatus, signal_is_actionable


@dataclass(frozen=True)
class InlineButton:
    text: str
    callback_data: str


def copy_button(signal_id: str) -> InlineButton:
    return InlineButton(text="Copy Trade", callback_data=f"copy:{signal_id}")


def render_signal_controls(signal: Signal) -> list[InlineButton]:
    """Direct translation of the handbook pseudocode."""
    if signal.status == SignalStatus.ACTIVE and signal_is_actionable(signal):
        return [copy_button(signal.signal_id)]
    return []


# --- Message lifecycle -------------------------------------------------
#
# The handbook's state table:
#   ACTIVE + actionable              -> show Copy button
#   TP1 / TP2                        -> edit existing message, update state
#   INVALIDATED/STALE/EXPIRED/COMPLETED -> edit existing message, remove/disable Copy
#
# Below is the *decision* of what to do to a message on a status
# transition. The actual Telegram Bot API call (editMessageText /
# editMessageReplyMarkup) belongs in your bot layer (app/bot.py per the
# handbook's Ruff-failures list) — this function tells that layer what
# to send, it doesn't call Telegram itself, so it stays testable without
# a network dependency.


@dataclass(frozen=True)
class MessageUpdate:
    text: str
    buttons: list[InlineButton]


_STATUS_LABELS = {
    SignalStatus.ACTIVE: "Active",
    SignalStatus.TP1_REACHED: "TP1 hit",
    SignalStatus.TP2_REACHED: "TP2 hit",
    SignalStatus.INVALIDATED: "Invalidated",
    SignalStatus.EXPIRED: "Expired",
    SignalStatus.STALE: "Stale (no longer actionable)",
    SignalStatus.SUPERSEDED: "Superseded",
    SignalStatus.COMPLETED: "Completed",
}


def build_message_update(signal: Signal, base_text: str) -> MessageUpdate:
    """`base_text` is your existing message formatter's output (kept out
    of scope here — formatter.py per the handbook's repo layout).
    Appends the status label and computes the correct button set.
    """
    label = _STATUS_LABELS.get(signal.status, signal.status.value)
    text = f"{base_text}\n\nStatus: {label}"
    return MessageUpdate(text=text, buttons=render_signal_controls(signal))


def requires_message_edit(previous_status: SignalStatus | None, signal: Signal) -> bool:
    """Whether this status transition needs a Telegram message edit.

    Guards against redundant API calls when evaluate_signal() is called
    every tick but status hasn't actually changed.
    """
    return previous_status != signal.status
