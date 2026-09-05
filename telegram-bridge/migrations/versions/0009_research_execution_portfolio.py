"""Research experiments, three books, validation, execution ledger and portfolio reservations.
Revision ID: 0009
Revises: 0008
"""
from alembic import op
import sqlalchemy as sa

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None

def upgrade():
    op.create_table("research_experiments",
        sa.Column("id",sa.Integer(),primary_key=True),sa.Column("experiment_id",sa.String(),nullable=False,unique=True),sa.Column("name",sa.String(),nullable=False),sa.Column("code_sha",sa.String(),nullable=False),sa.Column("config_hash",sa.String(),nullable=False),sa.Column("data_snapshot",sa.String(),nullable=False),sa.Column("created_at",sa.DateTime(timezone=True),nullable=False),sa.Column("train_start",sa.DateTime(timezone=True),nullable=False),sa.Column("train_end",sa.DateTime(timezone=True),nullable=False),sa.Column("oos_start",sa.DateTime(timezone=True),nullable=False),sa.Column("oos_end",sa.DateTime(timezone=True),nullable=False),sa.Column("walk_forward_id",sa.String()),sa.Column("holdout_locked",sa.Boolean(),nullable=False,server_default=sa.false()))
    op.create_index("ix_research_experiments_id","research_experiments",["experiment_id"],unique=True);op.create_index("ix_research_experiments_config","research_experiments",["config_hash"])
    op.create_table("experiment_observations",sa.Column("id",sa.Integer(),primary_key=True),sa.Column("experiment_id",sa.String(),nullable=False),sa.Column("signal_id",sa.String(),nullable=False),sa.Column("symbol",sa.String(),nullable=False),sa.Column("timestamp",sa.DateTime(timezone=True),nullable=False),sa.Column("payload",sa.JSON(),nullable=False),sa.Column("fingerprint",sa.String(),nullable=False))
    op.create_index("ix_exp_obs_experiment_time","experiment_observations",["experiment_id","timestamp"]);op.create_index("ix_exp_obs_signal","experiment_observations",["signal_id"]);op.create_index("ix_exp_obs_fingerprint","experiment_observations",["fingerprint"])
    op.create_table("experiment_book_results",sa.Column("id",sa.Integer(),primary_key=True),sa.Column("experiment_id",sa.String(),nullable=False),sa.Column("signal_id",sa.String(),nullable=False),sa.Column("book",sa.String(),nullable=False),sa.Column("strategy",sa.String()),sa.Column("direction",sa.String()),sa.Column("outcome",sa.String(),nullable=False),sa.Column("realized_r",sa.Float()),sa.Column("mfe_r",sa.Float()),sa.Column("mae_r",sa.Float()),sa.Column("hypothetical",sa.Boolean(),nullable=False),sa.Column("metadata_json",sa.JSON(),nullable=False))
    op.create_index("ix_book_experiment_book","experiment_book_results",["experiment_id","book"]);op.create_index("ix_book_signal","experiment_book_results",["signal_id"])
    op.create_table("validation_runs",sa.Column("id",sa.Integer(),primary_key=True),sa.Column("experiment_id",sa.String(),nullable=False),sa.Column("validation_type",sa.String(),nullable=False),sa.Column("window_json",sa.JSON(),nullable=False),sa.Column("metrics_json",sa.JSON(),nullable=False),sa.Column("passed",sa.Boolean(),nullable=False),sa.Column("created_at",sa.DateTime(timezone=True)))
    op.create_index("ix_validation_experiment","validation_runs",["experiment_id"])
    op.create_table("promotion_decision_audit",sa.Column("id",sa.Integer(),primary_key=True),sa.Column("experiment_id",sa.String(),nullable=False),sa.Column("champion_id",sa.String(),nullable=False),sa.Column("challenger_id",sa.String(),nullable=False),sa.Column("decision",sa.String(),nullable=False),sa.Column("reason",sa.Text(),nullable=False),sa.Column("metrics_json",sa.JSON(),nullable=False),sa.Column("holdout_passed",sa.Boolean(),nullable=False),sa.Column("created_at",sa.DateTime(timezone=True)))
    op.create_index("ix_promotion_audit_experiment","promotion_decision_audit",["experiment_id"])
    op.create_table("execution_ledger",sa.Column("id",sa.Integer(),primary_key=True),sa.Column("request_id",sa.String(),nullable=False,unique=True),sa.Column("signal_id",sa.String()),sa.Column("symbol",sa.String(),nullable=False),sa.Column("state",sa.String(),nullable=False),sa.Column("broker_order_id",sa.String()),sa.Column("broker_deal_id",sa.String()),sa.Column("broker_position_id",sa.String()),sa.Column("request_json",sa.JSON(),nullable=False),sa.Column("result_json",sa.JSON()),sa.Column("created_at",sa.DateTime(timezone=True)),sa.Column("checked_at",sa.DateTime(timezone=True)),sa.Column("sent_at",sa.DateTime(timezone=True)),sa.Column("reconciled_at",sa.DateTime(timezone=True)),sa.Column("lease_until",sa.DateTime(timezone=True)),sa.Column("latency_ms",sa.Float()))
    op.create_index("ix_exec_ledger_request","execution_ledger",["request_id"],unique=True);op.create_index("ix_exec_ledger_state","execution_ledger",["state"]);op.create_index("ix_exec_ledger_signal","execution_ledger",["signal_id"])
    op.create_table("portfolio_reservations",sa.Column("id",sa.Integer(),primary_key=True),sa.Column("request_id",sa.String(),nullable=False,unique=True),sa.Column("symbol",sa.String(),nullable=False),sa.Column("direction",sa.String(),nullable=False),sa.Column("risk_r",sa.Float(),nullable=False),sa.Column("volatility",sa.Float(),nullable=False),sa.Column("factor_exposure",sa.JSON(),nullable=False),sa.Column("status",sa.String(),nullable=False),sa.Column("lease_until",sa.DateTime(timezone=True),nullable=False),sa.Column("created_at",sa.DateTime(timezone=True)))
    op.create_index("ix_portfolio_request","portfolio_reservations",["request_id"],unique=True);op.create_index("ix_portfolio_status","portfolio_reservations",["status"])

def downgrade():
    for name in ["portfolio_reservations","execution_ledger","promotion_decision_audit","validation_runs","experiment_book_results","experiment_observations","research_experiments"]: op.drop_table(name)
