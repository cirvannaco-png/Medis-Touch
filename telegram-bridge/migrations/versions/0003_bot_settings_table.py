"""bot_settings table

Revision ID: 0003
Revises: 0002
Create Date: 2026-08-13

Adds bot_settings, a small key/value table backing the new /mute,
/unmute, /pause and /resume Telegram commands (see
app/settings_store.py). Plain key/value on purpose - these operator
flags tend to grow one at a time, and a generic table avoids a fresh
migration for every new toggle.

No enums here, unlike 0001/0002, so this is a plain create_table with
no DO $$ guard needed.
"""
import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "bot_settings",
        sa.Column("key", sa.String(), primary_key=True),
        sa.Column("value", sa.JSON(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("bot_settings")
