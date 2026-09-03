"""Persistent registry for validated configurations and deployment ACKs."""
from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, Index, Integer, JSON, String

from app.database import Base


class ParameterConfiguration(Base):
    __tablename__ = "parameter_configurations"
    id = Column(Integer, primary_key=True, autoincrement=True)
    config_hash = Column(String(64), unique=True, nullable=False, index=True)
    parent_version = Column(String(128), nullable=False)
    parameters_json = Column(JSON, nullable=False)
    provenance_json = Column(JSON, nullable=False)
    validation_state = Column(String(32), nullable=False, index=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class ParameterDeployment(Base):
    __tablename__ = "parameter_deployments"
    __table_args__ = (Index("ix_parameter_deployments_symbol_state", "symbol", "state"),)
    id = Column(Integer, primary_key=True, autoincrement=True)
    config_hash = Column(String(64), nullable=False, index=True)
    symbol = Column(String(20), nullable=False)
    state = Column(String(32), nullable=False)
    scheduled_at = Column(DateTime(timezone=True), nullable=True)
    activated_at = Column(DateTime(timezone=True), nullable=True)
    retired_at = Column(DateTime(timezone=True), nullable=True)
    rollback_of = Column(String(64), nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class ParameterDeploymentAck(Base):
    __tablename__ = "parameter_deployment_acks"
    __table_args__ = (Index("ix_parameter_deployment_acks_config_symbol", "config_hash", "symbol"),)
    id = Column(Integer, primary_key=True, autoincrement=True)
    config_hash = Column(String(64), nullable=False)
    symbol = Column(String(20), nullable=False)
    ea_instance = Column(String(128), nullable=False)
    status = Column(String(32), nullable=False)
    reason = Column(String(300), nullable=True)
    ea_version = Column(String(64), nullable=True)
    received_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
