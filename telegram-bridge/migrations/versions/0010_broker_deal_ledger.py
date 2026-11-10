"""Persist actual MT5 broker deals and per-position aggregates.

Revision ID: 0010
Revises: 0009
"""
from alembic import op
import sqlalchemy as sa

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "broker_deals",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("deal_ticket", sa.String(), nullable=False, unique=True),
        sa.Column("position_id", sa.String(), nullable=False),
        sa.Column("order_ticket", sa.String(), nullable=False),
        sa.Column("signal_id", sa.String(), nullable=True),
        sa.Column("symbol", sa.String(), nullable=False),
        sa.Column("magic_number", sa.BigInteger(), nullable=False),
        sa.Column("direction", sa.String(), nullable=False),
        sa.Column("entry_type", sa.String(), nullable=False),
        sa.Column("deal_type", sa.String(), nullable=False),
        sa.Column("volume", sa.Float(), nullable=False),
        sa.Column("price", sa.Float(), nullable=False),
        sa.Column("profit", sa.Float(), nullable=False, server_default="0"),
        sa.Column("commission", sa.Float(), nullable=False, server_default="0"),
        sa.Column("swap", sa.Float(), nullable=False, server_default="0"),
        sa.Column("fee", sa.Float(), nullable=False, server_default="0"),
        sa.Column("net_profit", sa.Float(), nullable=False, server_default="0"),
        sa.Column("time_msc", sa.BigInteger(), nullable=False),
        sa.Column("deal_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("comment", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_broker_deals_deal_ticket", "broker_deals", ["deal_ticket"], unique=True)
    op.create_index("ix_broker_deals_position_time", "broker_deals", ["position_id", "time_msc"])
    op.create_index("ix_broker_deals_symbol_time", "broker_deals", ["symbol", "time_msc"])
    op.create_index("ix_broker_deals_signal_id", "broker_deals", ["signal_id"])

    op.create_table(
        "broker_positions",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("position_id", sa.String(), nullable=False, unique=True),
        sa.Column("signal_id", sa.String(), nullable=True),
        sa.Column("symbol", sa.String(), nullable=False),
        sa.Column("magic_number", sa.BigInteger(), nullable=False),
        sa.Column("direction", sa.String(), nullable=False),
        sa.Column("entry_price", sa.Float(), nullable=True),
        sa.Column("initial_stop_loss", sa.Float(), nullable=True),
        sa.Column("initial_risk_distance", sa.Float(), nullable=True),
        sa.Column("total_volume_in", sa.Float(), nullable=False, server_default="0"),
        sa.Column("total_volume_out", sa.Float(), nullable=False, server_default="0"),
        sa.Column("position_open", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("gross_profit", sa.Float(), nullable=False, server_default="0"),
        sa.Column("commission", sa.Float(), nullable=False, server_default="0"),
        sa.Column("swap", sa.Float(), nullable=False, server_default="0"),
        sa.Column("fee", sa.Float(), nullable=False, server_default="0"),
        sa.Column("net_profit", sa.Float(), nullable=False, server_default="0"),
        sa.Column("mfe_price", sa.Float(), nullable=True),
        sa.Column("mae_price", sa.Float(), nullable=True),
        sa.Column("mfe_r", sa.Float(), nullable=True),
        sa.Column("mae_r", sa.Float(), nullable=True),
        sa.Column("opened_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_broker_positions_position_id", "broker_positions", ["position_id"], unique=True)
    op.create_index("ix_broker_positions_symbol_closed", "broker_positions", ["symbol", "position_open"])
    op.create_index("ix_broker_positions_signal_id", "broker_positions", ["signal_id"])


def downgrade() -> None:
    op.drop_table("broker_positions")
    op.drop_table("broker_deals")
