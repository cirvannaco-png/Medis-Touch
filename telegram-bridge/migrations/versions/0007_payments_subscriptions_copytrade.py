"""payment -> entitlement -> adaptive copy trading
Revision ID: 0007
Revises: 0006
"""
from alembic import op
import sqlalchemy as sa

revision="0007"
down_revision="0006"
branch_labels=None
depends_on=None

def upgrade():
    op.create_table("payments",
        sa.Column("id",sa.Integer(),primary_key=True,autoincrement=True),
        sa.Column("payment_id",sa.String(),nullable=False,unique=True),sa.Column("user_id",sa.String(),nullable=False),
        sa.Column("provider",sa.String(),nullable=False),sa.Column("provider_reference",sa.String()),
        sa.Column("amount",sa.Float(),nullable=False),sa.Column("currency",sa.String(),nullable=False),
        sa.Column("plan",sa.String(),nullable=False),sa.Column("status",sa.String(),nullable=False),
        sa.Column("paid_at",sa.DateTime(timezone=True)),sa.Column("raw_payload",sa.JSON()),sa.Column("created_at",sa.DateTime(timezone=True)))
    op.create_index("ix_payments_user_status","payments",["user_id","status"])
    op.create_table("subscriptions",
        sa.Column("id",sa.Integer(),primary_key=True,autoincrement=True),sa.Column("subscription_id",sa.String(),nullable=False,unique=True),
        sa.Column("user_id",sa.String(),nullable=False),sa.Column("plan",sa.String(),nullable=False),sa.Column("status",sa.String(),nullable=False),
        sa.Column("started_at",sa.DateTime(timezone=True)),sa.Column("expires_at",sa.DateTime(timezone=True)),sa.Column("payment_id",sa.String()),
        sa.Column("created_at",sa.DateTime(timezone=True)),sa.Column("updated_at",sa.DateTime(timezone=True)))
    op.create_index("ix_subscriptions_user_status","subscriptions",["user_id","status"])
    op.create_index("ix_subscriptions_expires_at","subscriptions",["expires_at"])
    op.create_table("entitlements",
        sa.Column("id",sa.Integer(),primary_key=True,autoincrement=True),sa.Column("entitlement_id",sa.String(),nullable=False,unique=True),
        sa.Column("user_id",sa.String(),nullable=False),sa.Column("subscription_id",sa.String(),nullable=False),
        sa.Column("telegram_access",sa.Boolean(),nullable=False,server_default=sa.true()),sa.Column("signal_access",sa.Boolean(),nullable=False,server_default=sa.true()),
        sa.Column("copy_trading",sa.Boolean(),nullable=False,server_default=sa.true()),sa.Column("status",sa.String(),nullable=False),
        sa.Column("valid_from",sa.DateTime(timezone=True),nullable=False),sa.Column("valid_until",sa.DateTime(timezone=True),nullable=False))
    op.create_index("ix_entitlements_user_status","entitlements",["user_id","status"])
    op.create_index("ix_entitlements_valid_until","entitlements",["valid_until"])
    op.create_table("copy_accounts",
        sa.Column("id",sa.Integer(),primary_key=True,autoincrement=True),sa.Column("account_id",sa.String(),nullable=False,unique=True),sa.Column("user_id",sa.String(),nullable=False),
        sa.Column("broker",sa.String(),nullable=False),sa.Column("server",sa.String()),sa.Column("ea_instance",sa.String()),sa.Column("risk_mode",sa.String(),nullable=False),sa.Column("risk_value",sa.Float(),nullable=False),
        sa.Column("copy_enabled",sa.Boolean(),nullable=False,server_default=sa.true()),sa.Column("last_seen_at",sa.DateTime(timezone=True)),sa.Column("created_at",sa.DateTime(timezone=True)))
    op.create_index("ix_copy_accounts_user_enabled","copy_accounts",["user_id","copy_enabled"])
    op.create_table("copy_trade_events",
        sa.Column("id",sa.Integer(),primary_key=True,autoincrement=True),sa.Column("copy_id",sa.String(),nullable=False,unique=True),sa.Column("signal_id",sa.String(),nullable=False),sa.Column("account_id",sa.String(),nullable=False),
        sa.Column("strategy",sa.String()),sa.Column("symbol",sa.String(),nullable=False),sa.Column("direction",sa.String(),nullable=False),sa.Column("entry",sa.Float(),nullable=False),sa.Column("sl",sa.Float(),nullable=False),
        sa.Column("tp1",sa.Float(),nullable=False),sa.Column("tp2",sa.Float(),nullable=False),sa.Column("final_tp",sa.Float()),sa.Column("risk_mode",sa.String(),nullable=False),sa.Column("risk_value",sa.Float(),nullable=False),
        sa.Column("status",sa.String(),nullable=False),sa.Column("broker_ticket",sa.String()),sa.Column("error_message",sa.Text()),sa.Column("created_at",sa.DateTime(timezone=True)),sa.Column("claimed_at",sa.DateTime(timezone=True)),sa.Column("executed_at",sa.DateTime(timezone=True)))
    op.create_index("ix_copy_events_account_status","copy_trade_events",["account_id","status"])
    op.create_index("ix_copy_events_signal","copy_trade_events",["signal_id"])
    op.create_table("signal_message_states",sa.Column("signal_id",sa.String(),primary_key=True),sa.Column("telegram_message_id",sa.Integer()),sa.Column("state",sa.String(),nullable=False),sa.Column("last_update_at",sa.DateTime(timezone=True)))

def downgrade():
    op.drop_table("signal_message_states"); op.drop_table("copy_trade_events"); op.drop_table("copy_accounts"); op.drop_table("entitlements"); op.drop_table("subscriptions"); op.drop_table("payments")
