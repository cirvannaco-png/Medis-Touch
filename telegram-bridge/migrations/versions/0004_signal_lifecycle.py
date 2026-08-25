"""signal lifecycle status + extra diagnostics

Revision ID: 0004
Revises: 0003
Create Date: 2026-08-24

Adds signal lifecycle tracking (VALID -> STALE/EXPIRED/INVALIDATED, see
app/models.py:SignalLifecycleStatus) and a JSON `extra` column for the
v2.9 EA-side diagnostics (sweep grade, BOS strength, decay, chase
distance, news risk, calibrated probability, pip distances) that don't
warrant dedicated columns yet.

Same DO $$ idempotent-enum-creation pattern as 0001, for the same
DuplicateObjectError reason documented there.
"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM as PG_ENUM

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

signal_lifecycle_status_enum = PG_ENUM(
    "valid", "stale", "expired", "invalidated",
    name="signallifecyclestatus",
    create_type=False,
)


def upgrade() -> None:
    op.execute(sa.text(
        "DO $$ BEGIN "
        "  CREATE TYPE signallifecyclestatus AS ENUM "
        "    ('valid', 'stale', 'expired', 'invalidated'); "
        "EXCEPTION WHEN duplicate_object THEN null; "
        "END $$;"
    ))

    op.add_column(
        "signals",
        sa.Column(
            "lifecycle_status",
            signal_lifecycle_status_enum,
            nullable=False,
            server_default="valid",
        ),
    )
    op.add_column("signals", sa.Column("lifecycle_reason", sa.String(), nullable=True))
    op.add_column("signals", sa.Column("lifecycle_updated_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("signals", sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("signals", sa.Column("extra", sa.JSON(), nullable=True))

    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_signals_lifecycle_status ON signals (lifecycle_status);"
    ))


def downgrade() -> None:
    op.execute(sa.text("DROP INDEX IF EXISTS ix_signals_lifecycle_status;"))
    op.drop_column("signals", "extra")
    op.drop_column("signals", "expires_at")
    op.drop_column("signals", "lifecycle_updated_at")
    op.drop_column("signals", "lifecycle_reason")
    op.drop_column("signals", "lifecycle_status")
    op.execute(sa.text("DROP TYPE IF EXISTS signallifecyclestatus;"))
