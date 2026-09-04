"""Low-latency configuration delivery and EA acknowledgement endpoints."""
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import case, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config_registry import ParameterConfiguration, ParameterDeployment, ParameterDeploymentAck
from app.database import get_session
from app.parameter_proposal.deployment import transition
from app.parameter_proposal.models import DeploymentState
from app.routes import verify_api_key

router = APIRouter(tags=["configuration"])


class ConfigResponseV2(BaseModel):
    symbol: str
    config_hash: str | None
    parent_version: str | None
    state: str | None
    params: dict | None
    issued_at: str | None


class ConfigAckRequest(BaseModel):
    config_hash: str = Field(..., min_length=64, max_length=64)
    ea_instance: str = Field(..., min_length=1, max_length=128)
    status: Literal["VALIDATED", "APPLIED", "REJECTED"]
    ea_version: str | None = Field(default=None, max_length=64)
    reason: str | None = Field(default=None, max_length=300)


class ConfigAckResponse(BaseModel):
    status: str
    config_hash: str
    symbol: str


def _advance_ea_validation(deployment: ParameterDeployment | None) -> None:
    """Advance only SCHEDULED deployments after successful EA validation."""
    if deployment is not None and deployment.state == DeploymentState.SCHEDULED.value:
        deployment.state = transition(DeploymentState.SCHEDULED, DeploymentState.EA_VALIDATED).value


def _advance_ea_applied(deployment: ParameterDeployment | None) -> None:
    """Activate only after the EA explicitly reports runtime application."""
    if deployment is not None and deployment.state == DeploymentState.EA_VALIDATED.value:
        state = transition(DeploymentState.EA_VALIDATED, DeploymentState.EA_ACKNOWLEDGED)
        state = transition(state, DeploymentState.ACTIVE)
        deployment.state = state.value
        deployment.activated_at = datetime.now(timezone.utc)


@router.get("/config/{symbol}", response_model=ConfigResponseV2)
async def get_active_config(
    symbol: str,
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
):
    """Return the highest-priority configuration awaiting EA validation/application."""
    deployment = await session.scalar(
        select(ParameterDeployment)
        .where(
            ParameterDeployment.symbol == symbol,
            ParameterDeployment.state.in_(["SCHEDULED", "EA_VALIDATED", "ACTIVE"]),
        )
        .order_by(
            case(
                (ParameterDeployment.state == "SCHEDULED", 0),
                (ParameterDeployment.state == "EA_VALIDATED", 1),
                else_=2,
            ),
            ParameterDeployment.created_at.desc(),
        )
        .limit(1)
    )
    if deployment is None:
        return ConfigResponseV2(
            symbol=symbol,
            config_hash=None,
            parent_version=None,
            state=None,
            params=None,
            issued_at=None,
        )

    config = await session.scalar(
        select(ParameterConfiguration).where(ParameterConfiguration.config_hash == deployment.config_hash)
    )
    if config is None or config.validation_state not in {"VALIDATED", "TESTED", "APPROVED", "ACTIVE"}:
        raise HTTPException(status_code=503, detail="deployable configuration is missing or not validated")

    return ConfigResponseV2(
        symbol=symbol,
        config_hash=config.config_hash,
        parent_version=config.parent_version,
        state=deployment.state,
        params=config.parameters_json,
        issued_at=(deployment.activated_at or datetime.now(timezone.utc)).isoformat(),
    )


@router.post("/config/{symbol}/ack", response_model=ConfigAckResponse)
async def acknowledge_config(
    symbol: str,
    payload: ConfigAckRequest,
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
):
    """Persist an EA acknowledgement without inferring application from validation."""
    config = await session.scalar(
        select(ParameterConfiguration).where(ParameterConfiguration.config_hash == payload.config_hash)
    )
    if config is None:
        raise HTTPException(status_code=404, detail="unknown config_hash")

    deployment = await session.scalar(
        select(ParameterDeployment)
        .where(
            ParameterDeployment.config_hash == payload.config_hash,
            ParameterDeployment.symbol == symbol,
        )
        .order_by(ParameterDeployment.created_at.desc())
        .limit(1)
    )

    session.add(
        ParameterDeploymentAck(
            config_hash=payload.config_hash,
            symbol=symbol,
            ea_instance=payload.ea_instance,
            status=payload.status,
            reason=payload.reason,
            ea_version=payload.ea_version,
        )
    )

    if payload.status == "VALIDATED":
        _advance_ea_validation(deployment)
    elif payload.status == "APPLIED":
        _advance_ea_applied(deployment)

    await session.commit()
    return ConfigAckResponse(status="recorded", config_hash=payload.config_hash, symbol=symbol)
