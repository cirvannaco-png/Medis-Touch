"""Research control-plane API. All endpoints are authenticated and fail closed."""
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_session
from app.routes import verify_api_key
from app.models import ResearchExperiment, ExperimentObservation, ValidationRun, PromotionDecisionAudit
from app.research.contracts import canonical_hash
from app.research.promotion import GatePolicy, gate

router = APIRouter(prefix="/research", tags=["research"])

class ExperimentIn(BaseModel):
    experiment_id: str = Field(min_length=1,max_length=128)
    name: str = Field(min_length=1,max_length=200)
    code_sha: str = Field(min_length=7,max_length=64)
    config: dict
    data_snapshot: str = Field(min_length=1,max_length=128)
    train_start: datetime; train_end: datetime; oos_start: datetime; oos_end: datetime
    walk_forward_id: str|None = None
    holdout_locked: bool = False

class ObservationIn(BaseModel):
    signal_id: str; symbol: str; timestamp: datetime; payload: dict

class GateIn(BaseModel):
    experiment_id: str; champion_id: str; challenger_id: str
    champion_r: list[float]; challenger_r: list[float]
    holdout_passed: bool
    min_trades: int = 100; min_expectancy_r: float = 0.05; max_drawdown_r: float = -10.0; min_win_rate: float = 0.45; min_effect_size_r: float = 0.02

@router.post("/experiments")
async def create_experiment(body: ExperimentIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    existing=await session.scalar(select(ResearchExperiment).where(ResearchExperiment.experiment_id==body.experiment_id))
    if existing: raise HTTPException(409,"experiment already exists")
    if body.train_start>=body.train_end or body.oos_start>=body.oos_end or body.train_end>body.oos_start: raise HTTPException(422,"invalid train/OOS chronology")
    row=ResearchExperiment(experiment_id=body.experiment_id,name=body.name,code_sha=body.code_sha,config_hash=canonical_hash(body.config),data_snapshot=body.data_snapshot,created_at=datetime.utcnow(),train_start=body.train_start,train_end=body.train_end,oos_start=body.oos_start,oos_end=body.oos_end,walk_forward_id=body.walk_forward_id,holdout_locked=body.holdout_locked)
    session.add(row); await session.commit(); return {"experiment_id":body.experiment_id,"config_hash":row.config_hash,"holdout_locked":row.holdout_locked}

@router.post("/experiments/{experiment_id}/observations")
async def ingest_observation(experiment_id: str, body: ObservationIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    exp=await session.scalar(select(ResearchExperiment).where(ResearchExperiment.experiment_id==experiment_id))
    if exp is None: raise HTTPException(404,"experiment not found")
    fingerprint=canonical_hash({"experiment_id":experiment_id,"signal_id":body.signal_id,"symbol":body.symbol,"timestamp":body.timestamp.isoformat(),"payload":body.payload})
    row=ExperimentObservation(experiment_id=experiment_id,signal_id=body.signal_id,symbol=body.symbol,timestamp=body.timestamp,payload=body.payload,fingerprint=fingerprint)
    session.add(row); await session.commit(); return {"stored":True,"fingerprint":fingerprint}

@router.post("/promotion-gate")
async def promotion_gate(body: GateIn, session: AsyncSession=Depends(get_session), _auth: bool=Depends(verify_api_key)):
    exp=await session.scalar(select(ResearchExperiment).where(ResearchExperiment.experiment_id==body.experiment_id))
    if exp is None: raise HTTPException(404,"experiment not found")
    if body.holdout_passed and not exp.holdout_locked: raise HTTPException(409,"holdout must be locked before a passing result can be accepted")
    policy=GatePolicy(min_trades=body.min_trades,min_expectancy_r=body.min_expectancy_r,max_drawdown_r=body.max_drawdown_r,min_win_rate=body.min_win_rate,min_effect_size_r=body.min_effect_size_r)
    d=gate(body.champion_r,body.challenger_r,policy,body.holdout_passed)
    audit=PromotionDecisionAudit(experiment_id=body.experiment_id,champion_id=body.champion_id,challenger_id=body.challenger_id,decision=d.action,reason=d.reason,metrics_json=d.__dict__,holdout_passed=body.holdout_passed)
    session.add(audit); await session.commit(); return d.__dict__
