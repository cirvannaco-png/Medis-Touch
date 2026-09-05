"""Authenticated research, validation, execution and promotion control plane."""
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_session
from app.routes import verify_api_key
from app.models import ResearchExperiment, ExperimentObservation, PromotionDecisionAudit
from app.research.contracts import canonical_hash
from app.research.promotion import GatePolicy, gate
from app.research.execution_service import reserve_execution, transition_execution, recover_expired_leases

router = APIRouter(prefix="/research", tags=["research"])
class ExperimentIn(BaseModel):
    experiment_id: str=Field(min_length=1,max_length=128); name: str=Field(min_length=1,max_length=200); code_sha: str=Field(min_length=7,max_length=64); config: dict; data_snapshot: str=Field(min_length=1,max_length=128); train_start: datetime; train_end: datetime; oos_start: datetime; oos_end: datetime; walk_forward_id: str|None=None; holdout_locked: bool=False
class ObservationIn(BaseModel):
    signal_id: str; symbol: str; timestamp: datetime; payload: dict
class GateIn(BaseModel):
    experiment_id: str; champion_id: str; challenger_id: str; champion_r: list[float]; challenger_r: list[float]; holdout_passed: bool; min_trades: int=100; min_expectancy_r: float=0.05; max_drawdown_r: float=-10.0; min_win_rate: float=0.45; min_effect_size_r: float=0.02
class ReserveIn(BaseModel):
    request_id: str; signal_id: str; symbol: str; direction: str; risk_r: float=Field(gt=0); volatility: float=Field(ge=0); factors: dict={}; max_heat_r: float=Field(gt=0,default=3.0)
class TransitionIn(BaseModel):
    request_id: str; state: str; result: dict|None=None

@router.post("/experiments")
async def create_experiment(body: ExperimentIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    if await session.scalar(select(ResearchExperiment).where(ResearchExperiment.experiment_id==body.experiment_id)): raise HTTPException(409,"experiment already exists")
    if body.train_start>=body.train_end or body.oos_start>=body.oos_end or body.train_end>body.oos_start: raise HTTPException(422,"invalid train/OOS chronology")
    row=ResearchExperiment(experiment_id=body.experiment_id,name=body.name,code_sha=body.code_sha,config_hash=canonical_hash(body.config),data_snapshot=body.data_snapshot,created_at=datetime.now(timezone.utc),train_start=body.train_start,train_end=body.train_end,oos_start=body.oos_start,oos_end=body.oos_end,walk_forward_id=body.walk_forward_id,holdout_locked=body.holdout_locked)
    session.add(row); await session.commit(); return {"experiment_id":row.experiment_id,"config_hash":row.config_hash,"holdout_locked":row.holdout_locked}

@router.post("/experiments/{experiment_id}/observations")
async def ingest_observation(experiment_id: str, body: ObservationIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    if await session.scalar(select(ResearchExperiment).where(ResearchExperiment.experiment_id==experiment_id)) is None: raise HTTPException(404,"experiment not found")
    fingerprint=canonical_hash({"experiment_id":experiment_id,"signal_id":body.signal_id,"symbol":body.symbol,"timestamp":body.timestamp.isoformat(),"payload":body.payload})
    session.add(ExperimentObservation(experiment_id=experiment_id,signal_id=body.signal_id,symbol=body.symbol,timestamp=body.timestamp,payload=body.payload,fingerprint=fingerprint)); await session.commit(); return {"stored":True,"fingerprint":fingerprint}

@router.post("/promotion-gate")
async def promotion_gate(body: GateIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    exp=await session.scalar(select(ResearchExperiment).where(ResearchExperiment.experiment_id==body.experiment_id))
    if exp is None: raise HTTPException(404,"experiment not found")
    policy=GatePolicy(min_trades=body.min_trades,min_expectancy_r=body.min_expectancy_r,max_drawdown_r=body.max_drawdown_r,min_win_rate=body.min_win_rate,min_effect_size_r=body.min_effect_size_r)
    d=gate(body.champion_r,body.challenger_r,policy,body.holdout_passed)
    if body.holdout_passed and not exp.holdout_locked: raise HTTPException(409,"holdout must be locked before accepting a passing result")
    audit=PromotionDecisionAudit(experiment_id=body.experiment_id,champion_id=body.champion_id,challenger_id=body.challenger_id,decision=d.action,reason=d.reason,metrics_json=d.__dict__,holdout_passed=body.holdout_passed); session.add(audit); await session.commit(); return d.__dict__

@router.post("/execution/reserve")
async def execution_reserve(body: ReserveIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    ok=await reserve_execution(session,body.request_id,body.signal_id,body.symbol,body.direction,body.risk_r,body.volatility,body.factors,body.max_heat_r)
    if not ok: await session.rollback(); raise HTTPException(409,"request duplicate or portfolio heat limit exceeded")
    await session.commit(); return {"reserved":True,"request_id":body.request_id}

@router.post("/execution/transition")
async def execution_transition(body: TransitionIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    if not await transition_execution(session,body.request_id,body.state,body.result): await session.rollback(); raise HTTPException(409,"unknown or terminal execution request")
    await session.commit(); return {"transitioned":True,"request_id":body.request_id,"state":body.state}

@router.post("/execution/recover-expired")
async def execution_recover(session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    count=await recover_expired_leases(session); await session.commit(); return {"recovered":count}
