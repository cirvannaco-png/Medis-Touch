"""calibration cycles + promotion requests + approved weight versions

Revision ID: 0006
Revises: 0005
Create Date: 2026-08-30

Step 5/6: moves cycle history from tools/cycle_store.py's local JSON
files into Postgres (calibration_cycles), and adds the tap-to-approve
audit trail (promotion_requests, approved_weight_versions). See
telegram-bridge/app/calibration.py for the orchestration that writes
these, and gating.py:load_cycles_from_db for how they're read back.
"""
import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "calibration_cycles",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("cycle_id", sa.String(), nullable=False, unique=True),
        sa.Column("source", sa.String(), nullable=False, server_default="live"),
        sa.Column("generated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("report_json", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_calibration_cycles_cycle_id ON calibration_cycles (cycle_id);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_calibration_cycles_source ON calibration_cycles (source);"))

    op.create_table(
        "promotion_requests",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("weight_version", sa.String(), nullable=False),
        sa.Column("action", sa.String(), nullable=False),
        sa.Column("decision_json", sa.JSON(), nullable=False),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("telegram_message_id", sa.Integer(), nullable=True),
        sa.Column("requested_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decided_by", sa.String(), nullable=True),
    )
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_promotion_requests_weight_version ON promotion_requests (weight_version);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_promotion_requests_status ON promotion_requests (status);"))

    op.create_table(
        "approved_weight_versions",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("weight_version", sa.String(), nullable=False, unique=True),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("approved_by", sa.String(), nullable=True),
        sa.Column("promotion_request_id", sa.Integer(), nullable=True),
    )
    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_approved_weight_versions_weight_version ON approved_weight_versions (weight_version);"
    ))


def downgrade() -> None:
    op.execute(sa.text("DROP TABLE IF EXISTS approved_weight_versions;"))
    op.execute(sa.text("DROP TABLE IF EXISTS promotion_requests;"))
    op.execute(sa.text("DROP TABLE IF EXISTS calibration_cycles;"))
