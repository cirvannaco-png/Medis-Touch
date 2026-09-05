"""Persistent execution control plane with idempotency and leases."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ExecutionLedger, PortfolioReservation

LEASE_SECONDS = 30
TERMINAL_STATES = {"FILLED", "REJECTED", "CANCELLED", "RECONCILED"}


async def _portfolio_lock(session: AsyncSession) -> None:
    """Serialize portfolio admission, including the empty-table case."""
    if session.bind and session.bind.dialect.name == "postgresql":
        await session.execute(
            text(
                "SELECT pg_advisory_xact_lock(hashtext('medis-touch-portfolio'))"
            )
        )


async def reserve_execution(
    session: AsyncSession,
    request_id: str,
    signal_id: str,
    symbol: str,
    direction: str,
    risk_r: float,
    volatility: float,
    factors: dict,
    max_heat_r: float = 3.0,
) -> bool:
    """Atomically reserve portfolio risk before any broker request is sent."""
    await _portfolio_lock(session)
    existing = await session.scalar(
        select(ExecutionLedger)
        .where(ExecutionLedger.request_id == request_id)
        .with_for_update()
    )
    if existing is not None:
        return False

    active = (
        (
            await session.execute(
                select(PortfolioReservation)
                .where(PortfolioReservation.status == "ACTIVE")
                .with_for_update()
            )
        )
        .scalars()
        .all()
    )
    if sum(abs(item.risk_r) for item in active) + abs(risk_r) > max_heat_r:
        return False

    now = datetime.now(timezone.utc)
    lease_until = now + timedelta(seconds=LEASE_SECONDS)
    session.add(
        ExecutionLedger(
            request_id=request_id,
            signal_id=signal_id,
            symbol=symbol,
            state="RESERVED",
            request_json={"direction": direction, "risk_r": risk_r},
            created_at=now,
            lease_until=lease_until,
        )
    )
    session.add(
        PortfolioReservation(
            request_id=request_id,
            symbol=symbol,
            direction=direction,
            risk_r=risk_r,
            volatility=volatility,
            factor_exposure=factors,
            status="ACTIVE",
            lease_until=lease_until,
            created_at=now,
        )
    )
    await session.flush()
    return True


async def transition_execution(
    session: AsyncSession,
    request_id: str,
    state: str,
    result: dict | None = None,
) -> bool:
    row = await session.scalar(
        select(ExecutionLedger)
        .where(ExecutionLedger.request_id == request_id)
        .with_for_update()
    )
    if row is None or row.state in TERMINAL_STATES:
        return False

    now = datetime.now(timezone.utc)
    row.state = state
    row.result_json = result
    if state == "CHECKED":
        row.checked_at = now
    if state == "SENT":
        row.sent_at = now
    if state in TERMINAL_STATES:
        row.reconciled_at = now
        if row.created_at:
            row.latency_ms = max(
                0.0,
                (now - row.created_at).total_seconds() * 1000.0,
            )
        reservation = await session.scalar(
            select(PortfolioReservation)
            .where(PortfolioReservation.request_id == request_id)
            .with_for_update()
        )
        if reservation:
            reservation.status = "RELEASED"
    await session.flush()
    return True


async def recover_expired_leases(session: AsyncSession) -> int:
    now = datetime.now(timezone.utc)
    rows = (
        (
            await session.execute(
                select(ExecutionLedger)
                .where(
                    ExecutionLedger.lease_until < now,
                    ExecutionLedger.state.in_(["RESERVED", "SENT", "ACKED"]),
                )
                .with_for_update()
            )
        )
        .scalars()
        .all()
    )
    for row in rows:
        row.state = "RECOVERING"
        reservation = await session.scalar(
            select(PortfolioReservation)
            .where(PortfolioReservation.request_id == row.request_id)
            .with_for_update()
        )
        if reservation:
            reservation.status = "RECOVERED"
    await session.flush()
    return len(rows)
