"""trade_events table

Revision ID: 0002
Revises: 0001
Create Date: 2026-07-27

Adds trade_events, the table backing POST /trade. Distinct from signals:
a Signal is a pre-trade alert; a TradeEvent is a lifecycle event
(opened/modified/partial_close/closed_*) for an order the EA's
OrderManager/PositionManager actually placed with the broker. See the
docstring on app.models.TradeEvent for the full rationale.

Follows the same enum-creation pattern as 0001 (explicit DO $$ block,
create_type=False on the PostgreSQL-specific PG_ENUM) for the same asyncpg
transaction-visibility reason documented there.
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import ENUM as PG_ENUM

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

# FIX: Use PG_ENUM (sqlalchemy.dialects.postgresql.ENUM) instead of
# generic sa.Enum. The generic class silently discards create_type=False;
# the PG-specific class stores and respects it. See 0001 for full rationale.
trade_event_status_enum = PG_ENUM(
    "pending", "active", "failed", "permanently_failed",
    name="tradeeventstatus",
    create_type=False,
)

trade_event_type_enum = PG_ENUM(
    "opened", "modified", "partial_close",
    "closed_tp1", "closed_tp2", "closed_sl", "closed_manual",
    name="tradeeventtype",
    create_type=False,
)


def upgrade() -> None:
    op.execute(sa.text(
        "DO $$ BEGIN "
        "  CREATE TYPE tradeeventstatus AS ENUM "
        "    ('pending', 'active', 'failed', 'permanently_failed'); "
        "EXCEPTION WHEN duplicate_object THEN null; "
        "END $$;"
    ))
    op.execute(sa.text(
        "DO $$ BEGIN "
        "  CREATE TYPE tradeeventtype AS ENUM "
        "    ('opened', 'modified', 'partial_close', "
        "     'closed_tp1', 'closed_tp2', 'closed_sl', 'closed_manual'); "
        "EXCEPTION WHEN duplicate_object THEN null; "
        "END $$;"
    ))

    op.create_table(
        "trade_events",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("event_id", sa.String(), nullable=False, unique=True),
        sa.Column("trade_id", sa.String(), nullable=False),
        sa.Column("signal_id", sa.String(), nullable=True),
        sa.Column("symbol", sa.String(), nullable=False),
        sa.Column("direction", sa.String(), nullable=False),
        sa.Column("event", trade_event_type_enum, nullable=False),
        sa.Column("volume", sa.Float(), nullable=False),
        sa.Column("price", sa.Float(), nullable=False),
        sa.Column("sl", sa.Float(), nullable=True),
        sa.Column("tp1", sa.Float(), nullable=True),
        sa.Column("tp2", sa.Float(), nullable=True),
        sa.Column("profit", sa.Float(), nullable=True),
        sa.Column("balance", sa.Float(), nullable=True),
        sa.Column("equity", sa.Float(), nullable=True),
        sa.Column("comment", sa.String(), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("telegram_message_id", sa.Integer(), nullable=True),
        sa.Column("status", trade_event_status_enum, nullable=False, server_default="pending"),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("latency_ms", sa.Integer(), nullable=True),
        if_not_exists=True,
    )

    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_trade_events_event_id ON trade_events (event_id);"
    ))
    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_trade_events_trade_id ON trade_events (trade_id);"
    ))
    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_trade_events_signal_id ON trade_events (signal_id);"
    ))
    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_trade_events_status ON trade_events (status);"
    ))


def downgrade() -> None:
    op.execute(sa.text("DROP INDEX IF EXISTS ix_trade_events_status;"))
    op.execute(sa.text("DROP INDEX IF EXISTS ix_trade_events_signal_id;"))
    op.execute(sa.text("DROP INDEX IF EXISTS ix_trade_events_trade_id;"))
    op.execute(sa.text("DROP INDEX IF EXISTS ix_trade_events_event_id;"))
    op.drop_table("trade_events")
    op.execute(sa.text("DROP TYPE IF EXISTS tradeeventtype;"))
    op.execute(sa.text("DROP TYPE IF EXISTS tradeeventstatus;"))
