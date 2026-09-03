"""parameter/config/deployment registry

Revision ID: 0007
Revises: 0006
Create Date: 2026-09-03
"""
import sqlalchemy as sa
from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "parameter_configurations",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("config_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("parent_version", sa.String(128), nullable=False),
        sa.Column("parameters_json", sa.JSON(), nullable=False),
        sa.Column("provenance_json", sa.JSON(), nullable=False),
        sa.Column("validation_state", sa.String(32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_parameter_configurations_validation_state", "parameter_configurations", ["validation_state"])

    op.create_table(
        "parameter_deployments",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("config_hash", sa.String(64), nullable=False),
        sa.Column("symbol", sa.String(20), nullable=False),
        sa.Column("state", sa.String(32), nullable=False),
        sa.Column("scheduled_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("activated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("retired_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("rollback_of", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_parameter_deployments_symbol_state", "parameter_deployments", ["symbol", "state"])
    op.create_index("ix_parameter_deployments_config_hash", "parameter_deployments", ["config_hash"])

    op.create_table(
        "parameter_deployment_acks",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("config_hash", sa.String(64), nullable=False),
        sa.Column("symbol", sa.String(20), nullable=False),
        sa.Column("ea_instance", sa.String(128), nullable=False),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("reason", sa.String(300), nullable=True),
        sa.Column("ea_version", sa.String(64), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_parameter_deployment_acks_config_symbol", "parameter_deployment_acks", ["config_hash", "symbol"])


def downgrade() -> None:
    op.drop_table("parameter_deployment_acks")
    op.drop_table("parameter_deployments")
    op.drop_table("parameter_configurations")
