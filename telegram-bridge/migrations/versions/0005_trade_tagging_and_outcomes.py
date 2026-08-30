"""trade tagging columns on signals + signal_outcomes table

Revision ID: 0005
Revises: 0004
Create Date: 2026-08-29

Foundation for the two-track (coverage vs. expectancy) metrics engine.

1. Promotes regime / session / sweep_grade / htf_ob_aligned / weight_version
   out of Signal.extra (a JSON blob) into first-class indexed columns on
   `signals`, so they're queryable/groupable without JSON extraction.
2. Adds `signal_outcomes` — one row per resolved (or no-fill) setup from
   the EA's OutcomeTracker simulator, denormalized with the same tag set
   plus realized R / MFE / MAE / decay. This is data that previously only
   ever reached a local CSV on the MT5 terminal and never touched
   Postgres at all.

No backfill: existing `signals` rows get NULL for the new columns (they
predate the EA build that populates them) and there is no existing
`signal_outcomes` data to migrate from, since this table didn't exist.
"""
import sqlalchemy as sa
from alembic import op

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # --- signals: promote tags out of `extra` into real columns ---
    op.add_column("signals", sa.Column("regime", sa.String(), nullable=True))
    op.add_column("signals", sa.Column("session", sa.String(), nullable=True))
    op.add_column("signals", sa.Column("sweep_grade", sa.String(), nullable=True))
    op.add_column("signals", sa.Column("htf_ob_aligned", sa.Boolean(), nullable=True))
    op.add_column("signals", sa.Column("weight_version", sa.String(), nullable=True))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signals_regime ON signals (regime);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signals_session ON signals (session);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signals_sweep_grade ON signals (sweep_grade);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signals_weight_version ON signals (weight_version);"))

    # --- signal_outcomes: new table ---
    op.create_table(
        "signal_outcomes",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("signal_id", sa.String(), nullable=False, unique=True),
        sa.Column("symbol", sa.String(), nullable=False),
        sa.Column("direction", sa.String(), nullable=False),
        sa.Column("outcome", sa.String(), nullable=False),
        sa.Column("realized_r", sa.Float(), nullable=True),
        sa.Column("mfe_r", sa.Float(), nullable=True),
        sa.Column("mae_r", sa.Float(), nullable=True),
        sa.Column("bars_held", sa.Integer(), nullable=True),
        sa.Column("bars_to_fill", sa.Integer(), nullable=True),
        sa.Column("filled", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("regime", sa.String(), nullable=True),
        sa.Column("session", sa.String(), nullable=True),
        sa.Column("sweep_grade", sa.String(), nullable=True),
        sa.Column("htf_ob_aligned", sa.Boolean(), nullable=True),
        sa.Column("weight_version", sa.String(), nullable=True),
        sa.Column("confidence_at_signal", sa.Float(), nullable=True),
        sa.Column("confidence_decayed", sa.Float(), nullable=True),
        sa.Column("decay_bars", sa.Integer(), nullable=True),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signal_outcomes_signal_id ON signal_outcomes (signal_id);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signal_outcomes_outcome ON signal_outcomes (outcome);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signal_outcomes_regime ON signal_outcomes (regime);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signal_outcomes_session ON signal_outcomes (session);"))
    op.execute(sa.text("CREATE INDEX IF NOT EXISTS ix_signal_outcomes_sweep_grade ON signal_outcomes (sweep_grade);"))
    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_signal_outcomes_regime_session ON signal_outcomes (regime, session);"
    ))
    op.execute(sa.text(
        "CREATE INDEX IF NOT EXISTS ix_signal_outcomes_weight_version ON signal_outcomes (weight_version);"
    ))


def downgrade() -> None:
    op.execute(sa.text("DROP TABLE IF EXISTS signal_outcomes;"))
    op.execute(sa.text("DROP INDEX IF EXISTS ix_signals_weight_version;"))
    op.execute(sa.text("DROP INDEX IF EXISTS ix_signals_sweep_grade;"))
    op.execute(sa.text("DROP INDEX IF EXISTS ix_signals_session;"))
    op.execute(sa.text("DROP INDEX IF EXISTS ix_signals_regime;"))
    op.drop_column("signals", "weight_version")
    op.drop_column("signals", "htf_ob_aligned")
    op.drop_column("signals", "sweep_grade")
    op.drop_column("signals", "session")
    op.drop_column("signals", "regime")
