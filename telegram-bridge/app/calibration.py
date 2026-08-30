"""
telegram-bridge/app/calibration.py — step 6's actual scheduled work, and
the seam where step 5's Telegram card gets attached to step 4's decision.

run_cycle() is what POST /admin/run-cycle (routes.py) calls. It:
  1. Pulls tools/metrics_engine.compute_report() over a trailing window
     (RECENT_WEEKS — matches tools/calibration_matrix.py's own framing:
     the interesting comparison is "recent vs baseline," not
     "since the beginning of time").
  2. Persists it as a CalibrationCycle row (source="live") — this is the
     Postgres replacement for tools/cycle_store.py's JSON files.
  3. For every weight_version that cycle's report has expectancy data
     for, loads that weight_version's live cycle history from Postgres
     and runs it through tools/gating.decide().
  4. PROMOTE -> creates a PromotionRequest (status="pending") and posts
     a tap-to-approve card to the admin chat (bot_promotions.py handles
     the tap). ROLLBACK -> creates a PromotionRequest
     (status="auto_executed") immediately and posts a plain notice — per
     the spec, a genuine contradiction is never gated behind a tap, only
     flagged. HOLD/INSUFFICIENT_DATA -> logged, not messaged; a cycle
     with nothing actionable shouldn't page you.

This module deliberately imports tools/metrics_engine.py and
tools/gating.py rather than re-implementing their logic — see
telegram-bridge/Dockerfile (tools/ is now copied into the image
specifically so this import works in production) and
tools/_pathutil.py (how the two different on-disk layouts, repo
checkout vs. deployed container, both resolve to the same import).
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app import bot as bot_module
from app.bot_promotions import build_promotion_keyboard
from app.config import settings
from app.database import async_session
from app.logger import logger
from app.models import CalibrationCycle, PromotionRequest, SignalOutcome

# See tools/_pathutil.py's docstring for why two candidates are tried.
_APP_DIR = os.path.dirname(os.path.abspath(__file__))
for _candidate in (
    os.path.normpath(os.path.join(_APP_DIR, "..", "tools")),        # deployed container (app/ and tools/ siblings)
    os.path.normpath(os.path.join(_APP_DIR, "..", "..", "tools")),  # repo checkout (telegram-bridge/app/../../tools)
):
    if os.path.exists(os.path.join(_candidate, "metrics_engine.py")) and _candidate not in sys.path:
        sys.path.insert(0, _candidate)
        break
else:
    logger.warning(
        "app.calibration: couldn't locate tools/ (metrics_engine.py/gating.py) "
        "from either the deployed container layout or a repo checkout — "
        "POST /admin/run-cycle will fail until this is fixed. See "
        "telegram-bridge/Dockerfile's COPY tools/ line."
    )

from gating import GatingError, decide, load_cycles_from_db
from metrics_engine import compute_report

CYCLE_WINDOW_WEEKS = 2  # matches the spec's biweekly cadence


async def _fetch_window_rows(since: datetime) -> list:
    async with async_session() as session:
        result = await session.execute(select(SignalOutcome).where(SignalOutcome.received_at >= since))
        return list(result.scalars().all())


async def _persist_cycle(report: dict) -> CalibrationCycle:
    cycle_id = f"live_{report['generated_at'].replace(':', '').replace('+', '_')}"
    row = CalibrationCycle(
        cycle_id=cycle_id,
        source="live",
        generated_at=datetime.fromisoformat(report["generated_at"]),
        report_json=report,
    )
    async with async_session() as session:
        session.add(row)
        await session.commit()
        await session.refresh(row)
    return row


def _format_summary(weight_version: str, decision, cycle_report: dict) -> str:
    """
    Per the spec: coverage delta, expectancy delta by tag, sample size,
    confidence interval — not just a verdict. Pulled straight off the
    gating Decision's metric_verdicts (already the CI objects
    tools/stats.py produced) so this can't drift from what the decision
    was actually based on.
    """
    lines = [
        f"📊 MEDIS TOUCH — Calibration cycle ({weight_version})",
        "",
        f"Decision: {decision.action}",
        f"Cycles considered: {decision.cycles_considered}",
        "",
    ]
    for line in decision.reasoning:
        lines.append(f"• {line}")
    lines.append("")
    for mv in decision.metric_verdicts:
        overlap_label = "no change" if mv.overlap else ("DIVERGED" if mv.overlap is False else "not estimable")
        lines.append(f"{mv.metric}: {overlap_label}")
        if mv.prior.is_estimable:
            lines.append(f"  prior:  {mv.prior.value:.3f} [{mv.prior.ci_low:.3f}, {mv.prior.ci_high:.3f}] (n={mv.prior.n})")
        if mv.latest.is_estimable:
            lines.append(f"  latest: {mv.latest.value:.3f} [{mv.latest.ci_low:.3f}, {mv.latest.ci_high:.3f}] (n={mv.latest.n})")

    cov = cycle_report.get("coverage", {})
    no_fill_rate = cov.get("no_fill_rate")
    no_fill_str = f"{no_fill_rate * 100:.1f}%" if no_fill_rate is not None else "n/a"
    lines += [
        "",
        f"Coverage this cycle: {cov.get('total_signals', 0)} signals, no-fill rate {no_fill_str}",
    ]
    return "\n".join(lines)


async def run_cycle() -> dict:
    now = datetime.now(timezone.utc)
    since = now - timedelta(weeks=CYCLE_WINDOW_WEEKS)

    rows = await _fetch_window_rows(since)
    if not rows:
        logger.info("app.calibration.run_cycle: no signal_outcomes rows in the current window — nothing to do.")
        return {"status": "no_data", "since": since.isoformat()}

    report = compute_report(rows)
    cycle = await _persist_cycle(report)
    logger.info(f"app.calibration.run_cycle: persisted cycle {cycle.cycle_id} "
                f"({len(rows)} rows, {report['expectancy']['resolved_count']} resolved).")

    weight_versions = list(report.get("expectancy", {}).get("by_weight_version_stats", {}).keys())
    decisions = []

    for wv in weight_versions:
        try:
            history = await load_cycles_from_db(weight_version=wv, source="live")
            decision = decide(history, wv)
        except GatingError as e:
            logger.warning(f"app.calibration.run_cycle: gating refused for {wv}: {e}")
            continue

        decisions.append({"weight_version": wv, "action": decision.action})

        if decision.action in ("HOLD", "INSUFFICIENT_DATA"):
            logger.info(f"app.calibration.run_cycle: {wv} -> {decision.action}, no message sent.")
            continue

        async with async_session() as session:
            promo = PromotionRequest(
                weight_version=wv,
                action=decision.action,
                decision_json=decision.to_dict(),
                status="pending" if decision.action == "PROMOTE" else "auto_executed",
                decided_at=None if decision.action == "PROMOTE" else now,
            )
            session.add(promo)
            await session.commit()
            await session.refresh(promo)

        summary = _format_summary(wv, decision, report)
        if decision.action == "ROLLBACK":
            summary += "\n\n⚠️ AUTO-ROLLBACK — this was not gated behind approval; a genuine " \
                       "contradiction between cycles is never auto-reconciled. Flagging for review."

        try:
            if bot_module.application is None or bot_module.application.bot is None:
                logger.warning("app.calibration.run_cycle: bot application not initialized — summary not sent.")
            else:
                keyboard = build_promotion_keyboard(promo.id) if decision.action == "PROMOTE" else None
                msg = await bot_module.application.bot.send_message(
                    chat_id=settings.ADMIN_CHAT_ID, text=summary, reply_markup=keyboard,
                )
                async with async_session() as session:
                    db_promo = await session.get(PromotionRequest, promo.id)
                    db_promo.telegram_message_id = msg.message_id
                    await session.commit()
        except Exception as e:
            logger.error(f"app.calibration.run_cycle: failed to send promotion card for {wv} "
                         f"({type(e).__name__}): {e}")

    return {
        "status": "ok",
        "cycle_id": cycle.cycle_id,
        "resolved_count": report["expectancy"]["resolved_count"],
        "decisions": decisions,
    }
