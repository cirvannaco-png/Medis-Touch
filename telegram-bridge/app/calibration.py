"""Biweekly calibration scheduler with strict statistical promotion gates.

The two-week cadence remains the observation window, not a license to
promote on two weeks of noise. Each candidate must also clear minimum
sample size, CI/persistence, practical effect, explicit baseline
comparison, and a temporal holdout before PROMOTE can be created.
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

_APP_DIR = os.path.dirname(os.path.abspath(__file__))
for _candidate in (
    os.path.normpath(os.path.join(_APP_DIR, "..", "tools")),
    os.path.normpath(os.path.join(_APP_DIR, "..", "..", "tools")),
):
    if os.path.exists(os.path.join(_candidate, "metrics_engine.py")) and _candidate not in sys.path:
        sys.path.insert(0, _candidate)
        break
else:
    logger.warning("app.calibration: couldn't locate tools/; calibration will fail until the image contains tools/.")

from gating import GatingError, load_cycles_from_db
from metrics_engine import compute_report
from oos_validation import validate_temporal_holdout
from strict_gating import strict_decide

CYCLE_WINDOW_WEEKS = 2
BASELINE_WEIGHT_VERSION_ENV = "CALIBRATION_BASELINE_WEIGHT_VERSION"


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
    oos = cycle_report.get("out_of_sample_by_weight_version", {}).get(weight_version, {})
    lines += [
        "",
        f"Coverage this cycle: {cov.get('total_signals', 0)} signals, no-fill rate {no_fill_str}",
        f"Temporal holdout: {'PASS' if oos.get('passed') else 'FAIL/HOLD'} (n={oos.get('holdout_count', 0)})",
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
    weight_versions = list(report.get("expectancy", {}).get("by_weight_version_stats", {}).keys())

    # Attach a real chronological holdout result to the cycle before it is
    # persisted. Strict gating refuses to promote a cycle without this.
    report["out_of_sample_by_weight_version"] = {
        wv: validate_temporal_holdout(rows, wv)
        for wv in weight_versions
    }

    cycle = await _persist_cycle(report)
    logger.info(
        f"app.calibration.run_cycle: persisted cycle {cycle.cycle_id} "
        f"({len(rows)} rows, {report['expectancy']['resolved_count']} resolved)."
    )

    baseline_version = os.getenv(BASELINE_WEIGHT_VERSION_ENV, "").strip()
    decisions = []

    for wv in weight_versions:
        try:
            history = await load_cycles_from_db(weight_version=wv, source="live")
            decision = strict_decide(history, wv, baseline_weight_version=baseline_version)
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
            summary += (
                "\n\n⚠️ AUTO-ROLLBACK — this was not gated behind approval; a genuine "
                "contradiction between cycles is never auto-reconciled. Flagging for review."
            )

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
            logger.error(
                f"app.calibration.run_cycle: failed to send promotion card for {wv} "
                f"({type(e).__name__}): {e}"
            )

    return {
        "status": "ok",
        "cycle_id": cycle.cycle_id,
        "resolved_count": report["expectancy"]["resolved_count"],
        "decisions": decisions,
        "baseline_weight_version": baseline_version or None,
    }
