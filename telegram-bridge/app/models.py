import enum
from datetime import datetime, timezone
import sqlalchemy as sa
from sqlalchemy import JSON, Column, DateTime, Float, Index, Integer, String, Text
from sqlalchemy.dialects.postgresql import ENUM as PG_ENUM
from app.database import Base

class SignalStatus(str, enum.Enum):
    PENDING="pending"; ACTIVE="active"; FAILED="failed"; PERMANENTLY_FAILED="permanently_failed"; DUPLICATE="duplicate"
class SignalLifecycleStatus(str, enum.Enum):
    VALID="valid"; STALE="stale"; EXPIRED="expired"; INVALIDATED="invalidated"
class TradeEventStatus(str, enum.Enum):
    PENDING="pending"; ACTIVE="active"; FAILED="failed"; PERMANENTLY_FAILED="permanently_failed"
class TradeEventType(str, enum.Enum):
    OPENED="opened"; MODIFIED="modified"; PARTIAL_CLOSE="partial_close"; CLOSED_TP1="closed_tp1"; CLOSED_TP2="closed_tp2"; CLOSED_SL="closed_sl"; CLOSED_MANUAL="closed_manual"
_signal_status_type=PG_ENUM(SignalStatus,name="signalstatus",create_type=False)
_signal_lifecycle_status_type=PG_ENUM(SignalLifecycleStatus,name="signallifecyclestatus",create_type=False)
_trade_event_status_type=PG_ENUM(TradeEventStatus,name="tradeeventstatus",create_type=False)
_trade_event_type_type=PG_ENUM(TradeEventType,name="tradeeventtype",create_type=False)

class BotSetting(Base):
    __tablename__="bot_settings"; key=Column(String,primary_key=True); value=Column(JSON,nullable=False); updated_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc),onupdate=lambda:datetime.now(timezone.utc))
class TradeEvent(Base):
    __tablename__="trade_events"; __table_args__=(Index("ix_trade_events_status","status"),Index("ix_trade_events_trade_id","trade_id"))
    id=Column(Integer,primary_key=True); event_id=Column(String,unique=True,nullable=False,index=True); trade_id=Column(String,nullable=False); signal_id=Column(String,nullable=True,index=True); symbol=Column(String,nullable=False); direction=Column(String,nullable=False); event=Column(_trade_event_type_type,nullable=False); volume=Column(Float,nullable=False); price=Column(Float,nullable=False); sl=Column(Float); tp1=Column(Float); tp2=Column(Float); profit=Column(Float); balance=Column(Float); equity=Column(Float); comment=Column(String); received_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc)); telegram_message_id=Column(Integer); status=Column(_trade_event_status_type,nullable=False,default=TradeEventStatus.PENDING); error_message=Column(Text); latency_ms=Column(Integer)
class Signal(Base):
    __tablename__="signals"; __table_args__=(Index("ix_signals_status","status"),)
    id=Column(Integer,primary_key=True); signal_id=Column(String,unique=True,nullable=False,index=True); symbol=Column(String,nullable=False); direction=Column(String,nullable=False); entry=Column(Float,nullable=False); sl=Column(Float,nullable=False); tp1=Column(Float,nullable=False); tp2=Column(Float,nullable=False); confidence=Column(Integer,nullable=False); reasons=Column(JSON,nullable=False); timeframe=Column(String,nullable=False); received_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc)); telegram_message_id=Column(Integer); status=Column(_signal_status_type,nullable=False,default=SignalStatus.PENDING); error_message=Column(Text); latency_ms=Column(Integer); lifecycle_status=Column(_signal_lifecycle_status_type,nullable=False,default=SignalLifecycleStatus.VALID); lifecycle_reason=Column(String); lifecycle_updated_at=Column(DateTime(timezone=True)); expires_at=Column(DateTime(timezone=True)); extra=Column(JSON,nullable=True); regime=Column(String,index=True); session=Column(String,index=True); sweep_grade=Column(String,index=True); htf_ob_aligned=Column(sa.Boolean); weight_version=Column(String,index=True)
class SignalOutcome(Base):
    __tablename__="signal_outcomes"; __table_args__=(Index("ix_signal_outcomes_regime_session","regime","session"),)
    id=Column(Integer,primary_key=True); signal_id=Column(String,unique=True,nullable=False,index=True); symbol=Column(String,nullable=False); direction=Column(String,nullable=False); outcome=Column(String,nullable=False,index=True); realized_r=Column(Float); mfe_r=Column(Float); mae_r=Column(Float); bars_held=Column(Integer); bars_to_fill=Column(Integer); filled=Column(sa.Boolean,nullable=False,default=False); regime=Column(String,index=True); session=Column(String,index=True); sweep_grade=Column(String,index=True); htf_ob_aligned=Column(sa.Boolean); weight_version=Column(String,index=True); confidence_at_signal=Column(Float); confidence_decayed=Column(Float); decay_bars=Column(Integer); received_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc))
class CalibrationCycle(Base):
    __tablename__="calibration_cycles"; id=Column(Integer,primary_key=True); cycle_id=Column(String,unique=True,nullable=False,index=True); source=Column(String,nullable=False,index=True,default="live"); generated_at=Column(DateTime(timezone=True),nullable=False); report_json=Column(JSON,nullable=False); created_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc))
class PromotionRequest(Base):
    __tablename__="promotion_requests"; id=Column(Integer,primary_key=True); weight_version=Column(String,nullable=False,index=True); action=Column(String,nullable=False); decision_json=Column(JSON,nullable=False); status=Column(String,nullable=False,default="pending",index=True); telegram_message_id=Column(Integer); requested_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc)); decided_at=Column(DateTime(timezone=True)); decided_by=Column(String)
class ApprovedWeightVersion(Base):
    __tablename__="approved_weight_versions"; id=Column(Integer,primary_key=True); weight_version=Column(String,unique=True,nullable=False,index=True); approved_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc)); approved_by=Column(String); promotion_request_id=Column(Integer)

class ResearchExperiment(Base):
    __tablename__="research_experiments"
    id=Column(Integer,primary_key=True); experiment_id=Column(String,unique=True,nullable=False,index=True); name=Column(String,nullable=False); code_sha=Column(String,nullable=False); config_hash=Column(String,nullable=False,index=True); data_snapshot=Column(String,nullable=False); created_at=Column(DateTime(timezone=True),nullable=False); train_start=Column(DateTime(timezone=True),nullable=False); train_end=Column(DateTime(timezone=True),nullable=False); oos_start=Column(DateTime(timezone=True),nullable=False); oos_end=Column(DateTime(timezone=True),nullable=False); walk_forward_id=Column(String,index=True); holdout_locked=Column(sa.Boolean,nullable=False,default=False)
class ExperimentObservation(Base):
    __tablename__="experiment_observations"; __table_args__=(Index("ix_exp_obs_experiment_time","experiment_id","timestamp"),Index("ix_exp_obs_signal","signal_id"))
    id=Column(Integer,primary_key=True); experiment_id=Column(String,nullable=False,index=True); signal_id=Column(String,nullable=False); symbol=Column(String,nullable=False); timestamp=Column(DateTime(timezone=True),nullable=False); payload=Column(JSON,nullable=False); fingerprint=Column(String,nullable=False,index=True)
class ExperimentBookResult(Base):
    __tablename__="experiment_book_results"; __table_args__=(Index("ix_book_experiment_book","experiment_id","book"),)
    id=Column(Integer,primary_key=True); experiment_id=Column(String,nullable=False,index=True); signal_id=Column(String,nullable=False,index=True); book=Column(String,nullable=False); strategy=Column(String); direction=Column(String); outcome=Column(String,nullable=False); realized_r=Column(Float); mfe_r=Column(Float); mae_r=Column(Float); hypothetical=Column(sa.Boolean,nullable=False); metadata_json=Column(JSON,nullable=False,default=dict)
class ValidationRun(Base):
    __tablename__="validation_runs"; id=Column(Integer,primary_key=True); experiment_id=Column(String,nullable=False,index=True); validation_type=Column(String,nullable=False); window_json=Column(JSON,nullable=False); metrics_json=Column(JSON,nullable=False); passed=Column(sa.Boolean,nullable=False); created_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc))
class PromotionDecisionAudit(Base):
    __tablename__="promotion_decision_audit"; id=Column(Integer,primary_key=True); experiment_id=Column(String,nullable=False,index=True); champion_id=Column(String,nullable=False); challenger_id=Column(String,nullable=False); decision=Column(String,nullable=False); reason=Column(Text,nullable=False); metrics_json=Column(JSON,nullable=False); holdout_passed=Column(sa.Boolean,nullable=False); created_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc))
class ExecutionLedger(Base):
    __tablename__="execution_ledger"; __table_args__=(Index("ix_exec_ledger_state","state"),)
    id=Column(Integer,primary_key=True); request_id=Column(String,unique=True,nullable=False,index=True); signal_id=Column(String,index=True); symbol=Column(String,nullable=False); state=Column(String,nullable=False); broker_order_id=Column(String); broker_deal_id=Column(String); broker_position_id=Column(String); request_json=Column(JSON,nullable=False); result_json=Column(JSON); created_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc)); checked_at=Column(DateTime(timezone=True)); sent_at=Column(DateTime(timezone=True)); reconciled_at=Column(DateTime(timezone=True)); lease_until=Column(DateTime(timezone=True)); latency_ms=Column(Float)
class PortfolioReservation(Base):
    __tablename__="portfolio_reservations"; id=Column(Integer,primary_key=True); request_id=Column(String,unique=True,nullable=False,index=True); symbol=Column(String,nullable=False); direction=Column(String,nullable=False); risk_r=Column(Float,nullable=False); volatility=Column(Float,nullable=False); factor_exposure=Column(JSON,nullable=False); status=Column(String,nullable=False,index=True); lease_until=Column(DateTime(timezone=True),nullable=False); created_at=Column(DateTime(timezone=True),default=lambda:datetime.now(timezone.utc))
