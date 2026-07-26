"""initial signals table

Revision ID: 0001
Revises:
Create Date: 2026-07-26

This captures the schema previously created implicitly by
Base.metadata.create_all() at app startup. From this point on, schema
changes go through a new revision instead of relying on create_all(),
which has no upgrade/rollback path once there's real data to protect.
"""
from alembic import op
import sqlalchemy as sa

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

signal_status_enum = sa.Enum(
    "pending", "active", "failed", "permanently_failed", "duplicate",
    name="signalstatus",
)


def upgrade() -> None:
    signal_status_enum.create(op.get_bind(), checkfirst=True)

    op.create_table(
        "signals",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("signal_id", sa.String(), nullable=False, unique=True),
        sa.Column("symbol", sa.String(), nullable=False),
        sa.Column("direction", sa.String(), nullable=False),
        sa.Column("entry", sa.Float(), nullable=False),
        sa.Column("sl", sa.Float(), nullable=False),
        sa.Column("tp1", sa.Float(), nullable=False),
        sa.Column("tp2", sa.Float(), nullable=False),
        sa.Column("confidence", sa.Integer(), nullable=False),
        sa.Column("reasons", sa.JSON(), nullable=False),
        sa.Column("timeframe", sa.String(), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("telegram_message_id", sa.Integer(), nullable=True),
        sa.Column("status", signal_status_enum, nullable=False, server_default="pending"),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("latency_ms", sa.Integer(), nullable=True),
    )
    op.create_index("ix_signals_signal_id", "signals", ["signal_id"])
    op.create_index("ix_signals_status", "signals", ["status"])


def downgrade() -> None:
    op.drop_index("ix_signals_status", table_name="signals")
    op.drop_index("ix_signals_signal_id", table_name="signals")
    op.drop_table("signals")
    signal_status_enum.drop(op.get_bind(), checkfirst=True)
