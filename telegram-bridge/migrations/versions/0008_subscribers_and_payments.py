"""subscriber entitlement and Telegram payment tables

Revision ID: 0008
Revises: 0007
"""
import sqlalchemy as sa
from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "subscribers",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("telegram_user_id", sa.String(), nullable=False, unique=True),
        sa.Column("telegram_username", sa.String(), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("current_period_end", sa.DateTime(timezone=True), nullable=True),
        sa.Column("copy_feed_api_key", sa.String(), nullable=True, unique=True),
        sa.Column("warned_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_subscribers_status", "subscribers", ["status"])
    op.create_index("ix_subscribers_telegram_user_id", "subscribers", ["telegram_user_id"])
    op.create_index("ix_subscribers_copy_feed_api_key", "subscribers", ["copy_feed_api_key"])

    op.create_table(
        "payments",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("telegram_payment_charge_id", sa.String(), nullable=False, unique=True),
        sa.Column("subscriber_id", sa.Integer(), nullable=False),
        sa.Column("amount", sa.Integer(), nullable=False),
        sa.Column("currency", sa.String(), nullable=False),
        sa.Column("period_days", sa.Integer(), nullable=False),
        sa.Column("invoice_payload", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False, server_default="succeeded"),
        sa.Column("raw_payload", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_payments_subscriber_id", "payments", ["subscriber_id"])
    op.create_index("ix_payments_telegram_payment_charge_id", "payments", ["telegram_payment_charge_id"])


def downgrade() -> None:
    op.drop_table("payments")
    op.drop_table("subscribers")
